package com.tiger.usbmanager.bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import com.tiger.usbmanager.ui.MainActivity

/** Explicit root broadcast; manifest requires privileged DUMP permission. */
class KnownComputerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.tiger.usbmanager.KNOWN_COMPUTER") return
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        val channel = NotificationChannel("known_computers", "已保存电脑连接提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "识别到已保存的电脑后静默提醒"
            setSound(null, null); enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        manager.createNotificationChannel(channel)
        val label = runCatching {
            String(Base64.decode(intent.getStringExtra("label").orEmpty(), Base64.NO_WRAP), Charsets.UTF_8)
        }.getOrDefault("").take(64).ifBlank { "已保存的电脑" }
        val pending = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, channel.id)
            .setSmallIcon(com.tiger.usbmanager.R.drawable.ic_connection_notification)
            .setContentTitle("已连接到已知电脑")
            .setContentText("$label · 已应用保存的 USB 配置")
            .setContentIntent(pending).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true).build()
        runCatching { manager.notify(217, notification) }
    }
}
