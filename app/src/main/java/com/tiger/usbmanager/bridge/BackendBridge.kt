package com.tiger.usbmanager.bridge

import android.content.Context
import android.util.Base64
import android.util.Log
import com.tiger.usbmanager.ModuleSettings
import com.tiger.usbmanager.auth.KnownComputer
import com.tiger.usbmanager.auth.RecognitionSettings
import com.tiger.usbmanager.policy.UsbMode
import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom

/** Atomic file IPC between the unprivileged UI and the boot-time root service. */
object BackendBridge {
    private const val TAG = "USBManager"
    private const val VERSION = "v1"
    private val random = SecureRandom()

    data class BackendStatus(
        val running: Boolean,
        val state: String = "UNKNOWN",
        val backend: String = "none",
        val detail: String = "",
        val updatedAt: Long = 0L,
    )
    data class Detection(val supported: Boolean, val backend: String = "none", val detail: String = "")
    data class PairResult(val status: String, val computer: KnownComputer? = null, val detail: String = "")

    fun submitChoice(context: Context, sessionId: String, mode: UsbMode, adb: Boolean): Boolean =
        request(context, "apply", sessionId, mode.wireValue, bit(adb), timeoutMs = 35_000L) == "OK"

    fun submitClose(context: Context, sessionId: String, outcome: String): Boolean =
        send(context, "close", sessionId, sanitizeAtom(outcome)) != null

    fun uninstallAndReboot(context: Context): String =
        request(context, "uninstall", "CONFIRM_UNINSTALL_REBOOT", timeoutMs = 15_000L)
            ?: "ERROR|NO_RESPONSE|模块未在 15 秒内响应，请查看 service.log"

    fun syncSettings(context: Context): Boolean = send(
        context,
        "settings",
        ModuleSettings.defaultMode(),
        bit(ModuleSettings.defaultAdb()),
        bit(ModuleSettings.disconnectAutoOffAdb()),
        bit(ModuleSettings.chooserWhileLocked()),
        bit(RecognitionSettings.isEnabled(context)),
        RecognitionSettings.backend(context),
    ) != null

    fun detect(context: Context, timeoutMs: Long = 60_000L): Detection {
        val response = request(context, "detect", timeoutMs = timeoutMs)
            ?: return Detection(false, detail = "root backend did not respond")
        val fields = response.lineSequence().firstOrNull().orEmpty().split('|')
        return if (fields.size >= 2 && fields[0] == "OK") {
            Detection(true, fields[1], fields.drop(2).joinToString("|"))
        } else Detection(false, detail = fields.drop(1).joinToString("|").ifBlank { response.takeLast(240) })
    }

    fun pair(context: Context, mode: UsbMode, adb: Boolean, timeoutMs: Long = 135_000L): PairResult {
        val response = request(context, "pair", mode.wireValue, bit(adb), timeoutMs = timeoutMs)
            ?: return PairResult("FAILED", detail = "root backend did not respond")
        val fields = response.lineSequence().firstOrNull().orEmpty().split('|')
        if (fields.size >= 7 && fields[0] == "OK" && fields[1] in setOf("PAIRED", "KNOWN")) {
            val computer = parseComputer(fields.drop(2))
            return PairResult(fields[1], computer, if (computer == null) "invalid backend response"
                else if (fields.getOrNull(7) == "APPLY_FAILED") "电脑已配对并保存，但 USB 配置未应用成功。可编辑配置后重试。" else "")
        }
        return PairResult(fields.getOrNull(1) ?: "FAILED", detail = fields.drop(2).joinToString("|").ifBlank { response.takeLast(240) })
    }

    fun listComputers(context: Context, timeoutMs: Long = 15_000L): List<KnownComputer> {
        val response = request(context, "hosts_list", timeoutMs = timeoutMs) ?: return emptyList()
        return response.lineSequence().drop(1).mapNotNull { line ->
            val fields = line.split('|')
            if (fields.firstOrNull() != "HOST") null else parseComputer(fields.drop(1))
        }.toList()
    }

    fun updateComputer(context: Context, computer: KnownComputer, timeoutMs: Long = 45_000L): String {
        val mode = computer.mode ?: return "ERROR|BAD_MODE"
        val response = request(context, "host_edit", computer.id, encode(computer.label), mode.wireValue,
            bit(computer.adb), timeoutMs = timeoutMs) ?: return "ERROR|TIMEOUT"
        return response.lineSequence().firstOrNull().orEmpty()
    }

    fun deleteComputer(context: Context, id: String, timeoutMs: Long = 15_000L): Boolean {
        val response = request(context, "host_delete", id, timeoutMs = timeoutMs) ?: return false
        return response.lineSequence().firstOrNull() == "OK"
    }

    fun readStatus(context: Context): BackendStatus {
        val dir = bridgeDir(context) ?: return BackendStatus(false, detail = "app bridge directory unavailable")
        val file = File(dir, "backend.status")
        if (!file.isFile) return BackendStatus(false, detail = "root module is not running")
        val values = runCatching {
            file.readLines().mapNotNull { line ->
                val split = line.indexOf('=')
                if (split <= 0) null else line.substring(0, split) to line.substring(split + 1)
            }.toMap()
        }.getOrElse { return BackendStatus(false, detail = it.message.orEmpty()) }
        val timestamp = values["timestamp"]?.toLongOrNull() ?: file.lastModified()
        val fresh = System.currentTimeMillis() - timestamp < 15_000L
        return BackendStatus(values["running"] == "1" && fresh, values["state"] ?: "UNKNOWN",
            values["auth_backend"] ?: "none", values["detail"].orEmpty(), timestamp)
    }

    private fun request(context: Context, operation: String, vararg args: String, timeoutMs: Long): String? {
        val requestId = send(context, operation, *args) ?: return null
        val response = File(bridgeDir(context) ?: return null, "response.$requestId")
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (response.isFile) {
                val text = runCatching { response.readText(Charsets.UTF_8) }.getOrNull()
                response.delete()
                if (text != null) return text.trimEnd()
            }
            Thread.sleep(100L)
        }
        return null
    }

    private fun send(context: Context, operation: String, vararg args: String): String? {
        val dir = bridgeDir(context) ?: return null
        val requestId = randomId()
        val payload = (listOf(VERSION, sanitizeAtom(operation), requestId) + args.map(::sanitizeAtom)).joinToString("|")
        val temp = File(dir, "command.$requestId.tmp")
        val target = File(dir, "command.$requestId")
        return runCatching {
            FileOutputStream(temp).use { stream ->
                stream.write(payload.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            check(temp.renameTo(target)) { "atomic command rename failed" }
            requestId
        }.onFailure {
            temp.delete()
            Log.e(TAG, "[BRIDGE] failed to submit $operation", it)
        }.getOrNull()
    }

    /**
     * Device-protected app-private storage is available before the first FBE
     * unlock. The root service addresses the same directory through
     * /data/user_de/<user>/<package>/files/root_bridge.
     */
    private fun bridgeDir(context: Context): File? = runCatching {
        File(context.createDeviceProtectedStorageContext().filesDir, "root_bridge").apply { mkdirs() }
    }.getOrNull()

    private fun parseComputer(fields: List<String>): KnownComputer? {
        if (fields.size < 5 || !fields[0].matches(Regex("[0-9a-f]{64}"))) return null
        return runCatching { KnownComputer(fields[0], decode(fields[1]), fields[2].toLong(),
            UsbMode.entries.firstOrNull { it.wireValue == fields[3] }, fields[4] == "1" || fields[4] == "true") }.getOrNull()
    }

    private fun randomId(): String = ByteArray(16).also(random::nextBytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    private fun bit(value: Boolean) = if (value) "1" else "0"
    private fun sanitizeAtom(value: String): String = value.replace('|', '_').replace('\n', ' ').replace('\r', ' ')
    private fun encode(value: String): String = Base64.encodeToString(value.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
    private fun decode(value: String): String = String(Base64.decode(value, Base64.NO_WRAP), Charsets.UTF_8)
}
