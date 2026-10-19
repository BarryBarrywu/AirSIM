import Combine
import Foundation
import CoreBluetooth
import UIKit

@MainActor
final class VoBLEDeviceSession {
    let central: VoBLECentralController
    let media: VoBLEGATTMediaTransport
    let audio: VoBLEAudioEngine
    let calls: VoBLECallCoordinator

    init(central: VoBLECentralController) {
        self.central = central
        media = VoBLEGATTMediaTransport(writer: central)
        audio = VoBLEAudioEngine(transport: media)
        calls = VoBLECallCoordinator(central: central, media: media, audio: audio)
    }
}

@MainActor
final class VoBLEDeviceHub: ObservableObject, VoBLECentralControlling {
    let radio: VoBLERadioController
    let placeholder: VoBLEDeviceSession
    @Published private(set) var selectedPeripheralID: UUID?
    private(set) var sessions: [UUID: VoBLEDeviceSession] = [:]
    var onSessionCreated: ((VoBLEDeviceSession) -> Void)?
    var onCallEvent: ((DeviceCallEvent) -> Void)?
    private let pairingStore: any VoBLEPairingStoring
    private let knownPeripheral: (UUID) -> Bool
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    private var radioObservation: AnyCancellable?
    @Published private var enabled = false
    private var handshake: UUID?
    private var pending: [VoBLEDiscoveredPeer] = []

    init(radio: VoBLERadioController? = nil, pairingStore: any VoBLEPairingStoring = VoBLEPairingStore(),
         knownPeripheral: ((UUID) -> Bool)? = nil) {
        self.radio = radio ?? VoBLERadioController()
        self.pairingStore = pairingStore
        self.knownPeripheral = knownPeripheral ?? { id in
            PairedAndroidDeviceStore.records().contains { PairedAndroidDeviceStore.peripheralID(for: $0.id) == id }
        }
        placeholder = VoBLEDeviceSession(central: VoBLECentralController(radio: self.radio, pairingStore: pairingStore))
        radioObservation = self.radio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.radio.onDiscovered = { [weak self] peer in self?.discover(peer) }
        self.radio.onRestored = { [weak self] id in
            guard let self, self.isKnown(id) else { return }
            // The radio forwards the actual OS peripheral immediately after
            // this callback; cached IDs alone never mark a session ready.
            self.prepare(peripheralID: id).central.start()
        }
    }
    var selected: VoBLEDeviceSession { selectedPeripheralID.flatMap { sessions[$0] } ?? placeholder }
    /// Discovery UI only: the placeholder is not an authenticated peer/session.
    var pairingState: VoBLEConnectionState {
        if selectedPeripheralID != nil, selected.central.state != .stopped { return selected.central.state }
        guard enabled else { return .stopped }
        return radio.poweredOn ? .scanning : .bluetoothUnavailable
    }
    func start() {
        if !enabled { enabled = true }
        for value in sessions.values { value.central.start() }
        radio.start()
        syncMediaScanPolicy()
    }

    /// Keep the shared scanner off while any session is carrying call audio.
    /// Continuous scanning steals radio time from the BLE media connection and
    /// backs up the uplink queue; pause while audio runs, resume when idle.
    private func syncMediaScanPolicy() {
        if sessions.values.contains(where: { $0.audio.running }) {
            radio.pauseScanForMedia()
        } else {
            radio.resumeScanAfterMedia()
        }
    }
    func restoreInBackgroundIfAuthorized() {
        guard UIApplication.shared.applicationState == .background,
              CBManager.authorization == .allowedAlways else { return }
        setApplicationIsBackground(true)
        start()
    }
    func setApplicationIsBackground(_ value: Bool) {
        for session in sessions.values { session.central.setApplicationIsBackground(value) }
    }
    func stop() { stop(except: nil) }
    func stop(except agentID: String?) {
        if enabled { enabled = false }
        pending.removeAll(); handshake = nil
        for (id, value) in sessions where value.central.authenticatedIdentity != agentID || agentID == nil {
            value.central.stop()
            radio.cancel(peripheralID: id)
        }
        if agentID == nil { radio.stop() }
    }
    func select(peripheralID: UUID) {
        guard sessions[peripheralID] != nil else { return }
        selectedPeripheralID = peripheralID
    }
    func session(for agentID: String) -> VoBLECentralController? { bundle(for: agentID)?.central }
    func bundle(for agentID: String) -> VoBLEDeviceSession? {
        sessions.values.first { $0.central.state == .ready && $0.central.authenticatedIdentity == agentID }
    }
    func retainedBundle(for agentID: String) -> VoBLEDeviceSession? {
        sessions.values.first { $0.central.authenticatedIdentity == agentID || $0.central.recoverableIdentity == agentID }
    }
    func connect(_ peer: VoBLEDiscoveredPeer) {
        start()
        let value = prepare(peripheralID: peer.id)
        selectedPeripheralID = peer.id
        value.central.start()
        value.central.connect(peer)
    }
    func forget(agentID: String) async throws {
        guard let pair = sessions.first(where: {
            $0.value.central.authenticatedIdentity == agentID || $0.value.central.recoverableIdentity == agentID
        }) else {
            try await VoBLEPairingWorker(store: pairingStore).revoke(identity: agentID)
            return
        }
        let (id, value) = pair
        try await value.central.forgetDevice(agentID)
        value.central.stop()
        radio.cancel(peripheralID: id)
        sessions.removeValue(forKey: id)
        observations.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        if selectedPeripheralID == id { selectedPeripheralID = nil }
        if handshake == id { handshake = nil; nextHandshake() }
        syncMediaScanPolicy()
        objectWillChange.send()
    }
    @discardableResult
    func prepare(peripheralID: UUID) -> VoBLEDeviceSession {
        if let existing = sessions[peripheralID] { return existing }
        let value = VoBLEDeviceSession(central: VoBLECentralController(radio: radio,
            peripheralID: peripheralID, pairingStore: pairingStore))
        sessions[peripheralID] = value
        value.calls.mediaPermission = { _ in false }
        onSessionCreated?(value)
        var subscriptions = Set<AnyCancellable>()
        value.central.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak value] state in
            guard let self, let value, value.central.state == state else { return }
            self.objectWillChange.send()
            if state == .ready, self.selectedPeripheralID == nil { self.selectedPeripheralID = peripheralID }
            if self.handshake == peripheralID, state == .ready || state == .stopped || {
                if case .failed = state { return true }; return false
            }() {
                self.handshake = nil; self.nextHandshake()
            }
        }.store(in: &subscriptions)
        value.central.$deviceInformation.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        // The pairing sheet reads pendingSAS/errorMessage directly from the
        // selected central. Those @Published fields are not mirrored by $state,
        // so without this forward the six-digit code appears only after another
        // tap changes selectedPeripheralID and forces a re-render.
        value.central.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        value.audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.syncMediaScanPolicy()
        }.store(in: &subscriptions)
        observations[peripheralID] = subscriptions
        return value
    }

    private func isKnown(_ id: UUID) -> Bool {
        knownPeripheral(id)
    }
    private func discover(_ peer: VoBLEDiscoveredPeer) {
        guard enabled, isKnown(peer.id), !pending.contains(where: { $0.id == peer.id }),
              sessions[peer.id]?.central.state != .ready, handshake != peer.id else { return }
        pending.append(peer)
        nextHandshake()
    }
    private func nextHandshake() {
        guard enabled, handshake == nil, !pending.isEmpty else { return }
        let peer = pending.removeFirst()
        handshake = peer.id
        let value = prepare(peripheralID: peer.id)
        value.central.start()
        value.central.connect(peer)
    }
}
