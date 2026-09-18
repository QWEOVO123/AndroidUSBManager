# AndroidUSBManager

[English](README_ENG.md)

不依赖 LSPosed 的 Android USB 管理模块。由 **Magisk / KernelSU root 后端**负责 USB 控制，普通权限 APP 提供界面，通过应用私有目录中的原子文件交换命令。APP 本身不申请 root。

作者：**TigerSpirit217 & QWEOVO**

## 功能

- 连接电脑时选择仅充电、MTP 文件传输、PTP 图片传输、RNDIS 网络共享或 MIDI，并控制 ADB。
- 保存可信电脑及其 USB 配置；识别成功后自动应用并发送静默通知。
- 修改当前已识别电脑的配置后立即尝试应用；其他电脑的配置在下次连接时使用。
- 分别报告“电脑已保存”和“USB 配置已应用”，避免将配置失败误报为配对失败。
- APP 内提供“卸载并重启”，通过模块执行清理与重启。

## 运行要求与限制

- Android 8.0+，已安装 Magisk 或 KernelSU 并允许模块启动脚本运行。
- 内核需提供 USB Gadget ConfigFS、FunctionFS 和可用物理 UDC。
- 电脑识别需要 Windows 端 USBManagerWinBackEnd 配套程序运行；源码位于 [windows-backend](windows-backend)，可执行程序随 GitHub Release 提供。
- 基础条件检测是只读检查，不代表所有 ROM 都能成功枚举或恢复 USB；需要实际配对验证。
- 厂商 HAL、SELinux、USB 控制器行为不同，不保证所有机型兼容。建议先保存数据并保留模块管理器的恢复途径。
- 仅充电常规切换失败时会尝试解绑物理 UDC；切回数据模式时按已准备好的接口尝试重新绑定。
- 电脑身份认证并非手机与电脑的双向长期身份认证。

## 安装与使用

1. 在 Magisk / KernelSU 管理器中安装模块 ZIP，然后重启。不用于第三方 Recovery 刷入。
2. 打开 APP。Android 13+ 首次启动申请通知权限；拒绝通知不影响 USB 管理，可在首页进入通知设置。
3. 在电脑识别页面检查基础条件，开启识别，并在 Windows 后端运行时发起配对。
4. 选择并保存电脑的 USB 模式及 ADB 配置。再次连接后自动使用保存的配置。

**安装脚本会先卸载同包名旧 APP，再安装新 APP。** APP 设置和通知授权会清除，模块设置也会重置；已保存电脑记录保留。升级后请重新检查通知权限和识别开关。

## 卸载

推荐使用 **APP → 卸载并重启 → 二次确认**。

模块确认请求后 APP 退出；独立卸载脚本停止相关操作、卸载 APP、重置 USB 默认功能并关闭 ADB、删除本模块目录，然后重启。识别或配对忙时可能拒绝请求，界面显示错误原因。

标准 `uninstall.sh` 也支持模块管理器调用，但不会在管理器流程内主动重启。保存的电脑身份和诊断资料默认保留在 `/data/adb`，不会删除其他模块或整个数据目录。ROM 重启后是否覆盖仅充电默认值需在目标设备验证。

## 数据与通信

| 内容 | 位置 |
| --- | --- |
| APP 与 root 的命令 / 回执 | `/data/user_de/<用户>/com.tiger.usbmanager/files/root_bridge` |
| 电脑身份记录 | `/data/adb/usbmanager-auth/hosts` |
| 模块设置与运行状态 | `/data/adb/usbmanager` |
| 关键日志 | `/data/adb/usbmanager/logs` |

APP 文件通信使用 Device Protected Storage，不依赖 sdcard。临时认证接口使用 FunctionFS / WinUSB；认证使用 ECDSA P-256、临时 ECDH、HKDF-SHA256 和 AES-GCM。认证结束后交还 USB，并应用保存的模式。

## 日志

默认保留服务启动、USB 连接、配对/识别结果、配置应用结果、卸载以及错误信息。不再逐步打印 gadget 快照、FunctionFS 事件和每条握手消息，也不在每次失败时自动生成大份诊断。

`READY`、`AUTH_RESULT`、`BACKEND=` 等是内部状态协议，保留以免影响功能。已有日志文件不会自动删除；原有日志轮转仍保留。

需要排查时，在 root shell 手动运行：

```sh
sh /data/adb/modules/usbmanager_root/diagnose.sh
```

分享前请检查诊断文件中的设备标识与路径。开发排查可给脚本设置 `USBMANAGER_DEBUG=1`，启用 shell 详细日志；无需日常启用。

## Windows 上构建

需要 JDK 21+、Android SDK Platform / Build Tools 37 和 NDK 27.2.12479018；使用项目内 Gradle Wrapper。NDK 支持在 Windows 原生构建，无需 WSL。

配置本地 Android SDK 路径后运行：

```powershell
.\gradlew.bat :app:assembleDebug
.\tools\package-module.ps1 -SkipBuild
```

产物位于 `dist/USBManager-Root-v6.2.1-lite.zip`。目前打包的是 **debug 签名 APK**，不是已配置正式签名的商用发布包。ZIP 包含 arm64-v8a / x86_64 原生库及许可证。

## 回归检查

```powershell
.\tools\test-module-lifecycle.ps1
.\tools\test-host-edit.ps1
.\tools\test-interop.ps1
```

前两项需要 Git for Windows 的 Bash，采用模拟命令，不会实际卸载或重启设备。第三项还需要 .NET 8 SDK，默认使用仓库内的 `windows-backend/Program.cs`；可通过 MSBuild 的 `BackendSource` 属性或同名环境变量指定其他源码绝对路径。

测试不代替真机 USB 枚举、UI、通知或卸载验收。

## 鸣谢

感谢 **[TigerSpirit217](https://github.com/TigerSpirit217)** 提供原始 [USBManager](https://github.com/TigerSpirit217/USBManager) 项目及相关实现基础。本仓库在其基础上维护不依赖 LSPosed 的 root 模块方案，并保留原项目历史与许可证。

## 许可证

使用 **木兰公共许可证，第 2 版（MulanPubL-2.0）**，详见 [LICENSE](LICENSE)。保留原项目版权及许可声明。
