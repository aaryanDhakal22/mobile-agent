package com.quiccpos.quibase

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// "quibase/ring": the Dart ring bridge drives the foreground service and the
// full-screen new-order notification through this. Engine-level and bound to
// the application context, so it works while no Activity is attached.
object RingChannel {
    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "quibase/ring").setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> result.success(RingService.start(app, call.argument<String>("text")))
                "updateService" -> {
                    RingService.update(app, call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "stopService" -> {
                    RingService.stop(app)
                    result.success(null)
                }
                "showRing" -> {
                    // In the foreground the in-app alert already covers the
                    // screen; the notification is only for when it isn't seen.
                    val shown = !MainActivity.resumed &&
                        RingService.showRing(app, call.argument<String>("title") ?: "New order", call.argument<String>("text") ?: "")
                    result.success(shown)
                }
                "cancelRing" -> {
                    RingService.cancelRing(app)
                    MainActivity.current?.ringEnded()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
