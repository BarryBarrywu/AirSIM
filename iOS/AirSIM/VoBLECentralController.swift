import Combine
import CoreBluetooth
import CryptoKit
import Foundation
import Security

enum VoBLEConnectionState: Equatable, Sendable {
    case stopped, bluetoothUnavailable, scanning, connecting, connected, authenticating, ready
    case failed(String)
}

enum VoBLEConnectionEvent: Equatable, Sendable {
    case bluetoothPoweredOn, bluetoothUnavailable, connected, characteristicsReady, stopped
    case discovered(UUID), restored(UUID), controlSubscription(Bool)
    case authenticated(identity: String), authenticationFailed(String)
    case disconnected(String?)
}

struct VoBLEConnectionReducer: Sendable {
    private(set) var state: VoBLEConnectionState = .stopped
    private(set) var peripheralID: UUID?
    private(set) var authenticatedIdentity: String?
    private var characteristicsReady = false
    private var controlSubscribed = false

    mutating func apply(_ event: VoBLEConnectionEvent) {
        switch event {
        case .bluetoothPoweredOn: state = .scanning
        case .bluetoothUnavailable: reset(); state = .bluetoothUnavailable
        case let .discovered(id): peripheralID = id; state = .connecting
        case .connected: state = .connected
        case let .restored(id): reset(); peripheralID = id; state = .connecting
        case .characteristicsReady:
            characteristicsReady = true; state = authenticatedIdentity == nil ? .authenticating : state
            publishReady()
        case let .controlSubscription(value): controlSubscribed = value; publishReady()
        case let .authenticated(identity): authenticatedIdentity = identity; state = .authenticating; publishReady()
        case let .authenticationFailed(message): authenticatedIdentity = nil; state = .failed(message)
        case let .disconnected(message): reset(); state = message.map(Self.failed) ?? .scanning
        case .stopped: reset(); peripheralID = nil; state = .stopped
        }
    }

    private mutating func publishReady() {
        if characteristicsReady, controlSubscribed, authenticatedIdentity != nil { state = .ready }
    }
    private mutating func reset() {
        characteristicsReady = false; controlSubscribed = false; authenticatedIdentity = nil
    }
    private static func failed(_ message: String) -> VoBLEConnectionState { .failed(message) }
}

struct VoBLEDiscoveredPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let signal: Int
}

struct VoBLEControlResponse: Equatable, Sendable {
    let requestID: String
    let generation: UInt64
    let success: Bool
    let code: String
    let detail: String
}

struct VoBLEAndroidEvent: Equatable, Sendable {
    let callID: String
    let generation: UInt64
    let direction: String
    let state: String
    let number: String
}

enum VoBLECentralError: LocalizedError, Equatable {
    case notReady, invalidResponse, authenticationFailed, commandTimedOut, disconnected
    case bluetooth(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "蓝牙 Agent 尚未完成认证"
        case .invalidResponse: "蓝牙 Agent 响应无效"
        case .authenticationFailed: "蓝牙消息认证失败"
        case .commandTimedOut: "蓝牙命令响应超时"
        case .disconnected: "蓝牙连接已断开"
        case let .bluetooth(message): message
        }
    }
}

@MainActor
final class VoBLECentralController: NSObject, ObservableObject, VoBLECentralControlling, VoBLEMediaWriting {
    static let serviceUUID = CBUUID(string: "7e57a000-7a17-4d9f-9a3c-41a17b1e0001")
    static let capabilityUUID = CBUUID(string: "7e57a001-7a17-4d9f-9a3c-41a17b1e0001")
    static let pairingUUID = CBUUID(string: "7e57a002-7a17-4d9f-9a3c-41a17b1e0001")
    static let controlRXUUID = CBUUID(string: "7e57a003-7a17-4d9f-9a3c-41a17b1e0001")
    static let controlTXUUID = CBUUID(string: "7e57a004-7a17-4d9f-9a3c-41a17b1e0001")
    static let audioUplinkUUID = CBUUID(string: "7e57a005-7a17-4d9f-9a3c-41a17b1e0001")
    static let audioDownlinkUUID = CBUUID(string: "7e57a006-7a17-4d9f-9a3c-41a17b1e0001")
    static let diagnosticsUUID = CBUUID(string: "7e57a007-7a17-4d9f-9a3c-41a17b1e0001")

    @Published private(set) var state: VoBLEConnectionState = .stopped
    @Published private(set) var discoveredPeers: [VoBLEDiscoveredPeer] = []
    @Published private(set) var pendingSAS: String?
    @Published private(set) var authenticatedIdentity: String?
    @Published private(set) var errorMessage: String?
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?

    private struct PairingAttempt {
        let challengeID: String, androidIdentity: String
        let iphonePublic: Data, iphoneNonce: Data
        let transcript: VoBLEPairingTranscript
        let material: VoBLEPairingMaterial
    }
    private struct WriteBatch { let characteristic: CBCharacteristic; let fragments: [Data]; var index: Int }
    private struct PendingCommand {
        let generation: UInt64
        let continuation: CheckedContinuation<VoBLEControlResponse, Error>
        let timeout: Task<Void, Never>
    }

    private var reducer = VoBLEConnectionReducer()
    private var central: CBCentralManager?
    private var enabled = false
    private var attemptedStoredRestore = false
    private var peripheral: CBPeripheral?
    private var capability: CBCharacteristic?
    private var pairing: CBCharacteristic?
    private var controlRX: CBCharacteristic?
    private var controlTX: CBCharacteristic?
    private(set) var audioUplink: CBCharacteristic?
    private(set) var audioDownlink: CBCharacteristic?
    private var diagnostics: CBCharacteristic?
    private var pairingSubscribed = false
    private var pairingStarted = false
    private var pairingAttempt: PairingAttempt?
    private var pairingReassembler = VoBLEMessageReassembler()
    private var controlReassembler = VoBLEMessageReassembler()
    private var replayWindow = VoBLEReplayWindow()
    private var writeBatches: [WriteBatch] = []
    private var messageID: UInt16 = 0
    private var sessionID = Data()
    private var activePeer: VoBLEStoredPeer?
    private var pendingCommands: [String: PendingCommand] = [:]
    private let pairingStore: VoBLEPairingStore
    private let peripheralPreferenceKey = "airsim.voble.peripheral-id"

    init(pairingStore: VoBLEPairingStore = VoBLEPairingStore()) {
        self.pairingStore = pairingStore
        super.init()
    }

    func start() {
        enabled = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.eric3u.airsim.voble.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        } else if central?.state == .poweredOn { restoreOrScan() }
    }

    func stop() {
        enabled = false; attemptedStoredRestore = false; central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        failPending(with: VoBLECentralError.disconnected)
        resetConnection(); apply(.stopped)
    }

    func connect(_ peer: VoBLEDiscoveredPeer) {
        guard enabled, let central,
              let selected = central.retrievePeripherals(withIdentifiers: [peer.id]).first else { return }
        connect(selected, restored: false)
    }

    func confirmPairing() {
        guard let attempt = pairingAttempt, pendingSAS == attempt.material.sas else { return }
        sendPairingConfirmation(attempt: attempt, reconnectTag: nil)
    }

    func cancelPairing() {
        pairingAttempt = nil; pendingSAS = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    func revokeCurrentPeer() {
        guard let identity = activePeer?.identity ?? pairingAttempt?.androidIdentity else { return }
        try? pairingStore.revoke(identity: identity)
        UserDefaults.standard.removeObject(forKey: peripheralPreferenceKey)
        activePeer = nil; authenticatedIdentity = nil; stop()
    }

    func send(command: String, callID: String = "", generation: UInt64 = 0, number: String = "") async throws -> VoBLEControlResponse {
        guard state == .ready, let peer = activePeer, !sessionID.isEmpty,
              let controlRX else { throw VoBLECentralError.notReady }
        let requestID = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let nonce = try randomData(count: 12)
        let body = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "timestamp_ms": timestamp, "number": number,
        ])
        let keys = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: peer.pairingKey, sessionID: sessionID, callID: callID, generation: generation)
        let unsigned = VoBLEControlEnvelope(
            command: command, callID: callID, generation: generation,
            sessionID: sessionID, nonce: nonce, ciphertext: body,
            authenticationTag: Data(repeating: 0, count: 16))
        let prefix = try unsigned.encoded().dropLast(16)
        let tag = try VoBLESessionAuthenticator.tag(
            message: authenticationMessage(nonce: nonce, timestampMillis: timestamp, payload: Data(prefix)),
            key: keys.control)
        let encoded = try VoBLEControlEnvelope(
            command: command, callID: callID, generation: generation,
            sessionID: sessionID, nonce: nonce, ciphertext: body, authenticationTag: tag).encoded()

        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.timeoutCommand(requestID)
            }
            pendingCommands[requestID] = PendingCommand(
                generation: generation, continuation: continuation, timeout: timeout)
            do { try enqueueMessage(encoded, type: .control, characteristic: controlRX) }
            catch {
                pendingCommands.removeValue(forKey: requestID)?.timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    func mediaKey(callID: String, generation: UInt64) throws -> Data {
        guard state == .ready, let peer = activePeer, !sessionID.isEmpty else {
            throw VoBLECentralError.notReady
        }
        return try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: peer.pairingKey, sessionID: sessionID,
            callID: callID, generation: generation).media
    }

    var canSendWriteWithoutResponse: Bool {
        peripheral?.canSendWriteWithoutResponse == true && audioUplink != nil
    }

    var maximumWriteLength: Int {
        peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
    }

    func writeWithoutResponse(_ data: Data) {
        guard let peripheral, let audioUplink else { return }
        peripheral.writeValue(data, for: audioUplink, type: .withoutResponse)
    }

    private func restoreOrScan() {
        guard enabled, let central, central.state == .poweredOn else { return }
        if !attemptedStoredRestore,
           let raw = UserDefaults.standard.string(forKey: peripheralPreferenceKey),
           let id = UUID(uuidString: raw),
           let restored = central.retrievePeripherals(withIdentifiers: [id]).first {
            attemptedStoredRestore = true
            connect(restored, restored: true); return
        }
        discoveredPeers.removeAll(); apply(.bluetoothPoweredOn)
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }

    private func connect(_ value: CBPeripheral, restored: Bool) {
        central?.stopScan(); resetConnection(keepingPeripheral: true)
        peripheral = value; value.delegate = self
        apply(restored ? .restored(value.identifier) : .discovered(value.identifier))
        central?.connect(value)
    }

    private func resetConnection(keepingPeripheral: Bool = false) {
        pairing = nil; controlRX = nil; controlTX = nil; audioUplink = nil; audioDownlink = nil
        diagnostics = nil; capability = nil; pairingSubscribed = false; pairingStarted = false
        pairingAttempt = nil; pendingSAS = nil; authenticatedIdentity = nil; activePeer = nil
        sessionID.removeAll(); pairingReassembler = VoBLEMessageReassembler()
        controlReassembler = VoBLEMessageReassembler(); replayWindow = VoBLEReplayWindow()
        writeBatches.removeAll(); if !keepingPeripheral { peripheral = nil }
    }

    private func apply(_ event: VoBLEConnectionEvent) {
        reducer.apply(event); state = reducer.state
        if case let .failed(message) = state { errorMessage = message } else { errorMessage = nil }
    }

    private func beginPairingIfPossible() {
        guard pairingSubscribed, !pairingStarted, let pairing else { return }
        pairingStarted = true
        do {
            try enqueueMessage(JSONSerialization.data(withJSONObject: ["op": "begin"]),
                               type: .pairing, characteristic: pairing)
        } catch { failAuthentication(error.localizedDescription) }
    }

    private func handlePairingMessage(_ data: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoBLECentralError.invalidResponse }
            if object["ready"] as? Bool == true {
                guard let attempt = pairingAttempt,
                      let confirmation = decodeBase64(object["confirmation_tag"] as? String),
                      VoBLESessionAuthenticator.authenticate(
                        message: Data("AirSIM/VoBLE/v1/ready\(attempt.challengeID)".utf8),
                        tag: confirmation, key: attempt.material.pairingKey
                      ) else { throw VoBLECentralError.authenticationFailed }
                try finishPairing()
                return
            }
            if object["ok"] as? Bool == false { throw VoBLECentralError.bluetooth(object["error"] as? String ?? "蓝牙配对失败") }
            if object["op"] as? String == "prepare" {
                guard let attempt = pairingAttempt,
                      let remoteSAS = object["sas"] as? String,
                      remoteSAS == attempt.material.sas else {
                    throw VoBLECentralError.authenticationFailed
                }
                pendingSAS = remoteSAS
                return
            }
            guard object["op"] as? String == "begin",
                  let challengeID = object["challenge_id"] as? String,
                  let identity = object["android_identity"] as? String,
                  let androidPublic = decodeBase64(object["android_public"] as? String),
                  let androidNonce = decodeBase64(object["android_nonce"] as? String),
                  androidPublic.count == 32, androidNonce.count == 32 else { throw VoBLECentralError.invalidResponse }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicData = privateKey.publicKey.rawRepresentation
            let iphoneNonce = try randomData(count: 32)
            let transcript = VoBLEPairingTranscript(
                androidIdentity: identity, androidPublicKey: androidPublic,
                iphonePublicKey: publicData, androidNonce: androidNonce, iphoneNonce: iphoneNonce)
            let material = try VoBLESessionAuthenticator.derivePairing(
                privateKey: privateKey.rawRepresentation, peerPublicKey: androidPublic, transcript: transcript)
            let attempt = PairingAttempt(
                challengeID: challengeID, androidIdentity: identity, iphonePublic: publicData,
                iphoneNonce: iphoneNonce, transcript: transcript, material: material)
            pairingAttempt = attempt
            if let stored = try pairingStore.load(identity: identity) {
                sendPairingConfirmation(attempt: attempt, reconnectTag:
                    try VoBLESessionAuthenticator.reconnectTag(pairingKey: stored.pairingKey, transcript: transcript))
            } else { try sendPairingPreparation(attempt) }
        } catch { failAuthentication(error.localizedDescription) }
    }

    private func sendPairingPreparation(_ attempt: PairingAttempt) throws {
        guard let pairing else { throw VoBLECentralError.disconnected }
        try enqueueMessage(JSONSerialization.data(withJSONObject: [
            "op": "prepare", "challenge_id": attempt.challengeID,
            "iphone_public": encodeBase64(attempt.iphonePublic),
            "iphone_nonce": encodeBase64(attempt.iphoneNonce),
        ]), type: .pairing, characteristic: pairing)
    }

    private func sendPairingConfirmation(attempt: PairingAttempt, reconnectTag: Data?) {
        guard let pairing else { return }
        do {
            var object: [String: Any] = [
                "op": "confirm", "challenge_id": attempt.challengeID,
                "iphone_public": encodeBase64(attempt.iphonePublic),
                "iphone_nonce": encodeBase64(attempt.iphoneNonce),
            ]
            if let reconnectTag { object["reconnect_tag"] = encodeBase64(reconnectTag) }
            else { object["sas"] = attempt.material.sas }
            try enqueueMessage(JSONSerialization.data(withJSONObject: object), type: .pairing, characteristic: pairing)
            pendingSAS = nil
        } catch { failAuthentication(error.localizedDescription) }
    }

    private func finishPairing() throws {
        guard let attempt = pairingAttempt, let peripheral else { throw VoBLECentralError.invalidResponse }
        let peer = VoBLEStoredPeer(identity: attempt.androidIdentity, pairingKey: attempt.material.pairingKey, createdAt: Date())
        try pairingStore.save(peer); activePeer = peer; authenticatedIdentity = peer.identity
        sessionID = try randomData(count: 16); replayWindow = VoBLEReplayWindow()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: peripheralPreferenceKey)
        attemptedStoredRestore = false
        pairingAttempt = nil; pendingSAS = nil; apply(.authenticated(identity: peer.identity))
    }

    private func failAuthentication(_ message: String) {
        pairingAttempt = nil; pendingSAS = nil; apply(.authenticationFailed(message))
    }

    private func enqueueMessage(_ data: Data, type: VoBLEMessageType, characteristic: CBCharacteristic) throws {
        guard let peripheral else { throw VoBLECentralError.disconnected }
        messageID &+= 1
        let fragments = try VoBLEMessageFragmenter.encode(
            data, type: type, messageID: messageID,
            maximumPacketLength: max(20, peripheral.maximumWriteValueLength(for: .withResponse)))
        writeBatches.append(WriteBatch(characteristic: characteristic, fragments: fragments, index: 0))
        if writeBatches.count == 1 { writeNext() }
    }

    private func writeNext() {
        guard let peripheral, let batch = writeBatches.first, batch.index < batch.fragments.count else { return }
        peripheral.writeValue(batch.fragments[batch.index], for: batch.characteristic, type: .withResponse)
    }

    private func handleControlMessage(_ data: Data) {
        do {
            let envelope = try VoBLEControlEnvelope.decode(data)
            guard let peer = activePeer,
                  let body = try JSONSerialization.jsonObject(with: envelope.ciphertext) as? [String: Any],
                  let timestampValue = body["timestamp_ms"] as? NSNumber else { throw VoBLECentralError.invalidResponse }
            let timestamp = timestampValue.int64Value
            let keys = try VoBLESessionAuthenticator.deriveSessionKeys(
                pairingKey: peer.pairingKey, sessionID: envelope.sessionID,
                callID: envelope.callID, generation: envelope.generation)
            guard VoBLESessionAuthenticator.authenticate(
                message: authenticationMessage(nonce: envelope.nonce, timestampMillis: timestamp, payload: Data(data.dropLast(16))),
                tag: envelope.authenticationTag, key: keys.control),
                  replayWindow.accept(nonce: envelope.nonce,
                    timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1_000)) else { throw VoBLECentralError.authenticationFailed }
            if envelope.command == "response", let requestID = body["request_id"] as? String {
                guard let pending = pendingCommands[requestID], pending.generation == envelope.generation else { return }
                pendingCommands.removeValue(forKey: requestID); pending.timeout.cancel()
                pending.continuation.resume(returning: VoBLEControlResponse(
                    requestID: requestID, generation: envelope.generation,
                    success: body["ok"] as? Bool ?? false,
                    code: body["code"] as? String ?? "invalid_response",
                    detail: body["detail"] as? String ?? ""))
            } else if envelope.command == "call_state" {
                onEvent?(VoBLEAndroidEvent(
                    callID: envelope.callID, generation: envelope.generation,
                    direction: body["direction"] as? String ?? "", state: body["state"] as? String ?? "",
                    number: body["number"] as? String ?? ""))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func timeoutCommand(_ id: String) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: VoBLECentralError.commandTimedOut)
    }
    private func failPending(with error: Error) {
        let values = Array(pendingCommands.values); pendingCommands.removeAll()
        for pending in values { pending.timeout.cancel(); pending.continuation.resume(throwing: error) }
    }
    private func authenticationMessage(nonce: Data, timestampMillis: Int64, payload: Data) -> Data {
        var result = Data([UInt8(truncatingIfNeeded: nonce.count >> 8), UInt8(truncatingIfNeeded: nonce.count)])
        result.append(nonce); var timestamp = UInt64(bitPattern: timestampMillis).bigEndian
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }; result.append(payload); return result
    }
    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VoBLECentralError.authenticationFailed }; return data
    }
    private func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func decodeBase64(_ input: String?) -> Data? {
        guard var value = input else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4); return Data(base64Encoded: value)
    }
}

extension VoBLECentralController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled else { return }; central.state == .poweredOn ? restoreOrScan() : apply(.bluetoothUnavailable)
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard enabled, let values = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let value = values.first else { return }; connect(value, restored: true)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peer = VoBLEDiscoveredPeer(id: peripheral.identifier,
            name: (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "AirSIM Android",
            signal: RSSI.intValue)
        if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) { discoveredPeers[index] = peer }
        else { discoveredPeers.append(peer) }
        if self.peripheral == nil { connect(peripheral, restored: false) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        apply(.connected); peripheral.discoverServices([Self.serviceUUID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetConnection()
        apply(.disconnected(error?.localizedDescription ?? "蓝牙连接失败")); if enabled { restoreOrScan() }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        handleDisconnect(error: error, isReconnecting: false)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleDisconnect(error: error, isReconnecting: isReconnecting)
    }
    private func handleDisconnect(error: Error?, isReconnecting: Bool) {
        failPending(with: VoBLECentralError.disconnected); resetConnection()
        attemptedStoredRestore = false
        apply(.disconnected(error?.localizedDescription)); if enabled, !isReconnecting { restoreOrScan() }
    }
}

extension VoBLECentralController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            apply(.authenticationFailed("未发现 AirSIM 蓝牙服务")); return
        }
        peripheral.discoverCharacteristics([Self.capabilityUUID, Self.pairingUUID, Self.controlRXUUID,
            Self.controlTXUUID, Self.audioUplinkUUID, Self.audioDownlinkUUID, Self.diagnosticsUUID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        for value in service.characteristics ?? [] {
            switch value.uuid {
            case Self.capabilityUUID: capability = value; peripheral.readValue(for: value)
            case Self.pairingUUID: pairing = value; peripheral.setNotifyValue(true, for: value)
            case Self.controlRXUUID: controlRX = value
            case Self.controlTXUUID: controlTX = value; peripheral.setNotifyValue(true, for: value)
            case Self.audioUplinkUUID: audioUplink = value
            case Self.audioDownlinkUUID: audioDownlink = value; peripheral.setNotifyValue(true, for: value)
            case Self.diagnosticsUUID: diagnostics = value; peripheral.setNotifyValue(true, for: value)
            default: break
            }
        }
        guard pairing != nil, controlRX != nil, controlTX != nil, audioUplink != nil, audioDownlink != nil else {
            apply(.authenticationFailed("AirSIM 蓝牙特征不完整")); return
        }
        apply(.characteristicsReady)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        if characteristic.uuid == Self.pairingUUID { pairingSubscribed = characteristic.isNotifying; beginPairingIfPossible() }
        else if characteristic.uuid == Self.controlTXUUID { apply(.controlSubscription(characteristic.isNotifying)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        do {
            if characteristic.uuid == Self.pairingUUID, let message = try pairingReassembler.append(value) {
                guard message.type == .pairing else { throw VoBLECentralError.invalidResponse }; handlePairingMessage(message.payload)
            } else if characteristic.uuid == Self.controlTXUUID, let message = try controlReassembler.append(value) {
                guard message.type == .control else { throw VoBLECentralError.invalidResponse }; handleControlMessage(message.payload)
            } else if characteristic.uuid == Self.audioDownlinkUUID {
                onAudioDownlinkFragment?(value)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !writeBatches.isEmpty else { return }
        if let error { writeBatches.removeAll(); failAuthentication(error.localizedDescription); return }
        writeBatches[0].index += 1
        if writeBatches[0].index >= writeBatches[0].fragments.count { writeBatches.removeFirst() }
        writeNext()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        onReadyToSendAudio?()
    }
}
