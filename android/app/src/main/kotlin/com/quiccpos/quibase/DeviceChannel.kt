package com.quiccpos.quibase

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// "quibase/device": what the setup wizard's tablet checks read (notifications,
// full-screen alerts, battery optimisation, installs, alarm volume, network)
// and the Android settings page that fixes each one. Bound to the Activity
// (permission requests and settings screens need one).
object DeviceChannel {
    private const val REQ_NOTIFICATIONS = 41

    fun attach(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "quibase/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "checks" -> result.success(checks(activity))
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
                    }
                    result.success(null)
                }
                "openSettings" -> result.success(openSettings(activity, call.argument<String>("kind") ?: ""))
                else -> result.notImplemented()
            }
        }
    }

    fun detach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "quibase/device").setMethodCallHandler(null)
    }

    private fun checks(a: Activity): Map<String, Any?> {
        val nm = a.getSystemService(NotificationManager::class.java)
        val pm = a.getSystemService(PowerManager::class.java)
        val audio = a.getSystemService(AudioManager::class.java)
        val cm = a.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "notifications" to NotificationManagerCompat.from(a).areNotificationsEnabled(),
            "fullScreen" to (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()),
            "battery" to pm.isIgnoringBatteryOptimizations(a.packageName),
            "installs" to (Build.VERSION.SDK_INT < 26 || a.packageManager.canRequestPackageInstalls()),
            "alarmVolume" to audio.getStreamVolume(AudioManager.STREAM_ALARM),
            "alarmMax" to audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
            "wifi" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
            "ethernet" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true),
            "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
        )
    }

    // Opens the settings page for one check; falls back to the app's own
    // details page when a device doesn't have the specific screen.
    private fun openSettings(a: Activity, kind: String): Boolean {
        val pkg = Uri.parse("package:${a.packageName}")
        val intent = when (kind) {
            "notifications" -> if (Build.VERSION.SDK_INT >= 26) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, a.packageName)
            } else null
            "fullScreen" -> if (Build.VERSION.SDK_INT >= 34) Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkg) else null
            "battery" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg)
            "installs" -> if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, pkg) else null
            "sound" -> Intent(Settings.ACTION_SOUND_SETTINGS)
            "wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
            else -> null
        }
        for (i in listOfNotNull(intent, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))) {
            try {
                a.startActivity(i)
                return true
            } catch (_: Exception) {
                // try the fallback
            }
        }
        return false
    }
}
