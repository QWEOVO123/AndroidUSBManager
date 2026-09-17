package com.tiger.usbmanager.bridge

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log
import com.tiger.usbmanager.ModuleConstants
import com.tiger.usbmanager.ModuleSettings
import com.tiger.usbmanager.auth.RecognitionSettings
import com.tiger.usbmanager.auth.RootAuthManager
import com.tiger.usbmanager.auth.AuthResult
import java.util.concurrent.Executors

/**
 * ContentProvider in the module app process, queried by system_server via
 * [ContentResolver.call]. It serves settings, the pending-apply mailbox, and runs
 * root authentication in the app mount namespace on behalf of system_server.
 */
class HostProvider : ContentProvider() {
    private val authLock = Any()
    private val authWorker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "usb-auth-app-worker").apply { isDaemon = true }
    }
    private var authSession = 0L
    private var authResult: AuthResult? = null

    /** In-memory pending apply (written by chooser UI, polled by system_server watcher).
     *  Volatile so binder thread reads are visible; single slot because there is at
     *  most one chooser live at a time. */
    @Volatile private var pendingApplyJson: String? = null

    override fun onCreate(): Boolean {
        val ctx = context ?: return false
        ModuleSettings.init(ctx)
        return true
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        return runCatching {
            // ----- UID authorization (authoritative gate, applies to ALL methods). -----
            val callingUid = android.os.Binder.getCallingUid()
            if (callingUid != android.os.Process.SYSTEM_UID &&
                callingUid != android.os.Process.myUid()
            ) {
                Log.w(TAG, "call($method) blocked: uid=$callingUid not authorized")
                return@runCatching null
            }

            // Mutating operations additionally require the shared BRIDGE_TOKEN.
            when (method) {
                UsbBridgeContract.METHOD_PUT_PENDING_APPLY,
                UsbBridgeContract.METHOD_GET_AND_CLEAR_PENDING_APPLY,
                UsbBridgeContract.METHOD_START_AUTH,
                UsbBridgeContract.METHOD_GET_AUTH_RESULT,
                UsbBridgeContract.METHOD_CANCEL_AUTH,
                -> {
                    val tok = extras?.getString(UsbBridgeContract.KEY_BRIDGE_TOKEN)
                    if (tok != ModuleConstants.BRIDGE_TOKEN) {
                        Log.w(TAG, "call($method) blocked: bridge-token mismatch")
                        return@runCatching null
                    }
                }
            }
            when (method) {
                UsbBridgeContract.METHOD_GET_SETTINGS -> handleGetSettings()
                UsbBridgeContract.METHOD_PUT_PENDING_APPLY -> handlePutPendingApply(extras)
                UsbBridgeContract.METHOD_GET_AND_CLEAR_PENDING_APPLY -> handleGetAndClearPendingApply()
                UsbBridgeContract.METHOD_START_AUTH -> handleStartAuth(extras)
                UsbBridgeContract.METHOD_GET_AUTH_RESULT -> handleGetAuthResult(extras)
                UsbBridgeContract.METHOD_CANCEL_AUTH -> handleCancelAuth(extras)
                else -> null
            }
        }.onFailure {
            Log.w(TAG, "call($method) failed", it)
        }.getOrNull()
    }

    private fun handleStartAuth(extras: Bundle?): Bundle {
        val id = extras?.getLong(UsbBridgeContract.KEY_AUTH_SESSION, 0L) ?: 0L
        val ctx = context
        if (id == 0L || ctx == null || !RecognitionSettings.isEnabled(ctx))
            return Bundle().apply { putBoolean(UsbBridgeContract.KEY_RESULT, false) }
        synchronized(authLock) {
            authSession = id
            authResult = null
        }
        // Provider binder threads return immediately. Root and the USB handshake
        // run in the app's mount namespace, where KernelSU exposes `su`.
        authWorker.execute {
            val result = runCatching { RootAuthManager.recognize(ctx) }
                .getOrElse { AuthResult("FAILED", detail = it.message.orEmpty()) }
            synchronized(authLock) {
                if (authSession == id) authResult = result
            }
            Log.i(TAG, "recognition session=$id outcome=${result.status} host=${result.id.take(12)}")
        }
        return Bundle().apply { putBoolean(UsbBridgeContract.KEY_RESULT, true) }
    }

    private fun handleGetAuthResult(extras: Bundle?): Bundle = synchronized(authLock) {
        val id = extras?.getLong(UsbBridgeContract.KEY_AUTH_SESSION, 0L) ?: 0L
        val result = if (id == authSession) authResult else null
        Bundle().apply {
            putBoolean(UsbBridgeContract.KEY_AUTH_READY, result != null)
            if (result != null) {
                putString(UsbBridgeContract.KEY_AUTH_STATUS, result.status)
                putString(UsbBridgeContract.KEY_AUTH_ID, result.id)
                putString(UsbBridgeContract.KEY_AUTH_LABEL, result.label)
                putString(UsbBridgeContract.KEY_AUTH_MODE, result.mode?.wireValue)
                putBoolean(UsbBridgeContract.KEY_AUTH_ADB, result.adb)
                putString(UsbBridgeContract.KEY_AUTH_DETAIL, result.detail)
            }
        }
    }

    private fun handleCancelAuth(extras: Bundle?): Bundle {
        val id = extras?.getLong(UsbBridgeContract.KEY_AUTH_SESSION, 0L) ?: 0L
        synchronized(authLock) {
            if (id == authSession) { authSession = 0L; authResult = null }
        }
        // A closed root session restores its gadget in its own finally block.
        return Bundle().apply { putBoolean(UsbBridgeContract.KEY_RESULT, true) }
    }

    // ---- Pending-apply fallback channel ----

    private fun handlePutPendingApply(extras: Bundle?): Bundle {
        val json = extras?.getString(UsbBridgeContract.KEY_PENDING_JSON)
            ?: return Bundle().apply { putBoolean(UsbBridgeContract.KEY_RESULT, false) }
        pendingApplyJson = json
        Log.i(TAG, "handlePutPendingApply: jsonLen=${json.length}")
        return Bundle().apply { putBoolean(UsbBridgeContract.KEY_RESULT, true) }
    }

    private fun handleGetAndClearPendingApply(): Bundle {
        val json = pendingApplyJson
        pendingApplyJson = null
        Log.i(TAG, "handleGetAndClearPendingApply: present=${json != null}")
        return Bundle().apply {
            if (json != null) putString(UsbBridgeContract.KEY_RESULT, json)
        }
    }

    private fun handleGetSettings(): Bundle {
        return Bundle().apply {
            putString(UsbBridgeContract.KEY_MODE, ModuleSettings.defaultMode())
            putBoolean(UsbBridgeContract.KEY_ADB, ModuleSettings.defaultAdb())
            putBoolean(
                UsbBridgeContract.KEY_DISCONNECT_AUTO_OFF,
                ModuleSettings.disconnectAutoOffAdb(),
            )
            putBoolean(
                UsbBridgeContract.KEY_CHOOSER_WHILE_LOCKED,
                ModuleSettings.chooserWhileLocked(),
            )
            val authEnabled = RecognitionSettings.isEnabled(requireNotNull(context))
            putBoolean(UsbBridgeContract.KEY_AUTH_ENABLED, authEnabled)
            putString(UsbBridgeContract.KEY_AUTH_BACKEND, RecognitionSettings.backend(requireNotNull(context)))
            putLong(UsbBridgeContract.KEY_AUTH_TRANSITION_UNTIL, RecognitionSettings.transitionUntil(requireNotNull(context)))
        }
    }

    // ---- Standard ContentProvider plumbing (not used; data exposed via call()) ----

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        @Suppress("unused")
        const val TAG = "HostProvider"
    }
}
