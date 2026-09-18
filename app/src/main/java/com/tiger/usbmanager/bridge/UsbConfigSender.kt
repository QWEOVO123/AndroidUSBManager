package com.tiger.usbmanager.bridge

import android.content.Context
import com.tiger.usbmanager.policy.UsbMode

/** UI-only facade; all privileged work is performed by the root service. */
object UsbConfigSender {
    fun apply(context: Context, sessionId: String, mode: UsbMode, adb: Boolean): Boolean =
        BackendBridge.submitChoice(context, sessionId, mode, adb)

    fun sendChooserClosed(context: Context, sessionId: String, outcome: String): Boolean =
        BackendBridge.submitClose(context, sessionId, outcome)
}
