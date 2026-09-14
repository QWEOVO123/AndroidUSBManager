# USBManager — Android USB 管理模块

[English](README_ENG.md)

USBManager 是一个基于 **LSPosed** 的 Android 系统模块。手机通过数据线连接电脑时，它会显示 USB 选择窗口，让用户决定本次连接的 USB 模式和 ADB 状态。

## 功能

* **自动检测连接**：自动识别手机以设备模式连接电脑的事件。
* **连接时选择模式**：支持仅充电、文件传输（MTP）、图片传输（PTP）、USB 网络共享（RNDIS）和 MIDI。
* **ADB 一键开关**：在选择窗口中决定本次是否启用 USB 调试。
* **OTG 不弹窗**：手机作为 USB 主机连接 U 盘、键鼠等设备时交给系统原生处理。
* **拔线自动关闭 ADB**：可在设置中关闭；启用时，拔出数据线后自动关闭 USB 调试。
* **锁屏延迟弹窗**：默认等待解锁后显示，也可允许锁屏时弹出。

## 实验性电脑识别与记忆

该功能用于让手机识别并记住可信电脑。功能默认关闭，关闭时仍会在每次连接电脑时显示 USB 选择窗口。

首次使用时，在应用的“电脑识别与记忆”页面点击检测并按提示授予 root。检测完全在手机本地完成，不要求先连接数据线或电脑。未授予 root 时，应用会提示需要授权。

检测通过后可以开启功能。首次配对时，在手机页面点击“允许一台新电脑配对”。配对成功后，电脑会显示在已保存列表中，可随时移除。

后续插线时，手机会自动验证电脑身份。已保存电脑直接进入可用状态，不再显示 USB 选择窗口；未知电脑、验证超时或失败时仍会显示普通选择窗口。未知电脑无法自行加入信任列表。

当前主要适配目标是 AOSP、Google 原生及类原生系统。设备是否支持以应用内检测结果为准；厂商可能修改或限制系统 USB 功能，因此不能只根据 Android 版本或品牌判断。整个方案不修改手机内核。

应用正常启动和基础 USB 选择功能不会请求 root。只有本地支持检测、功能开启后的识别会话以及已保存设备管理会使用 root。

该功能需要配套的 **[USBManagerWinBackEnd](https://github.com/TigerSpirit217/USBManagerWinBackEnd)** Windows 后端，其程序、说明和发布文件位于对应项目。

## 安装

### 前置条件

* 已解锁 Bootloader 并取得 root 的 Android 设备。
* 已安装 **LSPosed**。
* Android 11 或更高版本，推荐 Android 12+。

### 步骤

1. 从 [Releases](../../releases) 下载最新 APK。
2. 安装 APK。
3. 在 **LSPosed Manager → 模块**中启用 **USBManager**。
4. 作用域勾选 system（系统框架）。
5. 重启设备。
6. 打开 USBManager，确认模块检测显示正常。

## 使用

1. 插入连接电脑的数据线。
2. 在 USB 选择窗口中选择模式和 ADB 状态。
3. 点击“确定”应用。

默认 USB 模式为**仅充电**，默认关闭 USB 调试；拔线自动关闭 ADB 默认开启，锁屏弹窗默认关闭。这些选项均可在应用主页修改。

## 构建

    git clone https://github.com/TigerSpirit217/USBManager.git
    cd USBManager
    ./gradlew :app:assembleRelease

## 调试

可在 LSPosed Manager 的日志页面搜索 USBManager，或使用：

    adb logcat -s USBManager

主要日志标记：

* **[WATCHER]**：USB 连接和选择流程。
* **[AUTH]**：电脑识别流程。
* **[RX]**：系统广播。
* **[HOOK]**：模块加载。
* **[CLIENT]**：应用与系统模块通信。
* **[CONTROLLER]**：USB 模式和 ADB 应用。

## 许可证

本项目使用木兰公共许可证，第 2 版（Mulan PubL v2）。完整授权见 [LICENSE](https://license.coscl.org.cn/MulanPubL-2.0)。

## 源码与发布

* 源码仓库：<https://github.com/TigerSpirit217/USBManager>
* 发布页面：<https://github.com/TigerSpirit217/USBManager/releases>
* 问题反馈：<https://github.com/TigerSpirit217/USBManager/issues>
