package com.quiccpos.quibase

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

// Keeps Quibase's process (and so the cached Flutter engine with its SSE
// connection to the Pi) alive while the app is in the background or the
// screen is off, behind a quiet "Listening for new orders" notification.
// New orders that nobody sees in the app are announced with a full-screen
// alarm notification: over the lock screen it opens Quibase and turns the
// screen on; over another app it shows as a heads-up, like an incoming call.
// The chime itself is played by the Dart side on the alarm stream, so the
// alarm channel has no sound of its own.
class RingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        lastText = text
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        try {
            ServiceCompat.startForeground(this, ID_SERVICE, connectionNotification(this, text), type)
        } catch (e: Exception) {
            // Android refused (e.g. started from the background): no crash,
            // the app starts it again the next time it is opened.
            Log.w(TAG, "startForeground refused: $e")
            stopSelf()
        }
        return START_STICKY
    }

    companion object {
        private const val TAG = "QuibaseRing"
        private const val CH_CONNECTION = "quibase_connection"
        private const val CH_ORDERS = "quibase_new_orders"
        private const val ID_SERVICE = 1
        private const val ID_RING = 2
        private const val EXTRA_TEXT = "text"
        const val EXTRA_RING = "quibase_ring"

        @Volatile private var lastText = "Listening for new orders"

        fun start(ctx: Context, text: String?): Boolean {
            ensureChannels(ctx)
            if (text != null) lastText = text
            return try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, RingService::class.java).putExtra(EXTRA_TEXT, lastText))
                true
            } catch (e: Exception) {
                Log.w(TAG, "start refused: $e")
                false
            }
        }

        fun update(ctx: Context, text: String) {
            lastText = text
            ensureChannels(ctx)
            try {
                ctx.getSystemService(NotificationManager::class.java).notify(ID_SERVICE, connectionNotification(ctx, text))
            } catch (e: SecurityException) {
                Log.w(TAG, "update: $e")
            }
        }

        fun stop(ctx: Context) {
            cancelRing(ctx)
            ctx.stopService(Intent(ctx, RingService::class.java))
        }

        fun showRing(ctx: Context, title: String, text: String): Boolean {
            ensureChannels(ctx)
            val open = PendingIntent.getActivity(
                ctx, 1,
                Intent(ctx, MainActivity::class.java)
                    .putExtra(EXTRA_RING, true)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(ctx, CH_ORDERS)
                .setSmallIcon(R.drawable.ic_stat_quibase)
                .setContentTitle(title)
                .setContentText(text)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setContentIntent(open)
                .setFullScreenIntent(open, true)
                .build()
            return try {
                ctx.getSystemService(NotificationManager::class.java).notify(ID_RING, n)
                true
            } catch (e: SecurityException) {
                Log.w(TAG, "showRing: $e") // notifications not allowed
                false
            }
        }

        fun cancelRing(ctx: Context) {
            ctx.getSystemService(NotificationManager::class.java).cancel(ID_RING)
        }

        private fun connectionNotification(ctx: Context, text: String): Notification {
            ensureChannels(ctx)
            val open = PendingIntent.getActivity(
                ctx, 0,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(ctx, CH_CONNECTION)
                .setSmallIcon(R.drawable.ic_stat_quibase)
                .setContentTitle("Quibase")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setContentIntent(open)
                .build()
        }

        private fun ensureChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CH_CONNECTION) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CH_CONNECTION, "Connection to the Pi", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shown while Quibase listens for new orders"
                        setShowBadge(false)
                    },
                )
            }
            if (nm.getNotificationChannel(CH_ORDERS) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CH_ORDERS, "New orders", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "Wakes the screen when a new order arrives"
                        setSound(null, null) // Quibase plays the chime itself
                        enableVibration(true)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    },
                )
            }
        }
    }
}
