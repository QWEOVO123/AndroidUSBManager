package com.tiger.usbmanager.auth

import android.content.Context
import com.tiger.usbmanager.ModuleConstants

object RecognitionSettings {
    const val BACKEND_NONE = "none"
    const val BACKEND_GENERIC = "generic_configfs"
    const val BACKEND_NOTHING = "nothing_qxr"

    private const val KEY_BACKEND = "auth_backend"
    private const val KEY_ENABLED = "auth_enabled"
    private const val KEY_TRANSITION_UNTIL = "auth_transition_until"

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(
        ModuleConstants.PREFS_SETTINGS,
        Context.MODE_PRIVATE,
    )

    fun backend(context: Context): String = prefs(context).getString(KEY_BACKEND, BACKEND_NONE) ?: BACKEND_NONE
    fun isSupported(context: Context): Boolean = backend(context) != BACKEND_NONE
    fun isEnabled(context: Context): Boolean = isSupported(context) && prefs(context).getBoolean(KEY_ENABLED, false)
    fun transitionUntil(context: Context): Long = prefs(context).getLong(KEY_TRANSITION_UNTIL, 0L)

    fun markTransition(context: Context, durationMs: Long = 45_000L) {
        // commit() is intentional: system_server must see this before USB teardown.
        prefs(context).edit().putLong(KEY_TRANSITION_UNTIL, System.currentTimeMillis() + durationMs).commit()
    }

    fun clearTransition(context: Context) {
        prefs(context).edit().remove(KEY_TRANSITION_UNTIL).apply()
    }

    fun saveDetectedBackend(context: Context, backend: String) {
        require(backend == BACKEND_GENERIC || backend == BACKEND_NOTHING)
        prefs(context).edit().putString(KEY_BACKEND, backend).putBoolean(KEY_ENABLED, false).apply()
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled && isSupported(context)).apply()
    }
}
