import ActivityKit
import UIKit

enum LiveActivityCreationPolicy {
    static func pushType(localModeEnabled: Bool) -> PushType? {
        localModeEnabled ? nil : .token
    }

    static func shouldCreate(
        appIsActive: Bool,
        moduleOnline: Bool,
        hasActivity: Bool
    ) -> Bool {
        !hasActivity && appIsActive
    }
}

enum LiveActivityAgentOrder {
    static let orderKey = "airsim.live-activity-agent-order"
    static let pinnedKey = "airsim.live-activity-pinned-agents"

    static func ordered(
        _ agents: [AndroidAgentPresentation],
        defaults: UserDefaults = .standard
    ) -> [AndroidAgentPresentation] {
        let pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return agents.sorted { left, right in
            let leftPinned = pinned.contains(left.id)
            let rightPinned = pinned.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            let leftRank = rank[left.id] ?? Int.max
            let rightRank = rank[right.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.deviceName.localizedCaseInsensitiveCompare(right.deviceName) == .orderedAscending
        }
    }

    static func isPinned(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        Set(defaults.stringArray(forKey: pinnedKey) ?? []).contains(id)
    }

    static func togglePin(_ id: String, defaults: UserDefaults = .standard) {
        var pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        defaults.set(Array(pinned).sorted(), forKey: pinnedKey)
    }

    /// Moves one row within the currently visible order and persists the full
    /// normalized order so later additions append instead of reshuffling.
    static func move(
        _ id: String,
        by delta: Int,
        agents: [AndroidAgentPresentation],
        defaults: UserDefaults = .standard
    ) {
        var ids = ordered(agents, defaults: defaults).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        defaults.set(ids, forKey: orderKey)
    }
}

struct LiveActivityAgentSnapshot: Equatable {
    let deviceName: String?
    let phoneNumber: String?
    let agentKind: String?
    let pairedAgentCount: Int
    let vowlanOnline: Bool
    let bluetoothOnline: Bool
    let cloudOnline: Bool
    let agents: [AirSIMCallActivityAttributes.ContentState.AgentSummary]
    let page: Int

    init(
        agent: AndroidAgentPresentation?,
        pairedAgentCount: Int,
        agents: [AndroidAgentPresentation] = [],
        currentID: String? = nil,
        page: Int = 0
    ) {
        let current = agent
            ?? agents.first(where: { $0.id == currentID })
            ?? agents.first(where: \.isCurrent)
            ?? agents.first
        deviceName = current?.deviceName
        phoneNumber = current?.phoneNumber
        agentKind = current?.agentKind
        self.pairedAgentCount = pairedAgentCount
        vowlanOnline = current?.vowlanOnline == true
        bluetoothOnline = current?.bluetoothOnline == true
        cloudOnline = current?.cloudOnline == true
        self.page = max(0, page)
        self.agents = agents.map { value in
            AirSIMCallActivityAttributes.ContentState.AgentSummary(
                id: value.id,
                name: value.deviceName,
                phoneNumber: value.phoneNumber,
                agentKind: value.agentKind,
                vowlanOnline: value.vowlanOnline,
                bluetoothOnline: value.bluetoothOnline,
                cloudOnline: value.cloudOnline,
                isCurrent: value.id == current?.id
            )
        }
    }
}

enum LiveActivityStateBuilder {
    static func make(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        idleStartedAt: Date,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil
    ) -> AirSIMCallActivityAttributes.ContentState {
        // VoWLAN 本地控制、Relay 心跳、VoBLE 任一路可达即视为 Agent 在线。
        // 双通道下 Wi-Fi 断开但 BLE 仍连着时，不能把整个 Agent 误报成离线。
        let localAgentOnline = agent?.vowlanOnline == true || agent?.bluetoothOnline == true
        guard moduleOnline || cloudOnline || localAgentOnline else {
            return .init(
                callID: "",
                number: "",
                displayName: "Agent 离线",
                phase: .offline,
                startedAt: idleStartedAt,
                agentDeviceName: agent?.deviceName,
                agentPhoneNumber: agent?.phoneNumber,
                agentKind: agent?.agentKind,
                pairedAgentCount: agent?.pairedAgentCount,
                vowlanOnline: agent?.vowlanOnline,
                bluetoothOnline: agent?.bluetoothOnline,
                cloudOnline: agent?.cloudOnline,
                agents: agent?.agents,
                agentPage: agent?.page
            )
        }
        // Calls are managed exclusively by CallKit; the Live Activity is an Agent-status
        // surface only. Never publish incoming/active/held phases or call action buttons.
        let cloudOnly = cloudOnline && !moduleOnline
        return .init(
            callID: "",
            number: "",
            displayName: cloudOnly ? "公网中继已连接" : "等待 Agent 来电",
            phase: cloudOnly ? .cloudStandby : .standby,
            startedAt: idleStartedAt,
            transport: cloudOnly ? .cloud : transport,
            signalDBM: radio?.signalDBM,
            operatorName: radio?.operatorName,
            networkMode: radio?.networkMode,
            radioBand: radio?.radioBand,
            downloadBytesPerSecond: nil,
            uploadBytesPerSecond: nil,
            agentDeviceName: agent?.deviceName,
            agentPhoneNumber: agent?.phoneNumber,
            agentKind: agent?.agentKind,
            pairedAgentCount: agent?.pairedAgentCount,
            vowlanOnline: agent?.vowlanOnline,
            bluetoothOnline: agent?.bluetoothOnline,
            cloudOnline: agent?.cloudOnline,
            agents: agent?.agents,
            agentPage: agent?.page
        )
    }
}

/// 主 App 负责预启动并持续同步灵动岛；后台只能更新已经存在的 Live Activity。
@MainActor
final class LiveActivityController {
    private var activity: Activity<AirSIMCallActivityAttributes>?
    private var lastState: AirSIMCallActivityAttributes.ContentState?
    private let idleStartedAt = Date()
    private var enabled = true
    private var visibilityRevision = 0

    /// 用户关闭开关时立即清理系统活动；重新开启后由下一轮模块状态同步按需创建。
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        visibilityRevision &+= 1
        if !enabled {
            let revision = visibilityRevision
            Task { @MainActor [weak self] in
                guard let self, !self.enabled,
                      self.visibilityRevision == revision else { return }
                await self.stop()
            }
        }
    }

    func update(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        appIsActive: Bool,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil,
        force: Bool = false
    ) async {
        guard enabled, UIDevice.current.userInterfaceIdiom == .phone else { return }
        resolveExistingActivity()
#if DEBUG
        let requestedPhase = call != nil ? "call" : (moduleOnline ? "standby" : (cloudOnline ? "cloud_standby" : "offline"))
        print("[AirSIM LiveActivity] requestedPhase=\(requestedPhase) appActive=\(appIsActive) authorized=\(ActivityAuthorizationInfo().areActivitiesEnabled) existingCount=\(Activity<AirSIMCallActivityAttributes>.activities.count) selected=\(activity?.id ?? "none")")
#endif

        if activity == nil {
            // iOS 不保证后台能本地创建活动。前台离线时也允许创建，以替换升级安装后
            // 系统仍显示、但 Activity.activities 已无法返回句柄的孤立活动。
            guard LiveActivityCreationPolicy.shouldCreate(
                      appIsActive: appIsActive,
                      moduleOnline: moduleOnline,
                      hasActivity: false
                  ),
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                let initialState = LiveActivityStateBuilder.make(
                    call: call,
                    callerName: callerName,
                    moduleOnline: moduleOnline,
                    cloudOnline: cloudOnline,
                    transport: transport,
                    radio: radio,
                    agent: agent,
                    idleStartedAt: idleStartedAt,
                    downloadBytesPerSecond: downloadBytesPerSecond,
                    uploadBytesPerSecond: uploadBytesPerSecond
                )
                activity = try Activity.request(
                    attributes: AirSIMCallActivityAttributes(moduleName: "AirSIM"),
                    content: ActivityContent(
                        state: initialState,
                        staleDate: nil
                    ),
                    pushType: LiveActivityCreationPolicy.pushType(
                        localModeEnabled: !CloudModePreference.isEnabled()
                    )
                )
                if let activity {
                    VoIPPushController.shared.observeLiveActivity(activity)
                }
#if DEBUG
                print("[AirSIM LiveActivity] created id=\(activity?.id ?? "none") phase=\(initialState.phase.rawValue)")
#endif
                lastState = initialState
            } catch {
#if DEBUG
                print("[AirSIM LiveActivity] create_failed error=\(String(describing: error))")
#endif
                return
            }
        } else if let activity {
            let nextState = LiveActivityStateBuilder.make(
                call: call,
                callerName: callerName,
                moduleOnline: moduleOnline,
                cloudOnline: cloudOnline,
                transport: transport,
                radio: radio,
                agent: agent,
                idleStartedAt: idleStartedAt,
                downloadBytesPerSecond: downloadBytesPerSecond,
                uploadBytesPerSecond: uploadBytesPerSecond
            )
            // 在线/离线由真实模块请求决定；不以 ActivityKit stale 代替连通性探测。
            // force 用于挂断后强制回到待机，避免残留 old state 让计时器继续走。
            guard force || nextState != lastState else { return }
            await activity.update(
                ActivityContent(
                    state: nextState,
                    staleDate: nil
                )
            )
#if DEBUG
            print("[AirSIM LiveActivity] updated id=\(activity.id) phase=\(nextState.phase.rawValue)")
#endif
            lastState = nextState
        }
    }

    func markOffline(agent: LiveActivityAgentSnapshot? = nil, appIsActive: Bool) async {
        await update(
            call: nil,
            callerName: nil,
            moduleOnline: false,
            radio: nil,
            agent: agent,
            appIsActive: appIsActive
        )
    }

    func stop() async {
        for activity in Activity<AirSIMCallActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastState = nil
    }


    private func resolveExistingActivity() {
        guard activity == nil else { return }
        let existing = Activity<AirSIMCallActivityAttributes>.activities
        activity = existing.first
        if let activity {
            VoIPPushController.shared.observeLiveActivity(activity)
        }
#if DEBUG
        let summary = existing.map { "\($0.id):\($0.content.state.phase.rawValue)" }.joined(separator: ",")
        print("[AirSIM LiveActivity] resolved count=\(existing.count) activities=[\(summary)]")
#endif
        lastState = activity?.content.state
    }

}
