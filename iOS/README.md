# AirSIM iOS 与 watchOS

该目录包含面向三星 Android 电话端的 iPhone、Apple Watch、Live Activity 与共享模型。客户端可通过 VoWLAN 或 VoBLE 直连三星手机，也可通过独立 Cloudflare Relay 使用远程通话与短信。

当前应用构建为 `v0.9.7 (80)`，同版本公开 Release 提供 build `80` 的 unsigned IPA；配套 AVF Agent 为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；自行更换 Bundle ID 后必须使用自己的 Relay 和 APNs 凭据。

## Xcode 工程

打开：

```text
iOS/AirSIM.xcodeproj
```

主要 target：

- `AirSIM`：iPhone / iPad 主 App
- `AirSIMWatchApp`：Apple Watch App
- `AirSIMLiveActivityExtension`：锁屏与灵动岛实时活动
- `AirSIMTests`：传输选择和协议边界测试

## 客户端能力

- 三星设备一次性加密配对
- VoWLAN 服务发现、HMAC 鉴权和健康检查
- CallKit 拨号、来电、接听、挂断、静音与 DTMF
- PushKit、通知 APNs 与 ActivityKit
- 首次进入前台优先申请麦克风权限；完成麦克风授权决策后才启动本地发现和通知授权。若系统暂缓弹窗，下次进入前台会重试，不需要重新配对。
- Apple Watch 拨号、接听和通话媒体
- 短信列表、发送、通知和联系人整合
- VoWLAN、VoBLE 与云端 Relay 传输选择；自动模式只按实际可用的拨号路由选择，优先级固定为 VoWLAN → VoBLE → 云端
- VoBLE 的拨号可用性由已认证的蓝牙会话和媒体通道判断，不依赖 Relay、VoWLAN 健康检查或 HTTP 200
- 拨号页、配对设备列表、锁屏实时活动与灵动岛同步显示 VoBLE 在线状态和当前传输
- VoBLE 通话的灵动岛接听、拒接和挂断会唤起 AirSIM，由主 App 的已认证 CoreBluetooth 会话执行；不会错误请求 VoWLAN 固定地址或 Relay
- VoBLE 配对页支持经认证的双端取消配对；密钥错位时会给出 Android 本地清除路径，并允许清除 iPhone Keychain 中的旧凭据后重新扫描
- 云端 PCM 使用有界缓冲与 20 毫秒发送节奏，降低突发网络抖动时的卡顿风险。
- 设置页实时显示当前 VoWLAN / 云端模式与 Agent 心跳状态
- 云端模式在 App 进入前台时查询一次 Relay 状态；需要走云端拨号时再核对一次，灵动岛显示通话前等待一次状态查询（后台来电也适用）。本地模式不查询 Relay，VoWLAN 失联和后台待机更新不会启动定时云端查询，避免反复消耗请求额度。
- 四阶段云端自检：本机 Push 凭据、Relay 身份、设备注册、Agent 心跳
- 本地通话记录、单条滑动删除、详情删除、诊断和媒体健康状态

VoWLAN 接听、拒接和挂断请求在已知当前通话时携带 `/api/calls/status` 返回的 `call_id`（JSON 字段 `call_id`）。Standalone 与新版 AVF Agent 会校验它，避免旧来电通知误操作后续通话；未取得通话 ID 时仍可发送兼容旧版 Agent 的空请求。

### 短信收发与推送

AirSIM 与 DJOneHub 采用相同的通道分工，但使用各自独立的 Relay 和 APNs topic：iPhone 发短信时，VoWLAN 就绪则直接调用 Agent；离线且云端模式开启时，向 Relay 提交经设备鉴权的 `send_sms` 命令，由 AVF Agent 执行并回传结果。Agent 收到短信后，把带 `delivery_id` 的事件送到 Relay；Relay 使用主 App topic 的普通 APNs `alert` 通知 iPhone，App 保存本地历史并按 `delivery_id` 与下次 Agent 同步去重。点开通知会进入发件人会话，冷启动时也会保留这一导航请求。

PushKit VoIP push 仅用于真实来电并交给 CallKit，不能拿它承载短信正文或唤醒发信任务。短信通知需要用户允许普通通知、iPhone 已取得 alert token，且 Relay、Agent 注册与心跳正常。普通 APNs 的送达及后台执行由 iOS 决定；正式验收必须分别测试前台、锁屏、冷启动和云端发信，不应把控制面自检通过等同于短信实测通过。

## 首次配置

1. 在三星手机启动 AirSIM，并确认 Agent 与 Shizuku 音频桥就绪。
2. 将 iPhone 连接到三星热点或同一局域网。
3. 在三星端打开两分钟配对窗口。
4. 在 iPhone 输入三星端显示的六位配对码。
5. 等待 VoWLAN 状态显示为就绪。
6. 如需 VoBLE，在“连接模式”选择蓝牙并完成系统蓝牙授权及 AirSIM 配对；看到“VoBLE 在线”后即可本地拨号，无需填写 Relay 参数。
7. 如需远程模式，在“云端 Relay”填写与当前签名身份匹配的独立 Relay 地址，点击“保存 Relay 地址”，再启用“远程通话与短信”。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；其他 Bundle ID 必须使用自行部署的 Relay。
8. 打开“设置 → 云端模式自检”。四项全部通过才代表云端控制链路可用；“Relay 身份”会拒绝 DJOneHub 或其他服务，“Agent 心跳”要求 AVF Agent 在最近 90 秒内上报。自检不会拨号或发送短信。

### 管理已配对 Android 设备

「设置 → 三星连接 → 配对三星手机」下方列出已配对设备，显示当前读取的设备名、号码与 VoWLAN/VoBLE/云端状态，支持逐个确认删除。离线历史只保留设备标识、名称和 Agent 类型，不保存号码。号码不可读或 SIM 未提供时显示“号码未提供”，不会用历史号码补齐。

删除会清除本机列表项、手动绑定与该设备的蓝牙凭据，并保留拒绝自动重连的设备标记；其他设备、通话记录和短信不受影响。在线蓝牙设备会尝试同时撤销 Android 凭据；离线删除不等同远端授权撤销，远端旧凭据可能需要在 Android「VoBLE 认证配置」中清除。删除的设备必须显式重新配对，不能被广播或云端旧状态自动加回。

重连使用当前广播和认证检查，不再凭缓存外设 UUID 建立连接。新版 Android APK 支持经认证的 BLE `device_info` 查询；旧 APK 不支持时不会借用 VoWLAN/Relay 的历史号码。Standalone 云端心跳及本地健康检查读取当前通话卡，不采用首次配对保存的号码。旧 AVF Linux Agent 的云端号码心跳尚未迁移到这一读取流程。

## 构建与测试

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

在指定模拟器运行测试：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 签名与推送

诊断包若从 `CODE_SIGNING_ALLOWED=NO` 的 Debug 构建重新签名，必须先签所有内嵌动态库（包括主 App 和 Live Activity 扩展各自的 `*.debug.dylib`、`__preview.dylib`），再由内到外签扩展与主 App。只对 `.app` 执行 `codesign --verify --deep --strict` 不足以证明位于包根目录的 Debug 动态库已签名；需对每个 `.dylib` 单独执行签名验证，并以真机启动后进程持续存活作为安装验收。漏签会在进入 App 代码前产生 DYLD `Library missing / missing code signature` 闪退。

这是源码可见、仅限非商业用途的工程，不提供原作者的 Apple Developer Team、App ID、证书或 provisioning profile。工程中的 `com.example.airsim` 是占位符，不能直接用于发布。首次真机构建前必须使用自己的 Apple Developer 账号重新配置并签名：

1. 在 Xcode 为 `AirSIM` 选择自己的 Team，将 Bundle Identifier 改为自己控制的唯一标识，例如 `org.example.airsim`。
2. 将 Watch App 改为主标识加 `.watchkitapp`，例如 `org.example.airsim.watchkitapp`，并将 `WKCompanionAppBundleIdentifier` 设置为主 App 标识。
3. 将 Live Activity Extension 改为主标识加 `.liveactivity`，例如 `org.example.airsim.liveactivity`；测试 Target 可使用主标识加 `.tests`。
4. 在 Apple Developer 为三个正式 Target 创建 Explicit App ID，启用所需 capabilities，并重新生成属于自己 Team 的开发/分发 provisioning profile。
5. 在 Relay 的 `ALLOWED_BUNDLE_ID` 使用同一个主 App 标识；PushKit、Watch 和 Live Activity 的 APNs topic 会以它为基础生成。

只替换签名证书而保留其他人的 Bundle ID 不会获得对应 App ID/APNs topic 的权限。主 App、Watch、Live Activity、provisioning profile 与 Relay 必须使用同一套标识关系。

Relay 地址通过 `AIRSIM_PUSH_RELAY_URL` 注入，APNs 环境通过 `AIRSIM_APNS_ENVIRONMENT` 配置。Debug 开发签名对应 APNs `sandbox`，Release/TestFlight 对应 `production`。

不要把 DJOneHub 的 `https://push.remotepilot.site` 填入 AirSIM。该地址只允许 DJOneHub Bundle ID；AirSIM 与 DJOneHub 的设备注册、命令队列、媒体会话和 Dashboard 相互隔离。维护者 AirSIM 地址也只接受 `com.eric3u.airsim`，开源使用者更换 Bundle ID 后必须同步更换 Relay `ALLOWED_BUNDLE_ID` 和 APNs 凭据。

新安装需要重新完成三星配对、通知授权、CallKit/PushKit 注册和 Watch 配套安装。

GitHub Release 中的 `AirSIM-iOS-<version>-unsigned.ipa` 是供重签的 arm64 构建产物，不包含 `_CodeSignature` 或 `embedded.mobileprovision`，不能直接安装。不能只签主 App：必须同步替换并签署 Watch App 与 Live Activity Extension 的 Bundle ID、entitlements 和 provisioning profile。公开 Release 不应上传包含开发设备 UDID 的 development/ad hoc IPA。

## 安全与隐私

- VoWLAN Secret 保存在 Keychain，不写入 UserDefaults 或日志。
- 配对使用 X25519、HKDF-SHA256 与 AES-256-GCM。
- 控制请求使用 HMAC-SHA256、时间窗口和 nonce 防重放。
- 通话 PCM 仅在内存和网络流中处理，不落盘。
- 日志与错误界面不得显示设备 Secret、HMAC、Push token 或完整媒体地址。

## 当前状态

模拟器构建与测试已覆盖主要协议和传输选择。正式发布前仍需完成 Apple 签名、实体 iPhone/Apple Watch 安装、三星实机拨号接听、双向语音、短信与后台推送验收。
