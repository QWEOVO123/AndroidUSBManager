package com.tiger.usbmanager.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.RadioGroup
import android.widget.RadioButton
import android.widget.Toast
import com.tiger.usbmanager.ModuleConstants
import com.tiger.usbmanager.R
import com.tiger.usbmanager.bridge.UsbConfigSender
import com.tiger.usbmanager.policy.UsbMode
import com.tiger.usbmanager.auth.RecognitionSettings

/**
 * Dialog activity launched by the root service every time a USB device-mode
 * connection is detected (the phone plugged into a computer). Shows the USB mode
 * picker and an ADB toggle, then writes the choice for the root service via
 * [UsbConfigSender].
 *
 * When identification is enabled this chooser is the fallback for unknown computers
 * and its last confirmed choice seeds the next pairing profile.
 *
 * Runs as an ordinary app process, so a UI crash cannot take down the root backend.
 *
 * ## Outcome signalling
 *
 * No matter how the user closes this activity (+ve / -ve / back / swipe-away)
 * we write a close command so the root service can finish the session. Paths:
 *   - Positive button → outcome="confirmed" (also sends APPLY_USB_CONFIG)
 *   - Negative button → outcome="cancelled"
 *   - onBackPressed / onCancel / finish without explicit action → outcome="dismissed"
 *   Guarded by a `finished` boolean so we never send duplicates.
 */
class UsbChooserActivity : Activity() {

    private var sessionId: String = ""
    private var outcomeReported: Boolean = false

    /**
     * Listens for the root service's ACTION_DISMISS_CHOOSER (sent when the USB cable is
     * unplugged while we're still on screen). On receipt we finish ourselves so the
     * chooser window doesn't linger after the cable is pulled. Registration is scoped
     * to the activity's visible lifetime (onStart/onStop) and guarded by token.
     */
    private val dismissReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val received = intent.getStringExtra(ModuleConstants.EXTRA_SESSION_ID).orEmpty()
            if (received != sessionId) return
            finish()
        }
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(ModuleConstants.ACTION_DISMISS_CHOOSER)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(dismissReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(dismissReceiver, filter)
            }
        }.onFailure { /* best-effort; chooser still closable via buttons */ }
    }

    override fun onStop() {
        runCatching { unregisterReceiver(dismissReceiver) }.onFailure { }
        super.onStop()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val preselectMode = UsbMode.fromWire(intent?.getStringExtra(ModuleConstants.EXTRA_USB_MODE))
        val rawPreselectAdb = intent?.getBooleanExtra(ModuleConstants.EXTRA_ADB_ENABLED, false) ?: false
        sessionId = intent?.getStringExtra(ModuleConstants.EXTRA_SESSION_ID).orEmpty()
        if (!sessionId.matches(Regex("[0-9a-f]{32}"))) {
            finish()
            return
        }

        // This activity is exported so the root service can start it, which means any
        // third-party app can also launch it with forged extras (e.g. ADB pre-ticked)
        // as a social-engineering vector. When the caller is an untrusted app we
        // refuse to honour a pre-selected "ADB on" — the user must explicitly check
        // ADB themselves. The strong root-generated session id below is the
        // authoritative gate for applying any choice.
        val caller = getCallingActivity()
        val trustedPublisher = caller == null || caller.packageName == ModuleConstants.MODULE_PACKAGE
        val preselectAdb = rawPreselectAdb && trustedPublisher

        val padding = dp(22)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        val icon = android.widget.ImageView(this).apply {
            setImageResource(R.drawable.ic_connection_notification)
            imageTintList = android.content.res.ColorStateList.valueOf(getColor(R.color.accent))
            setPadding(dp(12), dp(12), dp(12), dp(12))
            UiStyle.card(this, getColor(R.color.banner_unknown_bg))
            importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        root.addView(icon, LinearLayout.LayoutParams(dp(48), dp(48)).apply { bottomMargin = dp(8) })
        root.addView(UiStyle.heading(this, "USB 连接"))
        root.addView(UiStyle.note(this, "为这次连接选择用途\n电脑识别与已保存配置可在 APP 中管理"))

        val radioGroup = RadioGroup(this).apply {
            orientation = RadioGroup.VERTICAL
        }
        UsbMode.entries.forEach { mode ->
            RadioButton(this).apply {
                val description = when (mode) {
                    UsbMode.CHARGING -> "关闭文件传输"
                    UsbMode.MTP -> "浏览与传输文件"
                    UsbMode.PTP -> "导入照片与影像"
                    UsbMode.RNDIS -> "通过 USB 共享网络"
                    UsbMode.MIDI -> "连接音乐与 MIDI 设备"
                }
                text = getString(mode.displayRes) + "\n" + description
                textSize = 14f
                setTextColor(getColor(R.color.text_primary))
                background = UiStyle.option(this@UsbChooserActivity)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                minHeight = dp(62)
                layoutParams = RadioGroup.LayoutParams(-1, -2).apply { bottomMargin = dp(8) }
                id = mode.ordinal + 100
                isChecked = mode == preselectMode
                radioGroup.addView(this)
            }
        }
        root.addView(radioGroup)

        val adbCheck = android.widget.Switch(this).apply {
            text = "ADB 调试"
            textSize = 15f
            setPadding(dp(14), dp(14), dp(14), dp(14))
            UiStyle.card(this, getColor(R.color.banner_unknown_bg))
            isChecked = preselectAdb
        }
        root.addView(adbCheck)

        AlertDialog.Builder(this)
            .setView(android.widget.ScrollView(this).apply { addView(root) })
            .setPositiveButton(R.string.chooser_confirm) { _, _ ->
                val selectedMode = UsbMode.entries.firstOrNull {
                    radioGroup.checkedRadioButtonId == it.ordinal + 100
                } ?: UsbMode.MTP
                val adb = adbCheck.isChecked

                RecognitionSettings.recordChooserSelection(this, selectedMode, adb)

                reportOutcome("confirmed")
                val appContext = applicationContext
                val submittedSession = sessionId
                Thread {
                    val applied = runCatching {
                        UsbConfigSender.apply(appContext, submittedSession, selectedMode, adb)
                    }.getOrDefault(false)
                    runOnUiThread {
                        Toast.makeText(appContext,
                            if (applied) "USB: " + selectedMode.name + if (adb) " + ADB" else ""
                            else "USB configuration failed. Check backend status/logs.",
                            Toast.LENGTH_LONG).show()
                    }
                }.start()
                finish()
            }
            .setNegativeButton(R.string.chooser_cancel) { _, _ ->
                reportOutcome("cancelled")
                finish()
            }
            .setOnCancelListener {
                reportOutcome("dismissed")
                finish()
            }
            .create()
            .apply {
                window?.setGravity(Gravity.CENTER)
                show()
                window?.setBackgroundDrawable(UiStyle.round(this@UsbChooserActivity, getColor(R.color.bg_card), 28))
                window?.setLayout((resources.displayMetrics.widthPixels * 0.92f).toInt().coerceAtMost(dp(480)), android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
                getButton(AlertDialog.BUTTON_POSITIVE)?.let { UiStyle.polish(it) }
            }
    }

    override fun onBackPressed() {
        reportOutcome("dismissed")
        super.onBackPressed()
    }

    override fun onDestroy() {
        // Safety net: if neither positive / negative / onCancel / onBackPressed
        // fired (e.g. system killed the task), emit "dismissed" once.
        if (!isChangingConfigurations) reportOutcome("dismissed")
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Do not let the old instance dismiss a replacement session on destroy.
        outcomeReported = true
        recreate()
    }

    private fun reportOutcome(outcome: String) {
        if (outcomeReported) return
        outcomeReported = true
        UsbConfigSender.sendChooserClosed(this, sessionId, outcome)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
