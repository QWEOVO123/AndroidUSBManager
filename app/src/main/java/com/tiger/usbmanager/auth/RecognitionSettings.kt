package com.tiger.usbmanager.auth

import android.content.Context
import com.tiger.usbmanager.ModuleConstants
import com.tiger.usbmanager.bridge.BackendBridge

object RecognitionSettings {
    const val BACKEND_NONE = "none"
    const val BACKEND_GENERIC = "generic_configfs"
    const val BACKEND_NOTHING = "nothing_qxr"

    private const val KEY_BACKEND = "auth_backend"
    private const val KEY_ENABLED = "auth_enabled"
    private const val KEY_TRANSITION_UNTIL = "auth_transition_until"
    private const val KEY_LAST_MODE = "auth_last_chooser_mode"
    private const val KEY_LAST_ADB = "auth_last_chooser_adb"

    data class UsbChoice(val mode: com.tiger.usbmanager.policy.UsbMode, val adb: Boolean)

    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext().getSharedPreferences(
        ModuleConstants.PREFS_SETTINGS,
        Context.MODE_PRIVATE,
    )

    fun backend(context: Context): String = prefs(context).getString(KEY_BACKEND, BACKEND_NONE) ?: BACKEND_NONE
    fun isSupported(context: Context): Boolean = backend(context) != BACKEND_NONE
    fun isEnabled(context: Context): Boolean = isSupported(context) && prefs(context).getBoolean(KEY_ENABLED, false)
    fun transitionUntil(context: Context): Long = prefs(context).getLong(KEY_TRANSITION_UNTIL, 0L)

    fun markTransition(context: Context, durationMs: Long = 45_000L) {
        // Kept synchronous for callers that need a durable transition marker.
        prefs(context).edit().putLong(KEY_TRANSITION_UNTIL, System.currentTimeMillis() + durationMs).commit()
    }

    fun clearTransition(context: Context) {
        prefs(context).edit().remove(KEY_TRANSITION_UNTIL).apply()
    }

    fun recordChooserSelection(context: Context, mode: com.tiger.usbmanager.policy.UsbMode, adb: Boolean) {
        prefs(context).edit()
            .putString(KEY_LAST_MODE, mode.wireValue)
            .putBoolean(KEY_LAST_ADB, adb)
            .apply()
    }

    /** Seeds a new computer profile with the most recently applied chooser choice. */
    fun recentChooserSelection(context: Context): UsbChoice? {
        val preferences = prefs(context)
        val mode = com.tiger.usbmanager.policy.UsbMode.entries.firstOrNull {
            it.wireValue == preferences.getString(KEY_LAST_MODE, null)
        } ?: return null
        return UsbChoice(mode, preferences.getBoolean(KEY_LAST_ADB, false))
    }

    fun saveDetectedBackend(context: Context, backend: String) {
        require(backend == BACKEND_GENERIC || backend == BACKEND_NOTHING)
        prefs(context).edit().putString(KEY_BACKEND, backend).putBoolean(KEY_ENABLED, false).apply()
        BackendBridge.syncSettings(context)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled && isSupported(context)).apply()
        BackendBridge.syncSettings(context)
    }
}
