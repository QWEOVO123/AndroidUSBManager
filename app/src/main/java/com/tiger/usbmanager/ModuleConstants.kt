package com.tiger.usbmanager

/** Contract shared by the UI APK and the root module scripts. */
object ModuleConstants {
    const val MODULE_PACKAGE = "com.tiger.usbmanager"
    const val CHOOSER_ACTIVITY = "$MODULE_PACKAGE.ui.UsbChooserActivity"
    const val ACTION_DISMISS_CHOOSER = "$MODULE_PACKAGE.action.DISMISS_CHOOSER"

    const val EXTRA_USB_MODE = "usb_mode"
    const val EXTRA_ADB_ENABLED = "adb_enabled"
    const val EXTRA_SESSION_ID = "session_id"

    const val PREFS_SETTINGS = "usbmanager_settings"
}
