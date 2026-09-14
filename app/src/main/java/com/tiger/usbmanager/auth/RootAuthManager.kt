package com.tiger.usbmanager.auth

import android.content.Context
import android.util.Base64
import java.io.File
import java.nio.charset.StandardCharsets

data class KnownComputer(val id: String, val label: String, val lastSeen: Long)

/** The only app-process entry point that requests root for USB Authenticate. */
object RootAuthManager {
    enum class DetectionFailure { ROOT_REQUIRED, UNSUPPORTED }

    data class Paths(val script: String, val apk: String, val nativeLibrary: String)
    data class Detection(
        val supported: Boolean,
        val backend: String = RecognitionSettings.BACKEND_NONE,
        val detail: String = "",
        val failure: DetectionFailure? = null,
    )

    fun prepare(context: Context): Paths {
        val directory = File(context.filesDir, "usb-auth").apply { mkdirs() }
        val script = File(directory, "usb_auth_root.sh")
        context.assets.open("usb_auth_root.sh").use { input ->
            script.outputStream().use { output -> input.copyTo(output) }
        }
        script.setReadable(true, true)
        val native = File(context.applicationInfo.nativeLibraryDir, "libusbmanager_auth.so")
        check(native.isFile) { "USB Authenticate native library is unavailable for this CPU" }
        return Paths(script.absolutePath, context.applicationInfo.sourceDir, native.absolutePath)
    }

    fun detect(context: Context): Detection {
        if (!isRootAuthorized()) {
            return Detection(false, detail = "Root access was not granted", failure = DetectionFailure.ROOT_REQUIRED)
        }
        val paths = prepare(context)
        val result = runRoot(paths, "detect", "closed", RecognitionSettings.BACKEND_NONE, 45_000)
        val backend = result.output.lineSequence().firstOrNull { it.startsWith("BACKEND=") }?.substringAfter('=')
        // ReSukiSU's global root shell may report a non-zero wrapper exit code
        // after the inner probe has completed successfully. BACKEND is emitted
        // only by our root-owned script after all capability checks pass.
        if (backend in setOf(RecognitionSettings.BACKEND_GENERIC, RecognitionSettings.BACKEND_NOTHING)) {
            RecognitionSettings.saveDetectedBackend(context, backend!!)
            return Detection(true, backend, result.output)
        }
        return Detection(
            false,
            detail = result.output.ifBlank { "USB gadget capability unavailable" },
            failure = DetectionFailure.UNSUPPORTED,
        )
    }

    fun start(context: Context, allowPair: Boolean): Boolean {
        if (!RecognitionSettings.isEnabled(context)) return false
        RecognitionSettings.markTransition(context)
        val paths = prepare(context)
        val result = runRoot(
            paths,
            "start",
            if (allowPair) "pair" else "closed",
            RecognitionSettings.backend(context),
            60_000,
        )
        val started = result.output.lineSequence().any { it.trim() == "STARTED" }
        if (!started) RecognitionSettings.clearTransition(context)
        return started
    }

    fun restore(context: Context): Boolean {
        RecognitionSettings.markTransition(context, 20_000L)
        val paths = prepare(context)
        val result = runRoot(paths, "restore", "closed", RecognitionSettings.backend(context), 20_000)
        return result.code == 0 || result.output.lineSequence().any { it.startsWith("FRAMEWORK_RESTORE ") }
    }

    fun list(context: Context): List<KnownComputer> {
        val paths = prepare(context)
        val result = runRoot(paths, "list", "closed", RecognitionSettings.backend(context), 10_000)
        return result.output.lineSequence().mapNotNull { line ->
            val fields = line.trim().split('|')
            if (fields.size != 3 || !fields[0].matches(Regex("[0-9a-f]{64}"))) return@mapNotNull null
            runCatching {
                KnownComputer(
                    fields[0],
                    String(Base64.decode(fields[1], Base64.DEFAULT), StandardCharsets.UTF_8),
                    fields[2].toLong(),
                )
            }.getOrNull()
        }.toList()
    }

    fun delete(context: Context, id: String): Boolean {
        require(id.matches(Regex("[0-9a-f]{64}")))
        val paths = prepare(context)
        val result = runRoot(paths, "delete", id, RecognitionSettings.backend(context), 10_000)
        return result.output.lineSequence().any { it.trim() == "DELETED" }
    }

    private data class Result(val code: Int, val output: String)

    private fun isRootAuthorized(): Boolean {
        val process = runCatching { Runtime.getRuntime().exec(arrayOf("su", "-c", "id -u")) }.getOrNull() ?: return false
        return try {
            if (!process.waitFor(15, java.util.concurrent.TimeUnit.SECONDS)) {
                process.destroy()
                process.waitFor(500, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (process.isAlive) process.destroyForcibly()
                false
            } else {
                process.inputStream.bufferedReader().use { reader ->
                    reader.readLines().any { it.trim() == "0" }
                }
            }
        } catch (_: Exception) {
            false
        } finally {
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
            runCatching { process.outputStream.close() }
        }
    }

    private fun runRoot(paths: Paths, action: String, mode: String, backend: String, timeoutMs: Long): Result {
        val command = "sh ${paths.script} $action ${paths.apk} ${paths.nativeLibrary} $mode $backend"
        val process = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        val output = StringBuilder()
        fun drain(stream: java.io.InputStream) = Thread {
            runCatching {
                stream.bufferedReader().useLines { lines ->
                    lines.forEach { line -> synchronized(output) { output.appendLine(line) } }
                }
            }
        }
        val outThread = drain(process.inputStream)
        val errorThread = drain(process.errorStream)
        outThread.start(); errorThread.start()
        val finished = process.waitFor(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        if (!finished) {
            process.destroy()
            process.waitFor(500, java.util.concurrent.TimeUnit.MILLISECONDS)
            if (process.isAlive) process.destroyForcibly()
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
            outThread.join(1_000); errorThread.join(1_000)
            return Result(124, synchronized(output) { output.appendLine("timeout").toString() })
        }
        outThread.join(1_000); errorThread.join(1_000)
        return Result(process.exitValue(), synchronized(output) { output.toString() })
    }
}
