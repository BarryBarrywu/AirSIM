import Foundation

/// 用户明确选择的连接方式。只有 `automatic` 可以跨传输回退。
enum AirSIMConnectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case vowlan
    case bluetooth
    case cloud
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vowlan: return "VoWLAN"
        case .bluetooth: return "蓝牙"
        case .cloud: return "云端"
        case .automatic: return "自动"
        }
    }

    var detail: String {
        switch self {
        case .vowlan: return "仅使用同一 Wi-Fi 或手机热点，不连接 Relay"
        case .bluetooth: return "仅使用蓝牙控制与通话音频，不依赖 Wi-Fi 或 Relay"
        case .cloud: return "仅使用 Relay、PushKit 与 CallKit"
        case .automatic: return "按 VoWLAN、蓝牙、云端的可用性自动选择"
        }
    }
}

enum ConnectionModePreference {
    static let key = "airsim.connection-mode"

    static func selected(defaults: UserDefaults = .standard) -> AirSIMConnectionMode {
        if let rawValue = defaults.string(forKey: key),
           let mode = AirSIMConnectionMode(rawValue: rawValue) {
            return mode
        }
        // 兼容升级前的两个布尔开关；不在读取时改写，避免测试套件和扩展进程副作用。
        if defaults.bool(forKey: LocalModePreference.key) { return .vowlan }
        if defaults.object(forKey: CloudModePreference.key) != nil,
           !defaults.bool(forKey: CloudModePreference.key) {
            return .vowlan
        }
        return .automatic
    }

    static func set(
        _ mode: AirSIMConnectionMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key)
        defaults.set(mode == .vowlan, forKey: LocalModePreference.key)
        defaults.set(
            mode == .cloud || mode == .automatic,
            forKey: CloudModePreference.key
        )
    }
}

struct ConnectionModeRuntimePolicy: Equatable, Sendable {
    let mode: AirSIMConnectionMode

    var startsVoWLAN: Bool { mode == .vowlan || mode == .automatic }
    var startsBluetooth: Bool { mode == .bluetooth || mode == .automatic }
    var startsCloud: Bool { mode == .cloud || mode == .automatic }
    var allowsCrossModeFallback: Bool { mode == .automatic }

    /// 蓝牙来电同样依赖系统通话界面；仅传统 VoWLAN 本地模式关闭 CallKit。
    var usesCallKit: Bool { mode != .vowlan }
}
