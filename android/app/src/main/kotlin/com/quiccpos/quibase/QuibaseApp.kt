package com.quiccpos.quibase

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

// Quibase keeps one Flutter engine for the life of the process instead of one
// per Activity. The Dart side (the SSE connection to the Pi, the alarm logic
// and the chime) then keeps running when the screen is off or the app was
// swiped away — RingService holds the process alive — and MainActivity just
// attaches to it. The engine-level "quibase/ring" channel (RingChannel) works
// with no Activity at all.
class QuibaseApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this) // registers the plugins
        RingChannel.attach(this, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}
