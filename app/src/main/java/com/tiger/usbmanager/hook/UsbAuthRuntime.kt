package com.tiger.usbmanager.hook

import com.tiger.usbmanager.policy.UsbMode
import com.tiger.usbmanager.bridge.ModuleSettingsSnapshot
import com.tiger.usbmanager.bridge.HostProviderClient
import java.util.concurrent.TimeUnit

/** Runs the root USB authentication session and reports its authenticated result. */
internal object UsbAuthRuntime {
    sealed interface Outcome {
        data class Known(val id: String, val label: String, val mode: UsbMode?, val adb: Boolean) : Outcome
        data class Unknown(val id: String, val label: String) : Outcome
        data object Timeout : Outcome
        data class Failed(val detail: String) : Outcome
    }

    fun start(env: HookEnv, client: HostProviderClient, settings: ModuleSettingsSnapshot,
              session: Long, completed: (Outcome) -> Unit) {
        if (!settings.authEnabled) {
            completed(Outcome.Failed("Recognition disabled"))
            return
        }
        Thread {
            val outcome = runCatching {
                if (!client.startAuth(session)) return@runCatching Outcome.Failed("App root worker unavailable")
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(85)
                while (System.nanoTime() < deadline) {
                    val answer = client.authResult(session)
                    if (answer != null) return@runCatching when (answer.status) {
                        "KNOWN", "PAIRED" -> Outcome.Known(answer.id, answer.label, answer.mode, answer.adb)
                        "UNKNOWN" -> Outcome.Unknown(answer.id, answer.label)
                        "TIMEOUT" -> Outcome.Timeout
                        else -> Outcome.Failed(answer.detail)
                    }
                    Thread.sleep(500)
                }
                Outcome.Timeout
            }.getOrElse { Outcome.Failed(it.message.orEmpty()) }
            env.info("[AUTH] closed session outcome=$outcome")
            completed(outcome)
        }.apply { name = "usb-auth-start"; isDaemon = true; start() }
    }

    fun cancel(env: HookEnv, client: HostProviderClient, session: Long) {
        if (session == 0L) return
        Thread {
            runCatching { client.cancelAuth(session) }
                .onFailure { env.warn("[AUTH] cancel session failed", it) }
        }.apply { name = "usb-auth-provider-cancel"; isDaemon = true; start() }
    }
}
