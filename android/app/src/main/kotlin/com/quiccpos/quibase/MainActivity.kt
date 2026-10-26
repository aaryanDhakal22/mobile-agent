package com.quiccpos.quibase

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

// Attaches to the process-wide Flutter engine (QuibaseApp) and doesn't
// destroy it when the Activity goes away, so orders keep ringing after the
// app is swiped off screen.
//
// "quibase/device" (DeviceChannel) backs the setup wizard's tablet checks.
// Self-update ("quibase/install") is engine-level: InstallChannel.
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
    }

    // The engine outlives this Activity: drop the handlers that hold it.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DeviceChannel.detach(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        @Volatile var resumed = false
        @Volatile var current: MainActivity? = null
    }
}
