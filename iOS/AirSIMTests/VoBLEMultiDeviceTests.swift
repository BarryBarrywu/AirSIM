import XCTest
import CoreBluetooth
import CryptoKit
@testable import AirSIM

@MainActor
final class VoBLEMultiDeviceTests: XCTestCase {
    private func authenticate(_ session: VoBLECentralController, as identity: String) {
        session.apply(.discovered(session.targetPeripheralID!))
        session.apply(.connected)
        session.apply(.characteristicsReady)
        session.apply(.controlSubscription(true))
        // Trusted result of the authenticated GATT boundary. The protocol's
        // transcript, SAS and crypto are exercised by the pairing tests.
        session.apply(.authenticated(identity: identity))
    }

    func testCallKitActivationNeverActivatesPassiveBLEForWLANOwner() async throws {
        let io = RadioIOProbe(), id = UUID()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: id)
        authenticate(session.central, as: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ModeExitBackend() }, bluetoothHub: hub)
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        session.central.onEvent?(.init(callID: "fixture", generation: 1, direction: "outgoing", state: "active", number: ""))
        XCTAssertNotNil(session.calls.currentIdentity)
        await model.callKitAudioSessionDidActivate()
        XCTAssertFalse(session.audio.callKitAudioActive)
        model.callKitAudioSessionDidDeactivate()
        await model.hangup()
    }
    func testNormalDisconnectRestartsDuplicateSuppressedScanWithoutDroppingB() {
        let io = RadioIOProbe()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        hub.start()
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        let before = io.scans
        a.central.apply(.disconnected(nil))
        XCTAssertEqual(io.scans, before + 1)
        XCTAssertEqual(b.central.state, .ready)
        XCTAssertTrue(io.cancelled.isEmpty)
        hub.stop()
    }

    func testTwoAuthenticatedSessionsStayConnectedWhenDefaultChanges() {
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let aID = UUID(), bID = UUID()
        let a = hub.prepare(peripheralID: aID), b = hub.prepare(peripheralID: bID)
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        hub.select(peripheralID: aID)
        XCTAssertTrue(hub.session(for: "A") === a.central)
        hub.select(peripheralID: bID)
        XCTAssertTrue(hub.selected === b)
        XCTAssertTrue(hub.session(for: "A") === a.central)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertEqual(b.central.state, .ready)
        XCTAssertTrue(io.cancelled.isEmpty)
    }

    func testDisconnectBDoesNotDemoteAAuthenticatedSession() {
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        b.central.stop()
        XCTAssertTrue(hub.session(for: "A") === a.central)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertNil(hub.session(for: "B"))
    }

    func testDisconnectBDoesNotFailAPendingCommand() async throws {
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        let sent = expectation(description: "A control request sent")
        let reply = Task { try await a.central.commandMailbox.perform(requestID: "A-request", generation: 7,
            write: { sent.fulfill() }) }
        await fulfillment(of: [sent], timeout: 1)
        b.central.stop()
        a.central.commandMailbox.resolve(.init(requestID: "A-request", generation: 7,
            success: true, code: "ok", detail: "A-only"))
        let result = try await reply.value
        XCTAssertEqual(result.detail, "A-only")
    }

    func testRevokeBDoesNotStopSharedScanOrDisconnectA() async throws {
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let aID = UUID(), bID = UUID()
        let a = hub.prepare(peripheralID: aID), b = hub.prepare(peripheralID: bID)
        hub.start()
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        try await hub.forget(agentID: "B")
        XCTAssertTrue(radio.scanning)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertNil(hub.session(for: "B"))
        XCTAssertFalse(io.cancelled.contains(aID))
    }

    func testRestoreAdoptsEveryEligibleOSPeripheralAndRequiresFreshAuth() {
        let ids = [UUID(), UUID()]
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { ids.contains($0) })
        hub.start()
        radio.restore(peripheralIDs: ids + [UUID()])
        XCTAssertEqual(hub.sessions.count, 2)
        XCTAssertNil(hub.session(for: "A"))
        XCTAssertNil(hub.session(for: "B"))
        XCTAssertTrue(ids.allSatisfy { hub.sessions[$0]?.central.authenticatedIdentity == nil })
    }

    func testDeferredBluetoothModeExitStopsRadioWhenOwnedCallEnds() async throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(previous) }
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ModeExitBackend() }, bluetoothHub: hub)
        hub.start()
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        model.setConnectionMode(.vowlan)
        XCTAssertTrue(radio.scanning, "keep active Bluetooth lane until terminal")
        await model.hangup()
        XCTAssertFalse(radio.scanning, "release deferred Bluetooth resources after terminal")
        model.stop()
    }

    func testModeExitKeepsAuthenticatedCentralUntilHangupCommandCompletes() async throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(previous) }
        let io = RadioIOProbe(), id = UUID()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: id)
        authenticate(session.central, as: "A")
        let backend = ModeExitBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, bluetoothHub: hub)
        hub.start()
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        model.setConnectionMode(.vowlan)
        backend.onEnd = {
            XCTAssertEqual(session.central.state, .ready, "end must reach an authenticated live transport")
            XCTAssertFalse(io.cancelled.contains(id), "UI retirement must not disconnect before sending")
            XCTAssertNil(model.deviceCalls.active, "presentation still retires before network I/O")
            model.setConnectionMode(.cloud)
            model.setConnectionMode(.vowlan)
            await Task.yield()
            XCTAssertEqual(session.central.state, .ready, "keep the lane until the command reply")
        }
        await model.hangup()
        XCTAssertEqual(session.central.state, .stopped)
        XCTAssertFalse(hub.radio.scanning)
        model.stop()
    }

    func testBluetoothToggleDoesNotRestoreOnlyFirstPeer() {
        let ids = [UUID(), UUID()]
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { ids.contains($0) })
        hub.start()
        radio.restore(peripheralIDs: ids)
        XCTAssertEqual(hub.sessions.count, 2)
        hub.stop(); hub.start()
        radio.restore(peripheralIDs: ids)
        XCTAssertEqual(hub.sessions.count, 2)
        XCTAssertTrue(hub.sessions.values.allSatisfy { $0.central.state != .ready })
        XCTAssertEqual(io.connected.count, 0)
    }

    func testStandbyPeersNeverRequestPCM() async {
        let central = CallControlBoundary()
        let writer = VoBLECentralController(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let media = VoBLEGATTMediaTransport(writer: writer)
        let audio = VoBLEAudioEngine(transport: media)
        let calls = VoBLECallCoordinator(central: central, media: media, audio: audio)
        var authorizationChecks = 0
        calls.mediaPermission = { _ in authorizationChecks += 1; return false }
        central.onEvent?(.init(callID: "local-android-answer", generation: 2,
            direction: "incoming", state: "active", number: ""))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertFalse(media.isRunning)
        XCTAssertFalse(audio.running)
        XCTAssertTrue(central.commands.isEmpty)
    }

    func testOutgoingOwnershipIsReservedBeforeCommandCanReply() async throws {
        let central = CallControlBoundary()
        let writer = VoBLECentralController(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let media = VoBLEGATTMediaTransport(writer: writer)
        let calls = VoBLECallCoordinator(central: central, media: media, audio: VoBLEAudioEngine(transport: media))
        var intent = false
        calls.onOutgoingIntent = { _ in intent = true }
        central.beforeSend = { XCTAssertTrue(intent) }
        _ = try await calls.startOutgoing(number: "test")
        XCTAssertEqual(central.commands, ["dial"])
    }

    func testPairingWorkAndCredentialIOStayOffMainThreadForBothPeers() async throws {
        let store = MemoryPairings()
        let android = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let workers = [VoBLEPairingWorker(store: store), VoBLEPairingWorker(store: store)]
        for (index, worker) in workers.enumerated() {
            let identity = "fixture-\(index)"
            let result = try await worker.prepare(identity: identity, androidPublic: android,
                androidNonce: Data(repeating: UInt8(index + 1), count: 32))
            try await worker.save(.init(identity: identity, pairingKey: result.material.pairingKey, createdAt: Date()))
        }
        XCTAssertEqual(store.mainThreadObservations.count, 4)
        XCTAssertFalse(store.mainThreadObservations.contains(true))
    }
}

@MainActor
private final class ModeExitBackend: DeviceCallBackend {
    let epoch: UInt64 = 1
    var onEnd: () async -> Void = {}
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        .init(callID: "fixture", backendID: "fixture", generation: nil)
    }
    func answer(callID: String, generation: UInt64?) async throws {}
    func end(callID: String, generation: UInt64?, reject: Bool) async throws { await onEnd() }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {}
}

private final class MemoryPairings: VoBLEPairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    var mainThreadObservations: [Bool] { lock.withLock { observations } }
    func save(_ peer: VoBLEStoredPeer) throws { lock.withLock { observations.append(Thread.isMainThread) } }
    func load(identity: String) throws -> VoBLEStoredPeer? {
        lock.withLock { observations.append(Thread.isMainThread) }; return nil
    }
    func revoke(identity: String) throws {}
}

@MainActor
private final class CallControlBoundary: VoBLECallControlling {
    var state: VoBLEConnectionState = .ready
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?
    var commands: [String] = []
    var beforeSend: () -> Void = {}
    func send(command: String, callID: String, generation: UInt64, number: String) async throws -> VoBLEControlResponse {
        beforeSend(); commands.append(command)
        return .init(requestID: "fixture", generation: generation, success: true, code: "ok", detail: "accepted")
    }
    func mediaKey(callID: String, generation: UInt64) throws -> Data { Data(repeating: 1, count: 32) }
}

@MainActor
private final class RadioIOProbe: VoBLERadioIO {
    var manager: CBCentralManager? { nil }
    var poweredOn = true
    var cancelled: [UUID] = []
    var connected: [UUID] = []
    var scans = 0
    var stops = 0
    func start(delegate: any CBCentralManagerDelegate) {}
    func scan() { scans += 1 }
    func stopScan() { stops += 1 }
    func connect(_ id: UUID) { connected.append(id) }
    func cancel(_ id: UUID) { cancelled.append(id) }
    func peripheral(_ id: UUID) -> CBPeripheral? { nil }
}
