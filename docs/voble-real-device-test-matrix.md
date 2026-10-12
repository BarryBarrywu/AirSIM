# VoBLE 真机测试矩阵

本文记录 `VoBLE` 分支的可复现验证证据。状态只表示表中明确执行过的项目；未连接的设备和未发生的真实电话不会被记为通过。

## 验证基线

- 日期：2026-10-13（Asia/Shanghai）
- 基线提交：`45ef904`，文档提交以本文最终提交为准
- Xcode：27.0（27A266a）
- iPhone Air：iPhone18,4，iOS 27.0（24A437），开发者模式已启用，经局域网配对连接
- Android：本轮检查 `adb devices -l` 为空，三星与小米均未连接
- Apple Watch：两台已知设备均显示 unavailable
- 隐私：记录中不包含电话号码、短信内容、配对密钥、nonce、认证 tag、Push token 或 PCM

## 自动化与构建

| 范围 | 命令 | 结果 | 产物或说明 |
| --- | --- | --- | --- |
| Android Bridge JVM | `./android/phone-control-app/test.sh` | 通过 | core、NotificationUpdateGate、call repository 均通过；覆盖 VoBLE 协议、认证和 PCM 队列 |
| Android Standalone 集成 | `./android-standalone/test.sh` | 通过 | `BridgeUnitTests checks=47`，随后完成 Standalone Bridge 构建/签名检查 |
| Android AVF Bridge APK | `./android/phone-control-app/build.sh` | 通过 | `android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk`，APK v3 签名验证通过 |
| Android Standalone APK | `./android-standalone/build.sh` | 通过 | `android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`，APK v3 签名验证通过 |
| iOS 编译测试 | `xcodebuild build-for-testing ... generic/platform=iOS Simulator CODE_SIGNING_ALLOWED=NO` | 通过 | App 与 XCTest bundle 均成功编译 |
| iOS 运行时 XCTest | `xcodebuild test ... iPhone Air,OS=27.0` | 未形成完整最终结果 | 新增生命周期用例在运行中通过；CoreSimulator runner 随后消失/重启，不能据此宣称整套通过。此前 Task 6 基线曾完成 58 项通过 |
| iPhoneOS unsigned build | `xcodebuild build ... generic/platform=iOS CODE_SIGNING_ALLOWED=NO` | 通过 | arm64 App、Live Activity 与 Watch 目标编译成功；这是本地重签输入，不等同正式签名验收 |

## 真机安装与功能矩阵

| 设备/场景 | 状态 | 证据或阻塞原因 |
| --- | --- | --- |
| iPhone Air 覆盖安装（保留数据） | 通过 | 使用开发描述文件重签并覆盖 `AirSIM Diag`；`devicectl` 安装、启动成功，主进程与 Live Activity 扩展均存活；未清除 App 数据 |
| 三星 Standalone 覆盖安装 | 阻塞 | 本轮 `adb devices -l` 无设备，未执行安装或真实电话 |
| 三星 AVF Bridge + AVF PCM | 阻塞 | 三星未连接；未验证 AVF 地址变化后的下一会话解析 |
| 小米 HyperOS Standalone | 阻塞 | 小米未连接 |
| Apple Watch 镜像来电/停止响铃 | 阻塞 | Watch unavailable |
| Wi-Fi 关闭的 VoBLE 拨出/呼入 | 未执行 | 需要 Android 与 iPhone 同时在线并发生真实运营商电话 |
| 双向首包音频、静音、扬声器、DTMF | 未执行 | 同上 |
| 三秒内同 generation 恢复 | 自动化通过，真机未执行 | reducer/协调器覆盖；仍需真实 BLE 射频环境验证 |
| 超过三秒终止、错误密钥、撤销配对 | 自动化通过，真机未执行 | 仍需真机 UI 与系统行为验收 |
| 30 分钟队列/内存稳定性 | 未执行 | 需要持续真实通话，禁止用模拟结果代替 |

## 真机验收步骤

### Standalone

1. 用 `adb install -r android-standalone/build/android/AirSIM-Android-Standalone-debug.apk` 覆盖安装，禁止清除数据。
2. 确认默认电话角色、附近设备、通知、Shizuku 和 PCM 桥均正常。
3. iPhone 选择“蓝牙直连”，两端核对短码并确认。
4. 关闭两端 Wi-Fi，Relay 保持不可用；分别执行拨出和呼入。
5. 记录拨号响应、接听到首个音频帧、双向音频、静音、扬声器、DTMF、Android/iPhone 两端挂断，以及 Watch 是否停止响铃。
6. 通话中短断蓝牙少于三秒，只允许同 `call_id`/generation 恢复；再断开超过三秒，应结束媒体并清理 CallKit/实时活动。
7. 连续运行 30 分钟，观察 GATT 待发送队列、丢包、jitter、内存和电量；日志不得出现号码或密钥。

### AVF PCM

1. 覆盖安装 AVF Bridge，确认它与 Standalone 不同时持有默认电话角色。
2. 完成一通 VoBLE 双向电话并记录 AVF PCM 端点。
3. 结束电话后重启 AVF，使私网地址变化；下一通电话必须解析新地址。
4. 活跃通话期间不得原地切换端点；地址变化只作用于下一媒体会话。

### 小米与失败场景

在 HyperOS 上逐项检查后台限制、锁屏、错误密钥、撤销配对、Relay 不可用、VPN 开/关、Wi-Fi 关闭、iOS 强制退出后提示，以及蓝牙权限被撤销。VoBLE 模式不得因为 Relay/PushKit token 不可用而拒绝本地配对或拨号。

## 已知边界

- VoBLE 是独立模式，不是 VoWLAN 的依赖；一次通话建立后不会在 VoBLE、VoWLAN 和 Relay 之间无提示漂移。
- BLE 只承载 AirSIM 控制和音频，不实现 Android 到 iPhone 的 Bluetooth PAN 网络共享。
- 音频为 G.711 μ-law 8 kHz 单声道，控制和媒体均以 AES-256-GCM 认证；PCM 只在内存中处理。
- iOS 用户强制退出 App 后，系统不保证 BLE 后台唤醒。CallKit 可用于本地蓝牙通话，但本地模式不依赖 PushKit。
- Apple Watch 使用 iPhone 的 CallKit/WatchConnectivity 状态与系统音频路由，不是 Watch 到 Android 的直接 BLE 音频链路。
- 自动化测试不替代三星、小米、iPhone 与 Watch 的联合真机电话验收。
