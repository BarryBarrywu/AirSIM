import ActivityKit
import AppIntents
import Foundation

/// 主 App 与灵动岛扩展共享的活动数据，字段必须保持精简且可编码。
struct AirSIMCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Transport: String, Codable, Hashable {
            case vowlan
            case bluetooth
            case cloud

            var title: String {
                switch self {
                case .vowlan: return "VoWLAN"
                case .bluetooth: return "蓝牙"
                case .cloud: return "云端"
                }
            }

            var systemImage: String {
                switch self {
                case .vowlan: return "wifi"
                case .bluetooth: return "wave.3.right"
                case .cloud: return "icloud.fill"
                }
            }
        }

        let callID: String
        let number: String
        let displayName: String
        let phase: Phase
        let startedAt: Date
        let transport: Transport?
        /// 模块 SIM 的蜂窝状态；只在待机状态显示，离线与通话状态不携带旧快照。
        let signalDBM: Int?
        let operatorName: String?
        let networkMode: String?
        let radioBand: String?
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        /// 当前用于拨号和媒体路由的 Android Agent。字段保持可选，以兼容旧版 Relay
        /// 推送的 ContentState，并避免升级时让已存在的 Live Activity 解码失败。
        let agentDeviceName: String?
        let agentPhoneNumber: String?
        let agentKind: String?
        let pairedAgentCount: Int?
        let vowlanOnline: Bool?
        let bluetoothOnline: Bool?
        let cloudOnline: Bool?

        init(
            callID: String,
            number: String,
            displayName: String,
            phase: Phase,
            startedAt: Date,
            transport: Transport? = nil,
            signalDBM: Int? = nil,
            operatorName: String? = nil,
            networkMode: String? = nil,
            radioBand: String? = nil,
            downloadBytesPerSecond: Double? = nil,
            uploadBytesPerSecond: Double? = nil,
            agentDeviceName: String? = nil,
            agentPhoneNumber: String? = nil,
            agentKind: String? = nil,
            pairedAgentCount: Int? = nil,
            vowlanOnline: Bool? = nil,
            bluetoothOnline: Bool? = nil,
            cloudOnline: Bool? = nil
        ) {
            self.callID = callID
            self.number = number
            self.displayName = displayName
            self.phase = phase
            self.startedAt = startedAt
            self.transport = transport
            self.signalDBM = signalDBM
            self.operatorName = operatorName
            self.networkMode = networkMode
            self.radioBand = radioBand
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.agentDeviceName = agentDeviceName
            self.agentPhoneNumber = agentPhoneNumber
            self.agentKind = agentKind
            self.pairedAgentCount = pairedAgentCount
            self.vowlanOnline = vowlanOnline
            self.bluetoothOnline = bluetoothOnline
            self.cloudOnline = cloudOnline
        }

        enum Phase: String, Codable, Hashable {
            case standby
            case cloudStandby = "cloud_standby"
            case incoming
            case active
            case held
            case offline

            var title: String {
                switch self {
                case .standby: return "Agent 待机"
                case .cloudStandby: return "云端在线"
                case .incoming: return "Agent 来电"
                case .active: return "通话中"
                case .held: return "通话保持"
                case .offline: return "Agent 离线"
                }
            }
        }
    }

    let moduleName: String
}

extension AirSIMCallActivityAttributes.ContentState {
    /// ActivityKit 的 stale 只表示主 App 暂时没有提交新内容，不能证明 Agent 离线。
    /// 模块离线由主 App 的真实 HTTP 探测失败显式写入 `.offline`。
    func liveActivityDisplayState(isStale: Bool) -> Self {
        // CallKit exclusively owns in-call UI. Even an activity created by an older
        // build must never render a call phase, timer or hangup button.
        guard phase == .incoming || phase == .active || phase == .held else { return self }
        return Self(
            callID: "",
            number: "",
            displayName: "等待 Agent 来电",
            phase: .standby,
            startedAt: startedAt,
            transport: transport,
            agentDeviceName: agentDeviceName,
            agentPhoneNumber: agentPhoneNumber,
            agentKind: agentKind,
            pairedAgentCount: pairedAgentCount,
            vowlanOnline: vowlanOnline,
            bluetoothOnline: bluetoothOnline,
            cloudOnline: cloudOnline
        )
    }
}

enum LiveActivityVisualPolicy {
    static func usesGlass(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> Bool {
        switch phase {
        case .standby, .cloudStandby, .incoming, .active, .held, .offline:
            return true
        }
    }
}

enum LiveActivityVisibilityPreference {
    static let key = "airsim.live-activity-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func registrationToken(
        _ storedToken: String,
        defaults: UserDefaults = .standard
    ) -> String {
        isEnabled(defaults: defaults) ? storedToken : ""
    }
}

enum IslandActionLayout {
    static let buttonSide: CGFloat = 44
    static let buttonSpacing: CGFloat = 8

    static func reservedWidth(for phase: AirSIMCallActivityAttributes.ContentState.Phase) -> CGFloat {
        switch phase {
        case .incoming: return buttonSide * 2 + buttonSpacing
        case .active, .held: return buttonSide
        case .standby, .cloudStandby, .offline: return 0
        }
    }
}

enum AirSIMLiveActivityAction: String, Equatable, Sendable {
    case answer
    case reject
    case hangup
    case switchAgent
}

enum AirSIMLiveActivityActionRouting {
    static func opensApp(for transport: AirSIMCallActivityAttributes.ContentState.Transport?) -> Bool {
        transport == .bluetooth || transport == .vowlan
    }
}

enum AirSIMLiveActivityActionURL {
    static func make(action: AirSIMLiveActivityAction, callID: String) -> URL? {
        guard !callID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "airsim"
        components.host = "call"
        components.path = "/\(action.rawValue)"
        components.queryItems = [URLQueryItem(name: "call_id", value: callID)]
        return components.url
    }

    static func parse(_ url: URL) -> (action: AirSIMLiveActivityAction, callID: String)? {
        guard url.scheme?.lowercased() == "airsim",
              url.host?.lowercased() == "call",
              let action = AirSIMLiveActivityAction(
                rawValue: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let callID = components.queryItems?.first(where: { $0.name == "call_id" })?.value,
              !callID.isEmpty else { return nil }
        return (action, callID)
    }
}

/// The Live Activity intent runs in the app process. AppModel installs this
/// handler so cloud/VoBLE/VoWLAN calls use the same authoritative path as the
/// in-app buttons instead of a hard-coded module address.
@MainActor
enum LiveActivityActionBridge {
    static var handler: ((AirSIMLiveActivityAction, String) async -> Bool)?

    static func perform(_ action: AirSIMLiveActivityAction, callID: String) async -> Bool {
        // A cold launch may still be initializing AppModel; give it a short window.
        for _ in 0..<20 {
            if let handler { return await handler(action, callID) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// 灵动岛动作只走 App 内统一处理，不再保存或猜测 Android 的控制地址。

@available(iOS 17.0, *)
struct AnswerAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "接听模块来电"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.answer, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct RejectAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "拒绝模块来电"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.reject, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

/// 待机态切换当前 Android Agent（及其号码）；通话中不切换，避免媒体/控制
/// 会话跨设备漂移。
@available(iOS 17.0, *)
struct SwitchAirSIMAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "切换 Android Agent"
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.switchAgent, callID: "") else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct HangUpAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "挂断模块通话"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.hangup, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

private enum LiveActivityActionError: LocalizedError {
    case appUnavailable

    var errorDescription: String? {
        switch self {
        case .appUnavailable: return "请在 AirSIM App 内处理该通话"
        }
    }
}
