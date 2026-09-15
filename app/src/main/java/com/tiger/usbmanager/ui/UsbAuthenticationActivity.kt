package com.tiger.usbmanager.ui

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.*
import com.tiger.usbmanager.R
import com.tiger.usbmanager.ModuleSettings
import com.tiger.usbmanager.auth.KnownComputer
import com.tiger.usbmanager.policy.UsbMode
import android.text.InputFilter
import com.tiger.usbmanager.auth.RecognitionSettings
import com.tiger.usbmanager.auth.RootAuthManager
import java.text.DateFormat
import java.util.Date

class UsbAuthenticationActivity : Activity() {
    private lateinit var content: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        render()
    }

    private fun render(message: String? = null) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(getColor(R.color.bg_page))
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(getColor(R.color.bg_card))
            setPadding(dp(8), dp(12) + statusBarHeight(), dp(16), dp(12))
            addView(Button(this@UsbAuthenticationActivity).apply {
                text = "‹"
                setOnClickListener { finish() }
            })
            addView(TextView(this@UsbAuthenticationActivity).apply {
                text = getString(R.string.auth_page_title)
                textSize = 20f
                setTextColor(getColor(R.color.text_primary))
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            })
        })
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(28))
        }
        content.addView(TextView(this).apply {
            text = getString(R.string.auth_usage)
            textSize = 14f
            setTextColor(getColor(R.color.text_body))
            setLineSpacing(0f, 1.18f)
        })
        if (message != null) content.addView(status(message))

        if (!RecognitionSettings.isSupported(this)) {
            content.addView(Button(this).apply {
                text = getString(R.string.auth_detect)
                setOnClickListener { runDetection() }
                layoutParams = margins(dp(18))
            })
        } else {
            content.addView(status(getString(R.string.auth_supported)))
            content.addView(toggle(getString(R.string.auth_enable), RecognitionSettings.isEnabled(this)) { enabled ->
                RecognitionSettings.setEnabled(this@UsbAuthenticationActivity, enabled)
                if (!enabled) Thread { runCatching { RootAuthManager.restore(this@UsbAuthenticationActivity) } }.start()
                render()
            })
            if (RecognitionSettings.isEnabled(this)) {
                content.addView(Button(this).apply {
                    text = getString(R.string.auth_allow_pair)
                    setOnClickListener { editComputer(null) }
                    layoutParams = margins(dp(8))
                })
                content.addView(TextView(this).apply {
                    text = getString(R.string.auth_saved_title)
                    textSize = 17f
                    setTextColor(getColor(R.color.text_primary))
                    setPadding(0, dp(22), 0, dp(8))
                })
                loadKnownComputers()
            }
        }
        root.addView(ScrollView(this).apply { addView(content) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    private fun runDetection() {
        showBusy(getString(R.string.auth_detecting))
        Thread {
            val result = runCatching { RootAuthManager.detect(this) }.getOrElse {
                RootAuthManager.Detection(
                    false,
                    detail = it.message.orEmpty(),
                    failure = RootAuthManager.DetectionFailure.UNSUPPORTED,
                )
            }
            runOnUiThread {
                val message = when {
                    result.supported -> R.string.auth_detect_pass
                    result.failure == RootAuthManager.DetectionFailure.ROOT_REQUIRED -> R.string.auth_detect_root_required
                    else -> R.string.auth_detect_fail
                }
                render(getString(message))
            }
        }.apply { name = "usb-auth-detection"; start() }
    }

    private fun editComputer(computer: KnownComputer?) {
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), dp(8))
        }
        val name = EditText(this).apply {
            hint = getString(R.string.auth_computer_name)
            setSingleLine(true)
            filters = arrayOf(InputFilter.LengthFilter(64))
            setText(computer?.label.orEmpty())
        }
        val mode = Spinner(this).apply {
            adapter = ArrayAdapter(this@UsbAuthenticationActivity, android.R.layout.simple_spinner_dropdown_item,
                UsbMode.entries.map { getString(it.displayRes) })
            setSelection((computer?.mode ?: UsbMode.fromWire(ModuleSettings.defaultMode())).ordinal)
        }
        val adb = CheckBox(this).apply {
            text = "ADB"
            isChecked = computer?.adb ?: ModuleSettings.defaultAdb()
        }
        form.addView(name); form.addView(mode); form.addView(adb)
        val dialog = AlertDialog.Builder(this)
            .setTitle(if (computer == null) R.string.auth_allow_pair else R.string.auth_edit)
            .setView(form)
            .setNegativeButton(R.string.dialog_cancel, null)
            .setPositiveButton(R.string.auth_save, null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val label = name.text.toString().trim()
                if (label.isEmpty() || label.any { it.isISOControl() }) {
                    name.error = getString(R.string.auth_name_required)
                    return@setOnClickListener
                }
                val selectedMode = UsbMode.entries[mode.selectedItemPosition]
                val selectedAdb = adb.isChecked
                dialog.dismiss()
                if (computer == null) runPairingWindow(label, selectedMode, selectedAdb)
                else {
                    showBusy(getString(R.string.auth_saving))
                    Thread {
                        val ok = runCatching { RootAuthManager.update(this, computer.id, label, selectedMode, selectedAdb) }.getOrDefault(false)
                        runOnUiThread { render(getString(if (ok) R.string.auth_saved else R.string.auth_save_failed)) }
                    }.start()
                }
            }
        }
        dialog.show()
    }

    private fun runPairingWindow(label: String, mode: UsbMode, adb: Boolean) {
        showBusy(getString(R.string.auth_pair_starting))
        Thread {
            val ok = runCatching { RootAuthManager.start(this, label, mode, adb) }.getOrDefault(false)
            runOnUiThread { render(getString(if (ok) R.string.auth_pair_success else R.string.auth_pair_failed)) }
        }.apply { name = "usb-auth-pair"; start() }
    }

    private fun loadKnownComputers() {
        val progress = ProgressBar(this)
        val target = content
        target.addView(progress)
        Thread {
            val computers = runCatching { RootAuthManager.list(this) }.getOrDefault(emptyList())
            runOnUiThread {
                if (content !== target || isFinishing || isDestroyed) return@runOnUiThread
                content.removeView(progress)
                if (computers.isEmpty()) {
                    content.addView(TextView(this).apply {
                        text = getString(R.string.auth_saved_empty)
                        setTextColor(getColor(R.color.text_secondary))
                    })
                } else computers.sortedByDescending { it.lastSeen }.forEach { computer ->
                    content.addView(LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(dp(12), dp(10), dp(4), dp(10))
                        setBackgroundColor(getColor(R.color.bg_card))
                        addView(TextView(this@UsbAuthenticationActivity).apply {
                            text = getString(
                                R.string.auth_saved_item,
                                computer.label,
                                DateFormat.getDateTimeInstance().format(Date(computer.lastSeen)),
                                computer.id.take(12),
                            )
                            append("\n" + (computer.mode?.let { getString(it.displayRes) } ?: getString(R.string.auth_config_missing)) + if (computer.adb) " + ADB" else "")
                            setTextColor(getColor(R.color.text_body))
                            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(Button(this@UsbAuthenticationActivity).apply {
                            text = getString(R.string.auth_edit)
                            setOnClickListener { editComputer(computer) }
                        })
                        addView(Button(this@UsbAuthenticationActivity).apply {
                            text = getString(R.string.auth_delete)
                            setOnClickListener {
                                AlertDialog.Builder(this@UsbAuthenticationActivity)
                                    .setMessage(getString(R.string.auth_delete_confirm, computer.label))
                                    .setNegativeButton(R.string.dialog_cancel, null)
                                    .setPositiveButton(R.string.auth_delete) { _, _ ->
                                        Thread {
                                            val ok = runCatching { RootAuthManager.delete(this@UsbAuthenticationActivity, computer.id) }.getOrDefault(false)
                                            runOnUiThread { render(if (ok) null else getString(R.string.auth_save_failed)) }
                                        }.start()
                                    }.show()
                            }
                        })
                    }, margins(dp(6)))
                }
            }
        }.apply { name = "usb-auth-hosts"; start() }
    }

    private fun showBusy(text: String) {
        content.removeAllViews()
        content.addView(ProgressBar(this))
        content.addView(status(text))
    }

    private fun status(value: String) = TextView(this).apply {
        text = value
        textSize = 14f
        setTextColor(getColor(R.color.accent))
        setPadding(0, dp(14), 0, dp(8))
    }

    private fun toggle(title: String, checked: Boolean, changed: (Boolean) -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(14), 0, dp(8))
        addView(TextView(this@UsbAuthenticationActivity).apply {
            text = title; textSize = 16f; setTextColor(getColor(R.color.text_primary))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(Switch(this@UsbAuthenticationActivity).apply {
            isChecked = checked
            setOnCheckedChangeListener { _, value -> changed(value) }
        })
    }

    private fun margins(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = dp(8); bottomMargin = bottom
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }
}
