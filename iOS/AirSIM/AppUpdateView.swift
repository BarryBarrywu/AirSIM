import SwiftUI

enum AppUpdatePresentation: Identifiable {
    case notes
    case result(AppUpdateResult)
    var id: String {
        switch self { case .notes: return "notes"; case .result: return "result" }
    }
}

enum AppReleaseNotes {
    // Bundled: showing installed-version notes never needs GitHub, Relay or pairing.
    // Keep this summary in sync with the candidate's source and docs when publishing.
    static let items = [
        "首次安装／升级后显示版本说明；设置中可随时重看，并手动检查应用更新。",
        "本地双通道：拨号前优先 VoWLAN、其次 VoBLE；通话中不自动切换音频链路。",
        "多安卓设备与通话来源绑定，改进短信会话、设备配对及详细日志。",
        "优化蓝牙音频启动顺序与云端挂断状态；云端后台待机保留最近确认结果，不增加 Relay 定时查询。"
    ]
    static let limitations = "各机型双向声音、长时锁屏与多设备场景仍需分别真机验证；GitHub 发布不代表 TestFlight 已可更新。"
}

enum AppUpdateChannel {
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            && Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") == nil
    }
    static var title: String { isTestFlight ? "TestFlight" : "自签／侧载或其他安装渠道" }
}

struct AppUpdateSheet: View {
    let presentation: AppUpdatePresentation
    @ObservedObject var updates: AppUpdateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch presentation {
        case .notes:
            NewFeatureOnboardingView(
                version: AppInformation.version,
                onConfirm: {
                    updates.acknowledgeNotes()
                    dismiss()
                }
            )
        case .result(let result):
            NavigationStack {
                List {
                    Section { Text(result.message) }
                    if let candidate = result.candidate {
                        Section("公开版本 \(candidate.version)（\(candidate.build)）") {
                            Text(candidate.notes.isEmpty ? "请查看发布页中的更新说明。" : candidate.notes)
                                .textSelection(.enabled)
                            Link("查看 GitHub 发布说明", destination: candidate.page)
                        }
                        Section("如何更新") {
                            Text(AppUpdateChannel.isTestFlight
                                ? "请打开 TestFlight 查看此 App 是否已有可用构建。GitHub 发布不代表 Apple 已处理完成或测试者可更新。"
                                : "GitHub IPA 需要侧载工具重新签名后安装，不能直接安装。使用 TestFlight 的用户请在 TestFlight 中检查。")
                            Text("不会自动下载安装，也不会更改配对、通话或 AVF Agent。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("应用更新")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("知道了") {
                            if let candidate = result.candidate { updates.acknowledgeUpdate(candidate) }
                            dismiss()
                        }
                    }
                }
            }
        }
        }
        .interactiveDismissDisabled()
    }
}

private struct NewFeaturePage: Identifiable {
    let id: Int
    let kicker: String
    let title: String
    let body: String
    let symbol: String
    let accent: Color
}

private enum NewFeatureCatalog {
    static let pages: [NewFeaturePage] = [
        NewFeaturePage(
            id: 0,
            kicker: "新功能",
            title: "后台保活，\n由你决定",
            body: "新增全局静音音频保活开关。默认关闭，不再用持续静音播放维持后台，显著降低耗电。PushKit、CallKit 与云端唤醒仍可工作。",
            symbol: "battery.25percent",
            accent: .green
        ),
        NewFeaturePage(
            id: 1,
            kicker: "自动反馈",
            title: "问题自动留痕",
            body: "通话结束、短信发送或接收时，自动把脱敏日志、设备信息和 PCM 状态写入 Notion。也可以在设置里填写用户描述与备注。",
            symbol: "paperplane.fill",
            accent: .cyan
        ),
        NewFeaturePage(
            id: 2,
            kicker: "VoWLAN 自愈",
            title: "换网也能\n自己找回来",
            body: "Wi-Fi 或 DHCP 换址后，旧的局域网地址会被丢弃，重新发现并做签名验证；Tailscale 路由会保留，不再反复探测失效 IP。",
            symbol: "wifi",
            accent: .blue
        ),
        NewFeaturePage(
            id: 3,
            kicker: "多设备",
            title: "四台安卓，\n一页掌控",
            body: "灵动岛每页最多显示 3 台设备，左右翻页即可切换；当前设备始终置顶，底部说明不再被最后一行挤出卡片。",
            symbol: "rectangle.stack.fill",
            accent: .purple
        ),
    ]
}

struct NewFeatureOnboardingView: View {
    let version: String
    let onConfirm: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: NewFeaturePage { NewFeatureCatalog.pages[page] }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    selected.accent.opacity(0.34),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: page)

            TabView(selection: $page) {
                ForEach(Array(NewFeatureCatalog.pages.enumerated()), id: \.element.id) { index, item in
                    NewFeaturePageView(item: item, isActive: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.35), value: page)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirSIM")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button("确定") { onConfirm() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(.white, in: Capsule())
                    .accessibilityLabel("确定并关闭新功能介绍")
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    ForEach(NewFeatureCatalog.pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? .white : .white.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: page)
                    }
                }
                Text("左右滑动 · 查看全部新功能")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 6)
            }
            .padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

private struct NewFeaturePageView: View {
    let item: NewFeaturePage
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(item.accent.opacity(0.18))
                    .frame(width: 190, height: 190)
                    .blur(radius: 2)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 150, height: 150)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
                Image(systemName: item.symbol)
                    .font(.system(size: 62, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.accent)
                    .scaleEffect(isActive ? 1 : 0.82)
                    .rotationEffect(.degrees(isActive ? 0 : -6))
                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.78), value: isActive)
            }
            .padding(.bottom, 34)

            Text(item.kicker.uppercased())
                .font(.caption.weight(.bold))
                .tracking(2.2)
                .foregroundStyle(item.accent)

            Text(item.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)

            Text(item.body)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(4)
                .padding(.top, 14)
                .padding(.horizontal, 8)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 28)
        .opacity(isActive ? 1 : 0.55)
        .scaleEffect(isActive ? 1 : 0.94)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isActive)
        .accessibilityElement(children: .combine)
    }
}

