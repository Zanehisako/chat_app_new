package com.example.chat_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.app.NotificationChannel
import android.app.NotificationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    "chat_messages",
                    "Chat messages",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "New direct messages and call updates."
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    "chat_calls",
                    "Group calls",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Invitations to join an active group call."
                },
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "openNotificationSettings") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    }
                } else {
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    )
                }
                try {
                    startActivity(intent)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("settings_unavailable", error.message, null)
                }
            }
    }

    companion object {
        private const val SETTINGS_CHANNEL = "chat_app/settings"
    }
}
