import Combine
import CoreBluetooth
import Foundation

/// The OS boundary is injectable; connection/authentication state remains in
/// the real per-peripheral controller, not in a mock central manager.
@MainActor
protocol VoBLERadioIO: AnyObject {
    var manager: CBCentralManager? { get }
    var poweredOn: Bool { get }
    func start(delegate: any CBCentralManagerDelegate)
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    func cancel(_ id: UUID)
    func peripheral(_ id: UUID) -> CBPeripheral?
}

@MainActor
final class VoBLESystemRadioIO: VoBLERadioIO {
    private(set) var manager: CBCentralManager?
    var poweredOn: Bool { manager?.state == .poweredOn }
    func start(delegate: any CBCentralManagerDelegate) {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: delegate, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.eric3u.airsim.voble.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }
    func scan() {
        manager?.scanForPeripherals(withServices: [VoBLECentralController.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func stopScan() { manager?.stopScan() }
    func peripheral(_ id: UUID) -> CBPeripheral? {
        manager?.retrievePeripherals(withIdentifiers: [id]).first
    }
    func connect(_ id: UUID) {
        guard let value = peripheral(id) else { return }
        var options: [String: Any] = [:]
        if #available(iOS 17.0, *) { options[CBConnectPeripheralOptionEnableAutoReconnect] = true }
        manager?.connect(value, options: options)
    }
    func cancel(_ id: UUID) {
        guard let value = peripheral(id) else { return }
        manager?.cancelPeripheralConnection(value)
    }
}

/// One manager and one scan for the whole app. Cancellation is always scoped
/// to an OS peripheral; a session never owns or stops the shared scanner.
@MainActor
final class VoBLERadioController: NSObject, ObservableObject {
    @Published private(set) var discoveredPeers: [VoBLEDiscoveredPeer] = []
    var onDiscovered: ((VoBLEDiscoveredPeer) -> Void)?
    var onRestored: ((UUID) -> Void)?
    private let io: any VoBLERadioIO
    private final class WeakSession {
        weak var value: VoBLECentralController?
        init(_ value: VoBLECentralController) { self.value = value }
    }
    private var sessions: [UUID: WeakSession] = [:]
    private var enabled = false
    private var recoveryScan: Task<Void, Never>?
    private var lastRecoveryScan = Date.distantPast
    private(set) var scanning = false
    var poweredOn: Bool { io.poweredOn }
    var manager: CBCentralManager? { io.manager }

    init(io: (any VoBLERadioIO)? = nil) { self.io = io ?? VoBLESystemRadioIO(); super.init() }

    func attach(_ session: VoBLECentralController, peripheralID: UUID) {
        sessions[peripheralID] = WeakSession(session)
    }
    func start() {
        enabled = true
        io.start(delegate: self)
        scanIfNeeded()
    }
    func scanIfNeeded() {
        guard enabled, poweredOn, !scanning else { return }
        scanning = true
        io.scan()
    }
    func stop() {
        recoveryScan?.cancel(); recoveryScan = nil
        enabled = false
        if scanning { io.stopScan() }
        scanning = false
        for id in sessions.keys { cancel(peripheralID: id) }
    }
    func connect(peripheralID: UUID) { guard enabled, poweredOn else { return }; io.connect(peripheralID) }
    func cancel(peripheralID: UUID) { io.cancel(peripheralID) }
    func peripheral(_ id: UUID) -> CBPeripheral? { io.peripheral(id) }
    func rescan() {
        guard enabled else { return }
        if scanning { io.stopScan() }
        scanning = false
        discoveredPeers.removeAll()
        scanIfNeeded()
    }
    func restartDiscoveryAfterDisconnect() {
        guard enabled, poweredOn else { return }
        let remaining = 0.5 - Date().timeIntervalSince(lastRecoveryScan)
        if remaining > 0 {
            guard recoveryScan == nil else { return }
            recoveryScan = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.recoveryScan = nil; self?.restartDiscoveryAfterDisconnect()
            }
            return
        }
        lastRecoveryScan = Date()
        if scanning { io.stopScan() }
        scanning = false
        scanIfNeeded() // Clear OS duplicate suppression, without cancelling another peer.
    }
    func restore(peripheralIDs: [UUID]) {
        for id in Set(peripheralIDs) where PairedAndroidDeviceStore.permitsPeripheral(id.uuidString) {
            onRestored?(id)
        }
    }

    private func adoptRestored(_ value: CBPeripheral, central: CBCentralManager) {
        guard PairedAndroidDeviceStore.permitsPeripheral(value.identifier.uuidString) else { return }
        sessions[value.identifier]?.value?.centralManager(central,
            willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [value]])
    }
}

extension VoBLERadioController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { scanning = false }
        for slot in sessions.values { slot.value?.centralManagerDidUpdateState(central) }
        scanIfNeeded()
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restore(peripheralIDs: peripherals.map(\.identifier))
        for peripheral in peripherals {
            adoptRestored(peripheral, central: central)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled else { return }
        let peer = VoBLEDiscoveredPeer(id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "AirSIM Android",
            signal: RSSI.intValue)
        if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
            if discoveredPeers[index] != peer { discoveredPeers[index] = peer }
        } else { discoveredPeers.append(peer) }
        onDiscovered?(peer)
        sessions[peer.id]?.value?.centralManager(central, didDiscover: peripheral,
            advertisementData: advertisementData, rssi: RSSI)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didConnect: peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didFailToConnect: peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didDisconnectPeripheral: peripheral,
            timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }
}
