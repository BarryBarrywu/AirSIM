import SwiftUI

struct SamsungPairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var localPairingOnly = LocalModePreference.isEnabled()
    @StateObject private var browser = SamsungPairingBrowser()
    @State private var code = ""
    @State private var pairingServiceID: String?
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $localPairingOnly) {
                    Label("本地模式配对", systemImage: "wifi")
                }
                .disabled(pairingServiceID != nil)
                .accessibilityIdentifier("localPairingOnly")
                Text(localPairingOnly
                     ? "本次配对只写入 VoWLAN 密钥，不检查或写入 Relay 和推送参数。不会改变全局通话模式。"
                     : "本次配对写入 VoWLAN 密钥及 Relay／推送配置；需要云端凭据就绪。不会改变全局通话模式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("连接步骤") {
                Label("让安卓与本机连接同一 Wi-Fi", systemImage: "wifi")
                Label("也可让本机连接安卓移动热点", systemImage: "personalhotspot")
                Label("在安卓 App 点击“开始一次性配对”", systemImage: "key")
            }

            Section("发现的设备") {
                if browser.services.isEmpty {
                    HStack {
                        ProgressView()
                        Text(browser.stateText).foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.services) { service in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(service.displayName, systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                        TextField("安卓显示的 6 位验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChange(of: code) { value in
                                code = String(value.filter(\.isNumber).prefix(6))
                            }
                        Button("加密配对", systemImage: "lock.shield") {
                            Task { await pair(service) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.count != 6 || pairingServiceID != nil)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !message.isEmpty {
                Section("结果") { Text(message) }
            }
        }
        .navigationTitle("配对安卓手机")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    @MainActor
    private func pair(_ service: SamsungPairingService) async {
        pairingServiceID = service.id
        message = localPairingOnly
            ? "正在加密并写入 VoWLAN 本地密钥…"
            : "正在加密并写入 Android Agent…"
#if DEBUG
        print("[AirSIM Pair] claim_started session=\(service.sessionID)")
#endif
        defer { pairingServiceID = nil }
        do {
            message = try await VoIPPushController.shared.performAndroidPairing(
                localOnly: localPairingOnly
            ) { registration in
                try await SamsungPairingCompletionCoordinator.complete(
                performPairing: {
                    try await SamsungPairingClient.pair(
                        service: service,
                        code: code,
                        registration: registration
                    )
                },
                refreshVoWLAN: {
                    await model.vowlan.refreshAfterPairing()
                }
                )
            }
#if DEBUG
            print("[AirSIM Pair] claim_completed session=\(service.sessionID)")
#endif
        } catch {
            message = "配对失败：\(error.localizedDescription)"
#if DEBUG
            print("[AirSIM Pair] claim_failed session=\(service.sessionID) error=\(String(describing: type(of: error)))")
#endif
        }
    }
}
