# AirSIM Android Standalone

AirSIM Android Standalone 是推荐的 Android 端部署方式：它把原本运行在 Android AVF Linux 中的 Agent 合并进 Android 前台服务，形成单一 APK。安装后不再需要 Linux Terminal、Debian、AVF 私网、`airsim-installerd`，也不再监听 Agent / installer 的 `8575`、`8576` 端口。

Standalone 复用 [`android/phone-control-app`](../android/phone-control-app/README.md) 的 Telecom、短信、VoWLAN、配对与 Shizuku 管理代码，以及 [`android/phone-audio-bridge`](../android/phone-audio-bridge/README.md) 的通话 PCM 桥。独立 Manifest 使用包名 `com.airsim.phonecontrol.standalone`，因此可与旧 AVF 版并存安装；但同一时间只能有一个 App 持有默认电话角色和 Shizuku PCM 会话。

## 内置能力

- Relay 设备注册、30 秒心跳、WebSocket 云端命令与 HTTP 补漏；
- Android Telecom 拨号、接听、拒接、挂断、DTMF 和系统短信发送；
- 来电 Push、通话生命周期以及单路云端 PCM 媒体编排；
- VoWLAN 本地控制和 PCM 链路；
- VoBLE 蓝牙本地控制和加密 G.711 μ-law 双向音频链路；
- 原 Agent `/api/health`、`/api/android/status`、通话和音频配置接口的进程内兼容层；
- 小米 HyperOS 默认电话角色引导，以及在系统角色界面不可用时通过已授权 Shizuku 设置默认电话 App；
- 非三星设备通过 Android `TYPE_TELEPHONY` 音频设备选择通话上下行，三星设备继续使用其语音 TX 路由。
- 默认电话角色的来电提供独立锁屏通话界面及接听/拒接通知动作；通话中可从通知返回界面挂断。Android 端保持静音转送策略，不因显示界面而自动切回本机听筒。

VoWLAN 的 `/api/calls/answer`、`/api/calls/reject`、`/api/calls/hangup` 接受可选 JSON `call_id`，值应为 `/api/calls/status` 中当前通话的 `id`。携带 ID 时只操作该通话；ID 过期或不匹配时拒绝执行，不会改选另一通。未携带 ID 的旧客户端保留当前通话兼容路径。

## 运行架构

```text
iPhone / Apple Watch
        │  VoWLAN、VoBLE 或 Cloudflare Relay
        ▼
AirSIM Android Standalone APK
        ├─ 内置 Agent：身份、心跳、命令和媒体编排
        ├─ Telecom / SMS：运营商通话与短信
        └─ Shizuku UserService：通话 PCM 桥
```

Shizuku 仍是采集和注入系统通话音频所需的权限桥。Standalone 不能绕过 Android/OEM 的安全边界，也不能替代系统紧急呼叫能力。

## 构建与测试

需要 JDK 17、Android SDK Platform 35、Build Tools 35 和 Python 3。构建脚本默认读取 `ANDROID_SDK_ROOT`；未设置时使用 Homebrew Android command-line tools 路径。

```sh
./android-standalone/test.sh
./android-standalone/build.sh
```

调试 APK 输出到：

```text
android-standalone/build/android/AirSIM-Android-Standalone-debug.apk
```

构建不可调试的正式签名 APK：

```sh
AIRSIM_ANDROID_BUILD_VARIANT=release \
AIRSIM_ANDROID_KEYSTORE=/absolute/path/to/airsim-android-release.jks \
AIRSIM_ANDROID_KEY_ALIAS=airsim \
AIRSIM_ANDROID_KEYSTORE_PASSWORD='从 Secret Store 注入' \
AIRSIM_ANDROID_KEY_PASSWORD='从 Secret Store 注入' \
./android-standalone/build.sh
```

正式 APK 输出为 `android-standalone/build/android/AirSIM-Android-Standalone-release.apk`。发布签名私钥和密码不得写入仓库、脚本、Release 或日志；覆盖升级时必须沿用上一版的签名证书。

## 安装与首次配置

1. 安装 APK，并启动 Shizuku；无线调试重启后通常需要重新启动 Shizuku。
2. 打开 AirSIM Standalone，授予电话、短信和通知权限，并按页面提示设为默认电话 App。可选择授权「读取短信」作为收件箱兜底：首次授权只记录当前收件箱位置，之后仅扫描新短信；拒绝时仍通过短信广播接收。部分安装来源可能因 Android 受限权限策略无法授予此权限。
   `读取手机状态/号码` 权限用于把 SIM 号码显示在 iPhone 的已配对 Agent 列表；运营商未写入本机号码或拒绝权限时，iPhone 会显示“号码未提供”，不影响拨号。
3. 小米 HyperOS 无法弹出默认电话选择页时，先在 Shizuku 中授权 AirSIM，再让 App 自动执行系统角色设置；无需手动运行 ADB 命令。
4. 在 Android 页面填写自己的 Relay 地址、设备标识与配对资料；使用自己的 Apple Bundle ID 时，Relay 的 `ALLOWED_BUNDLE_ID` 和 APNs topic 必须一致。
5. iPhone 与 Android 在同一热点或局域网时优先验证 VoWLAN；随后再验证 Relay 远程模式。

### 配置 VoBLE 蓝牙模式

VoBLE 是设置中的独立模式，不要求先建立 VoWLAN，也不会改变已有 VoWLAN/Relay 配置：

1. Android 保持 AirSIM Standalone 为默认电话 App，授予附近设备/蓝牙与通知权限，并确认 Shizuku PCM 音频桥显示运行中。
2. 在 Android 状态页启用 VoBLE；在 iPhone AirSIM 设置中选择“蓝牙直连”，扫描并选择目标 Android。
3. 两端核对同一个短码后确认配对。长期密钥仅保存在 Android Keystore 和 iOS Keychain，不应截图、记录或写入日志。
4. 配对完成后先做一通拨出和一通呼入，分别检查接听、拒接、挂断、静音、扬声器和 DTMF，再检查双向音频。

蓝牙模式通过 BLE GATT 传送控制与 G.711 μ-law 8 kHz 单声道音频，帧使用 AES-256-GCM 认证加密。它不使用 Relay、PushKit 或云端注册参数，也不提供 Bluetooth PAN 网络共享；iPhone 的互联网连接需要单独配置。Android PCM 桥、默认电话角色和系统 Telecom 仍是必需条件。三秒内的短暂断链只恢复同一 `call_id`/generation，超过三秒会结束本次媒体会话，防止旧包进入下一通电话。

iOS 被用户强制退出后不保证后台 BLE 来电唤醒；重新打开 AirSIM 后会恢复扫描。Apple Watch 由 iPhone 的 CallKit/WatchConnectivity 镜像来电与控制状态，不直接连接 Android BLE，音频能否切到手表取决于 iPhone/watchOS 的系统路由。

锁屏来电使用独立的高优先级「AirSIM 来电」通知渠道；Android 14 及以上若系统关闭了该 App 的全屏来电权限，可能只显示可操作的横幅通知。此权限由系统/用户控制，App 不能绕过。请在目标设备上分别实测锁屏接听、拒接、挂断以及 iPhone 端音频路径。

无线调试安装示例：

```sh
adb connect DEVICE_IP:WIRELESS_ADB_PORT
adb install -r android-standalone/build/android/AirSIM-Android-Standalone-debug.apk
```

无线调试地址与端口每次配对都可能变化，示例值不能当作固定设备配置。

## 从 AVF 版迁移

- Standalone 使用独立包名，不会自动读取旧 AVF 版 App 的本地数据；迁移前记录 Relay、设备 ID 和配对资料。
- 安装并验证 Standalone 后，将它设为默认电话 App；不要让两个 AirSIM 包同时控制同一通话。
- Standalone 正常工作后即可停止 AVF Agent。删除 Debian/AVF 数据属于独立的破坏性操作，不是 APK 安装流程的一部分。
- 需要回退时，重新把旧 App 设为默认电话 App，并恢复对应的 AVF Agent；两个版本可保留在设备上用于回退。

## 真机验收

- 页面显示内置 Agent、Relay 和 VoWLAN 状态正常，且不依赖 `8575/8576`；
- Android 重启后前台服务能恢复，Shizuku 失效时页面给出明确提示；
- iPhone 可拨号、接听、拒接、挂断和发送 DTMF；
- Android 与 iPhone 双向通话音频都从预期设备输出，没有回到小米本机听筒；
- 短信发送结果以 Android 系统回执为准，并由收件方确认实际收到；
- 分别测试同网 VoWLAN 与异网 Relay，通话中不切换传输路径。
- 单独选择 VoBLE 后关闭 Wi-Fi，确认拨出、呼入和双向音频不访问 Relay；再验证三秒内同通话恢复和超时终止。

完整项目级结果、未连接设备和失败场景记录在 [VoBLE 真机测试矩阵](../docs/voble-real-device-test-matrix.md)。

## 安全边界

- 通话 PCM 只在内存与网络中处理，不落盘；
- 日志不得包含完整短信、电话号码、Push token、配对密钥或 Relay 密钥；
- APK 不包含 APNs 私钥、Cloudflare token、Android 发布私钥或 Apple 签名身份；
- 本项目仅限 [PolyForm Noncommercial License 1.0.0](../LICENSE) 允许的非商业用途。
