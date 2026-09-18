package com.tiger.usbmanager

import android.content.Context
import com.tiger.usbmanager.bridge.BackendBridge

/** Reads the heartbeat file published by the root module service. */
object ModuleActivationCheck {
    sealed class Status {
        data class Active(val state: String, val backend: String) : Status()
        data class Inactive(val reason: String) : Status()
        data class Unknown(val note: String) : Status()
    }

    fun check(context: Context): Status {
        val status = BackendBridge.readStatus(context)
        if (status.running) return Status.Active(status.state, status.backend)
        return if (status.detail.isNotBlank()) Status.Inactive(status.detail)
        else Status.Unknown(context.getString(R.string.check_unknown_note))
    }
}
