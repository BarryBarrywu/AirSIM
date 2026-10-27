import SwiftUI
import WebKit

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
        "新增全局“后台静音音频保活”开关，默认关闭，显著降低后台耗电；PushKit/CallKit 仍可唤醒。",
        "反馈改为手动上传：在设置里填写描述与备注后点击上传，不会在通话或短信时自动提交。",
        "VoWLAN 在 Wi-Fi/DHCP 换址后丢弃旧 LAN 地址并重新发现验证，减少离线卡住。",
        "灵动岛每页最多 3 台设备；国际号码保留国家码，修复英国等号码显示错误。",
        "修复 OnePlus 等机型 DTMF 按键被立即取消、挂断无响应的问题；KernelSU root bridge 增加 Looper 初始化。",
        "CallKit 接听改为幂等，修复冷启动/通知打开时 active call id mismatch 与自动挂断；VoBLE 新增短信下行。",
        "来电事件优先走 Relay，已结束的来电不再迟到拉起 CallKit；挂断控制回执超时按本地结束处理。",
        "云端接听后立即启动音频，不再等待迟到的 Agent active 帧；弱网短丢包隐藏并自适应扩大 jitter 缓冲。",
        "新增崩溃诊断与最新 Android 日志采集；反馈输入框支持键盘“完成”收起；云端自检复用 HTTPS 连接。"
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
    let demo: NewFeatureDemo
}

private enum NewFeatureCatalog {
    static let pages: [NewFeaturePage] = [
        NewFeaturePage(
            id: 0,
            kicker: "新功能",
            title: "后台保活，\n由你决定",
            body: "新增全局静音音频保活开关。默认关闭，不再用持续静音播放维持后台，显著降低耗电。PushKit、CallKit 与云端唤醒仍可工作。",
            symbol: "battery.25percent",
            accent: .green,
            demo: .standby
        ),
        NewFeaturePage(
            id: 1,
            kicker: "反馈",
            title: "问题手动留痕",
            body: "在设置里填写用户描述与备注，手动把脱敏日志、设备信息和 PCM 状态上传到 Notion。不会在通话或短信时自动上传。",
            symbol: "paperplane.fill",
            accent: .cyan,
            demo: .feedback
        ),
        NewFeaturePage(
            id: 2,
            kicker: "VoWLAN 自愈",
            title: "换网也能\n自己找回来",
            body: "Wi-Fi 或 DHCP 换址后，旧的局域网地址会被丢弃，重新发现并做签名验证；Tailscale 路由会保留，不再反复探测失效 IP。",
            symbol: "wifi",
            accent: .blue,
            demo: .vowlan
        ),
        NewFeaturePage(
            id: 3,
            kicker: "多设备",
            title: "四台安卓，\n一页掌控",
            body: "灵动岛每页最多显示 3 台设备，左右翻页即可切换；当前设备始终置顶，底部说明不再被最后一行挤出卡片。",
            symbol: "rectangle.stack.fill",
            accent: .purple,
            demo: .devices
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

            FeatureDemoView(demo: item.demo, accent: item.accent)
                .frame(height: 220)
                .padding(.horizontal, 4)
                .opacity(isActive ? 1 : 0.55)
                .scaleEffect(isActive ? 1 : 0.94)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isActive)
                .padding(.bottom, 22)

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


private enum NewFeatureDemo: Equatable {
    case standby
    case feedback
    case vowlan
    case devices
}

private struct FeatureDemoView: UIViewRepresentable {
    let demo: NewFeatureDemo
    let accent: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        context.coordinator.demo = demo
        view.loadHTMLString(FeatureDemoHTML.html(for: demo), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.demo != demo else { return }
        context.coordinator.demo = demo
        view.loadHTMLString(FeatureDemoHTML.html(for: demo), baseURL: nil)
    }

    final class Coordinator {
        var demo: NewFeatureDemo?
    }
}

private enum FeatureDemoHTML {
    static func html(for demo: NewFeatureDemo) -> String {
        let body: String
        switch demo {
        case .standby: body = standby
        case .feedback: body = feedback
        case .vowlan: body = vowlan
        case .devices: body = devices
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        html,body{margin:0;padding:0;width:100%;height:100%;background:transparent;overflow:hidden}
        svg{display:block;width:100%;height:100%}
        text{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif}
        .knob{transform-box:fill-box;transform-origin:center;animation:toggle 5.5s ease-in-out infinite}
        .wave{transform-box:fill-box;transform-origin:center;animation:wave 1.05s ease-in-out infinite}
        .wave.off{animation:none;opacity:.18}
        .batteryFill{animation:battery 5.5s ease-in-out infinite}
        .packet{animation:packet 4.8s ease-in-out infinite}
        .ipOld{animation:ipOld 5s ease-in-out infinite}
        .ipNew{animation:ipNew 5s ease-in-out infinite}
        .route{stroke-dasharray:8 7;animation:route 2.2s linear infinite}
        .check{animation:check 5s ease-in-out infinite;transform-box:fill-box;transform-origin:center}
        .pageA{animation:pageA 5.5s ease-in-out infinite}
        .pageB{animation:pageB 5.5s ease-in-out infinite}
        .pageC{animation:pageC 5.5s ease-in-out infinite}
        .dotA{animation:dotA 5.5s ease-in-out infinite}
        .dotB{animation:dotB 5.5s ease-in-out infinite}
        @keyframes toggle{0%,32%{transform:translateX(0)}42%,88%{transform:translateX(34px)}96%,100%{transform:translateX(0)}}
        @keyframes wave{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}
        @keyframes battery{0%,32%{width:42px}42%,88%{width:20px}96%,100%{width:42px}}
        @keyframes packet{0%,12%{transform:translate(0,0);opacity:0}20%{opacity:1}68%{transform:translate(150px,-6px);opacity:1}76%,100%{transform:translate(150px,-6px);opacity:0}}
        @keyframes ipOld{0%,35%{opacity:1}45%,100%{opacity:.18}}
        @keyframes ipNew{0%,35%{opacity:.18}45%,88%{opacity:1}96%,100%{opacity:.18}}
        @keyframes route{to{stroke-dashoffset:-30}}
        @keyframes check{0%,55%{opacity:0;transform:scale(.5)}68%,88%{opacity:1;transform:scale(1)}96%,100%{opacity:0;transform:scale(.5)}}
        @keyframes pageA{0%,30%{transform:translateX(0);opacity:1}42%,100%{transform:translateX(-22px);opacity:.45}}
        @keyframes pageB{0%,30%{transform:translateX(0);opacity:.45}42%,72%{transform:translateX(0);opacity:1}84%,100%{transform:translateX(-22px);opacity:.45}}
        @keyframes pageC{0%,70%{transform:translateX(0);opacity:.45}82%,100%{transform:translateX(0);opacity:1}}
        @keyframes dotA{0%,30%{opacity:1}42%,100%{opacity:.25}}
        @keyframes dotB{0%,30%{opacity:.25}42%,100%{opacity:1}}
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static let standby = """
    <svg viewBox="0 0 320 220" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="phone" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#ffffff" stop-opacity=".12"/>
          <stop offset="1" stop-color="#ffffff" stop-opacity=".03"/>
        </linearGradient>
      </defs>
      <rect x="88" y="10" width="144" height="200" rx="25" fill="url(#phone)" stroke="#ffffff" stroke-opacity=".18"/>
      <rect x="138" y="22" width="44" height="8" rx="4" fill="#ffffff" fill-opacity=".22"/>
      <rect x="118" y="47" width="84" height="30" rx="15" fill="#2c2c2e"/>
      <circle class="knob" cx="134" cy="62" r="11" fill="#34c759"/>
      <text x="160" y="67" fill="#ffffff" fill-opacity=".7" font-size="10">后台保活</text>
      <g transform="translate(160 108)">
        <rect class="wave" x="-24" y="-14" width="5" height="28" rx="2.5" fill="#34c759"/>
        <rect class="wave" x="-12" y="-22" width="5" height="44" rx="2.5" fill="#34c759" style="animation-delay:.12s"/>
        <rect class="wave" x="0" y="-9" width="5" height="18" rx="2.5" fill="#34c759" style="animation-delay:.24s"/>
        <rect class="wave" x="12" y="-18" width="5" height="36" rx="2.5" fill="#34c759" style="animation-delay:.36s"/>
      </g>
      <text x="160" y="151" text-anchor="middle" fill="#ffffff" fill-opacity=".55" font-size="10">静音音频占用</text>
      <rect x="108" y="169" width="84" height="18" rx="9" fill="#ffffff" fill-opacity=".1"/>
      <rect class="batteryFill" x="112" y="173" width="42" height="10" rx="5" fill="#34c759"/>
      <text x="160" y="197" text-anchor="middle" fill="#34c759" font-size="9">关闭后更低耗电</text>
    </svg>
    """

    private static let feedback = """
    <svg viewBox="0 0 320 220" xmlns="http://www.w3.org/2000/svg">
      <rect x="18" y="36" width="102" height="145" rx="18" fill="#ffffff" fill-opacity=".08" stroke="#ffffff" stroke-opacity=".16"/>
      <rect x="52" y="48" width="34" height="6" rx="3" fill="#ffffff" fill-opacity=".25"/>
      <rect x="31" y="68" width="76" height="34" rx="11" fill="#32ade6" fill-opacity=".22"/>
      <text x="40" y="82" fill="#ffffff" fill-opacity=".65" font-size="8">通话结束</text>
      <text x="40" y="93" fill="#ffffff" fill-opacity=".4" font-size="7">脱敏日志</text>
      <rect x="31" y="110" width="64" height="24" rx="8" fill="#ffffff" fill-opacity=".08"/>
      <text x="40" y="126" fill="#ffffff" fill-opacity=".55" font-size="8">PCM 状态</text>
      <circle cx="69" cy="158" r="12" fill="#32ade6" fill-opacity=".2"/>
      <path d="M64 158 l4 4 l8 -9" stroke="#32ade6" stroke-width="2" fill="none" stroke-linecap="round"/>
      <path class="route" d="M125 110 C150 70, 170 150, 205 110" stroke="#32ade6" stroke-opacity=".7" stroke-width="2" fill="none"/>
      <g class="packet" transform="translate(126 104)">
        <rect width="40" height="18" rx="6" fill="#32ade6" fill-opacity=".28"/>
        <text x="7" y="12" fill="#ffffff" fill-opacity=".8" font-size="7">反馈</text>
      </g>
      <rect x="205" y="55" width="96" height="112" rx="16" fill="#ffffff" fill-opacity=".09" stroke="#ffffff" stroke-opacity=".18"/>
      <rect x="220" y="68" width="66" height="8" rx="4" fill="#ffffff" fill-opacity=".25"/>
      <rect x="220" y="86" width="66" height="15" rx="4" fill="#32ade6" fill-opacity=".22"/>
      <rect x="220" y="107" width="66" height="15" rx="4" fill="#ffffff" fill-opacity=".08"/>
      <rect x="220" y="128" width="50" height="15" rx="4" fill="#ffffff" fill-opacity=".08"/>
      <text x="253" y="151" text-anchor="middle" fill="#32ade6" font-size="9">Notion</text>
    </svg>
    """

    private static let vowlan = """
    <svg viewBox="0 0 320 220" xmlns="http://www.w3.org/2000/svg">
      <circle cx="160" cy="105" r="52" fill="#0a84ff" fill-opacity=".08"/>
      <circle cx="160" cy="105" r="34" fill="#0a84ff" fill-opacity=".12"/>
      <path d="M116 105 Q160 58 204 105" stroke="#0a84ff" stroke-opacity=".55" stroke-width="2" fill="none"/>
      <path d="M128 105 Q160 73 192 105" stroke="#0a84ff" stroke-opacity=".4" stroke-width="2" fill="none"/>
      <circle cx="160" cy="105" r="7" fill="#0a84ff"/>
      <text class="ipOld" x="160" y="30" text-anchor="middle" fill="#ffffff" fill-opacity=".55" font-size="11">192.168.1.20</text>
      <text class="ipNew" x="160" y="30" text-anchor="middle" fill="#0a84ff" font-size="11">192.168.1.88</text>
      <text x="160" y="184" text-anchor="middle" fill="#ffffff" fill-opacity=".5" font-size="9">Wi-Fi / DHCP 变化</text>
      <g class="check" transform="translate(214 42)">
        <circle r="13" fill="#0a84ff" fill-opacity=".2"/>
        <path d="M-5 0 l4 4 l8 -9" stroke="#0a84ff" stroke-width="2" fill="none" stroke-linecap="round"/>
      </g>
      <text x="160" y="207" text-anchor="middle" fill="#0a84ff" font-size="9">丢弃旧地址 · 重新验证</text>
    </svg>
    """

    private static let devices = """
    <svg viewBox="0 0 320 220" xmlns="http://www.w3.org/2000/svg">
      <rect class="pageC" x="48" y="43" width="224" height="32" rx="10" fill="#ffffff" fill-opacity=".05"/>
      <rect class="pageB" x="48" y="80" width="224" height="38" rx="11" fill="#ffffff" fill-opacity=".08"/>
      <rect class="pageA" x="48" y="123" width="224" height="44" rx="12" fill="#bf5af2" fill-opacity=".16" stroke="#bf5af2" stroke-opacity=".35"/>
      <text class="pageA" x="66" y="149" fill="#ffffff" font-size="10">Nothing A059 · 当前</text>
      <text class="pageB" x="66" y="104" fill="#ffffff" fill-opacity=".65" font-size="10">Google Pixel 7</text>
      <text class="pageC" x="66" y="63" fill="#ffffff" fill-opacity=".4" font-size="10">Google Pixel 8</text>
      <rect class="pageA" x="240" y="136" width="20" height="18" rx="5" fill="#34c759" fill-opacity=".2"/>
      <rect x="48" y="181" width="60" height="2" rx="1" fill="#ffffff" fill-opacity=".15"/>
      <rect class="dotA" x="48" y="185" width="60" height="4" rx="2" fill="#bf5af2"/>
      <text x="160" y="195" text-anchor="middle" fill="#ffffff" fill-opacity=".45" font-size="8">左右翻页 · 每页 3 台</text>
    </svg>
    """
}

