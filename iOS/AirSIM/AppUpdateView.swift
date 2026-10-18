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
        NavigationStack {
            List {
                switch presentation {
                case .notes:
                    Section("AirSIM \(AppInformation.version)") {
                        ForEach(AppReleaseNotes.items, id: \.self) { Text($0) }
                    }
                    Section { Text(AppReleaseNotes.limitations).foregroundStyle(.secondary) }
                case .result(let result):
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
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") {
                        switch presentation {
                        case .notes: updates.acknowledgeNotes()
                        case .result(let result): if let candidate = result.candidate { updates.acknowledgeUpdate(candidate) }
                        }
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch presentation { case .notes: return "当前版本更新内容"; case .result: return "应用更新" }
    }
}
