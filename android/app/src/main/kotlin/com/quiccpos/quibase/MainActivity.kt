package com.quiccpos.quibase

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Attaches to the process-wide Flutter engine (QuibaseApp) and doesn't
// destroy it when the Activity goes away, so orders keep ringing after the
// app is swiped off screen.
//
// The "quibase/install" channel backs the forced self-update (UpdateGate):
// the installed version, a cache dir to download into, whether this app may
// install packages (+ the settings screen to allow it), and handing a
// downloaded APK to Android's installer. "quibase/device" (DeviceChannel)
// backs the setup wizard's tablet checks.
class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = QuibaseApp.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        handleRing(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleRing(intent)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    // Opened by the full-screen new-order notification: show over the lock
    // screen and turn the screen on until the ring ends.
    private fun handleRing(intent: Intent?) {
        if (intent?.getBooleanExtra(RingService.EXTRA_RING, false) != true) return
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    fun ringEnded() {
        runOnUiThread {
            if (Build.VERSION.SDK_INT >= 27) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DeviceChannel.attach(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quibase/install").setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                    result.success(mapOf("versionCode" to code, "versionName" to (info.versionName ?: "")))
                }
                "updatesDir" -> {
                    val dir = File(cacheDir, "updates").apply { mkdirs() }
                    result.success(dir.absolutePath)
                }
                "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
                    val intent = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // The engine outlives this Activity: drop the handlers that hold it.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DeviceChannel.detach(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quibase/install").setMethodCallHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        @Volatile var resumed = false
        @Volatile var current: MainActivity? = null
    }
}
