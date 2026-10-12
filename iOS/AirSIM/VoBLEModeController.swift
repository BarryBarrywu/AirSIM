import Foundation

@MainActor
protocol VoBLECentralControlling: AnyObject {
    func start()
    func stop()
}

struct VoBLEModeActions: Equatable, Sendable {
    let startVoWLAN: Bool
    let startCloud: Bool
}

@MainActor
final class VoBLEModeController {
    private let bluetooth: any VoBLECentralControlling
    private(set) var selectedMode: AirSIMConnectionMode = .automatic

    init(bluetooth: any VoBLECentralControlling) {
        self.bluetooth = bluetooth
    }

    @discardableResult
    func activate(_ mode: AirSIMConnectionMode) -> VoBLEModeActions {
        selectedMode = mode
        let policy = ConnectionModeRuntimePolicy(mode: mode)
        if policy.startsBluetooth { bluetooth.start() } else { bluetooth.stop() }
        return VoBLEModeActions(
            startVoWLAN: policy.startsVoWLAN,
            startCloud: policy.startsCloud
        )
    }

    var shouldFallbackAfterBluetoothFailure: Bool {
        ConnectionModeRuntimePolicy(mode: selectedMode).allowsCrossModeFallback
    }
}
