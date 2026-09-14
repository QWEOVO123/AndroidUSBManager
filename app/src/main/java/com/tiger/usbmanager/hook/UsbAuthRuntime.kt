package com.tiger.usbmanager.hook

import android.util.Base64
import com.tiger.usbmanager.bridge.ModuleSettingsSnapshot
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

/** Runs the root USB authentication session and reports its authenticated result. */
internal object UsbAuthRuntime {
    sealed interface Outcome {
        data class Known(val id: String, val label: String) : Outcome
        data class Unknown(val id: String, val label: String) : Outcome
        data object Timeout : Outcome
        data class Failed(val detail: String) : Outcome
    }

    fun start(env: HookEnv, settings: ModuleSettingsSnapshot, completed: (Outcome) -> Unit) {
        if (!settings.authEnabled || !valid(settings)) return
        Thread {
            val outcome = runCatching {
                val command = "sh ${settings.authScript} start ${settings.authApk} ${settings.authLibrary} closed ${settings.authBackend}"
                val process = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
                val output = StringBuilder()
                fun drain(stream: java.io.InputStream) = Thread {
                    runCatching {
                        stream.bufferedReader().useLines { lines ->
                            lines.forEach { line -> synchronized(output) { output.appendLine(line) } }
                        }
                    }
                }
                val stdout = drain(process.inputStream)
                val stderr = drain(process.errorStream)
                stdout.start()
                stderr.start()
                val finished = process.waitFor(50, TimeUnit.SECONDS)
                if (!finished) {
                    process.destroy()
                    process.waitFor(500, TimeUnit.MILLISECONDS)
                    if (process.isAlive) process.destroyForcibly()
                }
                runCatching { process.inputStream.close() }
                runCatching { process.errorStream.close() }
                stdout.join(1_000)
                stderr.join(1_000)
                val text = synchronized(output) { output.toString() }
                parse(text, finished)
            }.getOrElse { Outcome.Failed(it.message.orEmpty()) }
            env.info("[AUTH] closed session outcome=$outcome")
            completed(outcome)
        }.apply { name = "usb-auth-start"; isDaemon = true; start() }
    }

    fun restore(env: HookEnv, settings: ModuleSettingsSnapshot) {
        if (!settings.authEnabled || !valid(settings)) return
        Thread {
            runCatching {
                val command = "sh ${settings.authScript} restore ${settings.authApk} ${settings.authLibrary} closed ${settings.authBackend}"
                val process = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
                val completed = process.waitFor(30, TimeUnit.SECONDS)
                env.info("[AUTH] restore completed=$completed")
                if (!completed) process.destroyForcibly()
            }.onFailure { env.warn("[AUTH] restore failed", it) }
        }.apply { name = "usb-auth-restore"; isDaemon = true; start() }
    }

    private fun parse(output: String, finished: Boolean): Outcome {
        val value = output.lineSequence()
            .firstOrNull { it.startsWith("AUTH_RESULT ") }
            ?.removePrefix("AUTH_RESULT ")
            ?.trim()
            ?: return if (finished) Outcome.Failed(output.takeLast(240)) else Outcome.Timeout
        if (value == "TIMEOUT") return Outcome.Timeout
        val fields = value.split('|')
        if (fields.size != 3) return Outcome.Failed(value)
        val label = runCatching {
            String(Base64.decode(fields[2], Base64.DEFAULT), StandardCharsets.UTF_8)
        }.getOrDefault("")
        return when (fields[0]) {
            "KNOWN", "PAIRED" -> Outcome.Known(fields[1], label)
            "UNKNOWN" -> Outcome.Unknown(fields[1], label)
            else -> Outcome.Failed(value)
        }
    }

    private fun valid(settings: ModuleSettingsSnapshot): Boolean {
        val safe = Regex("^/[A-Za-z0-9_./=@+-]+$")
        return settings.authBackend in setOf("generic_configfs", "nothing_qxr") &&
            safe.matches(settings.authScript) && safe.matches(settings.authApk) && safe.matches(settings.authLibrary)
    }
}
