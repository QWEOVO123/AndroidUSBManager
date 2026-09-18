# AndroidUSBManager

[中文文档](README.md)

An Android USB manager with a Magisk / KernelSU root backend and an unprivileged UI. No LSPosed is required. Maintained by TigerSpirit217 & QWEOVO.

Supports USB mode selection, ADB control, saved computer profiles, silent known-computer notifications and confirmed in-app uninstall/reboot. Computer authentication requires the separate Windows USBManagerWinBackEnd companion, not included here.

## Installation

Install the module ZIP in Magisk / KernelSU Manager and reboot. Open the APP, grant notification permission if desired, check prerequisites and enable computer recognition before pairing.

Installation first uninstalls any existing APP with the same package name. APP settings, notification grants and module preferences are reset; trusted-host records are retained. Recheck settings after upgrades.

## Build

Use JDK 21+, Android SDK / Build Tools 37, NDK 27.2.12479018 and the included Gradle wrapper:

```powershell
.\gradlew.bat :app:assembleDebug
.\tools\package-module.ps1 -SkipBuild
```

Output: `dist/USBManager-Root-v6.2-fix17.zip`. Packaging currently uses the debug-signed APK. Windows-native NDK builds do not require WSL.

## Logs and removal

Only key lifecycle/results/errors are logged by default. Internal protocol markers such as READY and AUTH_RESULT remain intact. Existing logs are not deleted. Detailed diagnostics are available by running `/data/adb/modules/usbmanager_root/diagnose.sh` from a root shell.

Use the APP's **Uninstall and reboot** action. Confirmation is required. Module-manager uninstall hooks do not themselves reboot. Host records and diagnostic data remain in /data/adb.

## Compatibility

Android 8.0+, USB Gadget ConfigFS, FunctionFS and a physical UDC are required. Read-only prerequisite detection does not guarantee successful enumeration. OEM HAL and SELinux differences require device testing. Charging-only fallback can unbind the physical gadget. This is host authentication, not mutual persistent device authentication.

See the Chinese README for storage paths and regression-test dependencies. Mocked tests do not replace physical-device validation.

## Acknowledgements and license

Thanks to **[TigerSpirit217](https://github.com/TigerSpirit217)** for the original [USBManager](https://github.com/TigerSpirit217/USBManager) project and implementation foundation.

Licensed under **Mulan Public License, Version 2 (MulanPubL-2.0)**. See [LICENSE](LICENSE). Original history and notices are retained.
