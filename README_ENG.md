# USBManager — Android USB Management Module

[中文](README.md)

USBManager is an **LSPosed** system module for Android. When the phone is connected to a computer by cable, it displays a USB chooser so the user can select the USB mode and ADB state for that connection.

## Features

* **Automatic connection detection:** detects when the phone connects to a computer as a USB device.
* **Per-connection mode selection:** supports Charge only, File transfer (MTP), Photo transfer (PTP), USB tethering (RNDIS), and MIDI.
* **One-tap ADB control:** selects whether USB debugging is enabled for the current connection.
* **No OTG prompts:** USB drives, keyboards, mice, and other peripherals connected while the phone acts as host remain under normal Android handling.
* **ADB off on unplug:** optionally turns USB debugging off when the cable is removed.
* **Lock-screen deferral:** waits until unlock by default, with an option to display the chooser while locked.

## Experimental Computer Recognition and Memory

This feature allows the phone to recognize and remember trusted computers. It is disabled by default. While disabled, the USB chooser continues to appear for every computer connection.

For first-time setup, open **Computer Recognition and Memory**, tap the detection button, and grant root when requested. Detection runs entirely on the phone and does not require a cable or computer. If root is not granted, the app asks for authorization.

After detection succeeds, the feature can be enabled. For first-time pairing, tap **Allow one new computer to pair** on the phone. Enter a computer name and select its USB mode and ADB state (for example, MTP + ADB). Keep the cable connected and the Windows companion running; pairing remains available for about 60 seconds after the interface is ready. The name and configuration are stored together with the authenticated identity and applied after pairing. Saved computers can be renamed and reconfigured in the same Edit dialog, or removed.

On later cable connections, the phone verifies the computer automatically. After authentication, the temporary recognition interface is restored to normal USB control and the saved USB mode and ADB state are applied without another chooser. Older records without a configuration continue to show the chooser until edited and saved. Edits take effect on the next recognition. An unknown computer, a timeout, or a failed verification falls back to the normal chooser. An unknown computer cannot add itself to the trust list.

The current compatibility targets are AOSP, Google Android, and near-stock systems. The in-app result is authoritative because vendors may alter or restrict system USB behavior. Support cannot be inferred from an Android version or brand alone. The feature does not modify the phone kernel.

Normal app startup and the standard USB chooser do not request root. Root is used only for the local capability check, recognition sessions after the feature is enabled, and saved-device management.

This feature requires the **[USBManagerWinBackEnd](https://github.com/TigerSpirit217/USBManagerWinBackEnd)** Windows companion. Its application, instructions, and release files are provided by the corresponding project.

## Installation

### Requirements

* An Android device with an unlocked bootloader and root access.
* **LSPosed**.
* Android 11 or later; Android 12+ is recommended.

### Steps

1. Download the latest APK from [Releases](../../releases).
2. Install the APK.
3. Enable **USBManager** in **LSPosed Manager → Modules**.
4. Add system (the Android framework) to the module scope.
5. Reboot the device.
6. Open USBManager and verify that the module status is healthy.

## Usage

1. Connect the phone to a computer with a USB cable.
2. Select a USB mode and the ADB state in the chooser.
3. Tap **OK** to apply.

The defaults are Charge only, USB debugging off, ADB off on unplug enabled, and chooser display while locked disabled. These options are configurable on the main page.

## Building

    git clone https://github.com/TigerSpirit217/USBManager.git
    cd USBManager
    ./gradlew :app:assembleRelease

## Debugging

Search for USBManager in LSPosed Manager logs, or run:

    adb logcat -s USBManager

Main log markers:

* **[WATCHER]**: USB connection and chooser flow.
* **[AUTH]**: computer recognition.
* **[RX]**: system broadcasts.
* **[HOOK]**: module loading.
* **[CLIENT]**: communication between the app and system module.
* **[CONTROLLER]**: USB mode and ADB application.

## License

This project is licensed under the Mulan Public License, version 2 (Mulan PubL v2). See [LICENSE](https://license.coscl.org.cn/MulanPubL-2.0) for the full license.

## Source and Releases

* Source: <https://github.com/TigerSpirit217/USBManager>
* Releases: <https://github.com/TigerSpirit217/USBManager/releases>
* Issues: <https://github.com/TigerSpirit217/USBManager/issues>
