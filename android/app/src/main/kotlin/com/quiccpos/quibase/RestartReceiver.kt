package com.quiccpos.quibase

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log

// Brings Quibase back after a forced self-update (the installer kills the
// process) and after the tablet reboots, so orders ring without anyone
// opening the app. The broadcast itself starts the process: QuibaseApp's
// onCreate runs first and starts the Flutter engine (Dart main → ring bridge
// → SSE to the Pi). This receiver starts RingService straight away because
// Android only allows a background foreground-service start for a short
// while after these broadcasts (specialUse is allowed from BOOT_COMPLETED on
// Android 14/15). On an unpaired tablet the Dart side stops the service again.
//
// No LOCKED_BOOT_COMPLETED: the app isn't direct-boot aware (its pairing
// lives in credential-encrypted storage), so it waits for BOOT_COMPLETED.
class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "restart after ${intent.action}")
                RingService.start(context.applicationContext, "Connecting to the Pi…")
                reopen(context)
            }
        }
    }

    // Brings the screen back too (1.6.1), so a tablet that updated itself
    // after Close batch shows Quibase in the morning, not the home screen.
    // Android only lets an app open a screen from the background when it may
    // "display over other apps" (Updates → Reopen after an update); without
    // it the ring service still runs and orders still ring.
    private fun reopen(context: Context) {
        if (!Settings.canDrawOverlays(context)) return
        try {
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not reopen the screen", e)
        }
    }

    companion object {
        private const val TAG = "QuibaseRing"
    }
}
