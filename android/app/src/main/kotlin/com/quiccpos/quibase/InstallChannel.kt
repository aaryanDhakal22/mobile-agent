package com.quiccpos.quibase

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// "quibase/install" (1.6.1): Quibase updates itself. Engine-level and bound
// to the application context, like RingChannel, so an install after Close
// batch also runs with the screen off.
//
// installSession commits the APK through a PackageInstaller session that asks
// for no user action (Android 12+). Android honours that only when Quibase
// itself installed the version being replaced, so the first update after the
// switch still needs one tap: the result comes back as pending_user_action
// and confirm() opens Android's screen for it. Results reach Dart as a
// "status" call on this channel ({status, message}); a successful update
// kills the process, and RestartReceiver brings Quibase back.
//
// install is the old path (hand the APK to Android's installer screen), kept
// for when a session can't be opened.
object InstallChannel {
    private const val TAG = "QuibaseUpdate"
    const val ACTION_RESULT = "com.quiccpos.quibase.INSTALL_RESULT"

    @Volatile private var channel: MethodChannel? = null
    @Volatile private var pendingConfirm: Intent? = null
    @Volatile private var lastStatus: Map<String, Any?>? = null

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "quibase/install")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> {
                    val info = app.packageManager.getPackageInfo(app.packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                    result.success(mapOf("versionCode" to code, "versionName" to (info.versionName ?: "")))
                }
                "updatesDir" -> result.success(File(app.cacheDir, "updates").apply { mkdirs() }.absolutePath)
                "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || app.packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "installer" -> result.success(installerOf(app))
                "canInstallSilently" -> result.success(Build.VERSION.SDK_INT >= 31 && installerOf(app) == app.packageName)
                "install" -> {
                    val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("bad_args", "path is required", null)
                    val uri = FileProvider.getUriForFile(app, "${app.packageName}.fileprovider", File(path))
                    app.startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "installSession" -> {
                    val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("bad_args", "path is required", null)
                    try {
                        commit(app, File(path))
                        result.success(null)
                    } catch (e: Exception) {
                        Log.w(TAG, "session install failed to start", e)
                        result.error("session_failed", e.message ?: e.javaClass.simpleName, null)
                    }
                }
                "confirm" -> {
                    val i = pendingConfirm
                    if (i == null) {
                        result.success(false)
                    } else {
                        pendingConfirm = null
                        app.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                }
                "lastStatus" -> result.success(lastStatus)
                else -> result.notImplemented()
            }
        }
    }

    private fun installerOf(context: Context): String? = try {
        if (Build.VERSION.SDK_INT >= 30) {
            context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION") context.packageManager.getInstallerPackageName(context.packageName)
        }
    } catch (e: Exception) {
        null
    }

    private fun commit(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            if (Build.VERSION.SDK_INT >= 34) setRequestUpdateOwnership(true)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("base.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pi = PendingIntent.getBroadcast(
                context,
                id,
                Intent(context, InstallResultReceiver::class.java).setAction(ACTION_RESULT),
                flags,
            )
            pendingConfirm = null
            lastStatus = mapOf("status" to "committed", "message" to "")
            session.commit(pi.intentSender)
        }
        Log.i(TAG, "session $id committed (${apk.length()} bytes)")
    }

    // Called by InstallResultReceiver (main thread).
    fun onResult(status: Int, message: String?, confirm: Intent?) {
        val name = when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> "pending_user_action"
            PackageInstaller.STATUS_SUCCESS -> "success"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "conflict"
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
            PackageInstaller.STATUS_FAILURE_INVALID -> "invalid"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
            else -> "failure"
        }
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) pendingConfirm = confirm
        Log.i(TAG, "install result $name ${message ?: ""}")
        val m = mapOf("status" to name, "message" to (message ?: ""))
        lastStatus = m
        Handler(Looper.getMainLooper()).post { channel?.invokeMethod("status", m) }
    }
}

// Receives the PackageInstaller session's result for InstallChannel.
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != InstallChannel.ACTION_RESULT) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val confirm = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
        InstallChannel.onResult(status, message, confirm)
    }
}
