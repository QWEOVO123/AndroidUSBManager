package com.tiger.usbmanager

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.UserManager
import com.tiger.usbmanager.bridge.BackendBridge

class UsbManagerApp : Application() {
    private val unlockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != Intent.ACTION_USER_UNLOCKED) return
            finishDeviceStorageSetup(createDeviceProtectedStorageContext())
            runCatching { unregisterReceiver(this) }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val deviceContext = createDeviceProtectedStorageContext()
        val unlocked = getSystemService(UserManager::class.java)?.isUserUnlocked == true
        if (unlocked) {
            migrateLegacyPreferences(deviceContext)
        } else {
            val filter = IntentFilter(Intent.ACTION_USER_UNLOCKED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(unlockReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(unlockReceiver, filter)
            }
        }
        ModuleSettings.init(deviceContext)
        // Fire-and-forget: creates the bridge directory and synchronizes settings
        // only after FBE unlock. Before unlock the root service keeps its durable
        // settings and the chooser can still submit a one-time selection.
        if (unlocked) BackendBridge.syncSettings(deviceContext)
    }

    private fun finishDeviceStorageSetup(deviceContext: Context) {
        migrateLegacyPreferences(deviceContext)
        Thread { BackendBridge.syncSettings(deviceContext) }.apply {
            name = "usbmanager-unlock-sync"
            start()
        }
    }

    private fun migrateLegacyPreferences(deviceContext: Context) {
        val source = getSharedPreferences(ModuleConstants.PREFS_SETTINGS, Context.MODE_PRIVATE)
        val target = deviceContext.getSharedPreferences(ModuleConstants.PREFS_SETTINGS, Context.MODE_PRIVATE)
        if (target.getBoolean("_device_storage_migrated", false)) return
        val edit = target.edit()
        source.all.forEach { (key, value) ->
            when (value) {
                is Boolean -> edit.putBoolean(key, value)
                is Int -> edit.putInt(key, value)
                is Long -> edit.putLong(key, value)
                is Float -> edit.putFloat(key, value)
                is String -> edit.putString(key, value)
                is Set<*> -> @Suppress("UNCHECKED_CAST") edit.putStringSet(key, value as Set<String>)
            }
        }
        edit.putBoolean("_device_storage_migrated", true).commit()
        if (source.all.isNotEmpty()) source.edit().clear().commit()
    }
}
