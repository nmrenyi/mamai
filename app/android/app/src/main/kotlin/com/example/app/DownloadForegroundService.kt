package com.example.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Minimal foreground service that keeps the process alive while MAM-AI model
 * files are downloading.  All download logic stays in Dart/Flutter; this
 * service only holds a persistent notification so the OS treats the process
 * as user-visible work and does not kill it when the user switches apps or
 * locks the screen.
 *
 * Flutter controls the service via three MethodChannel calls:
 *   startDownloadService  – starts the foreground service
 *   updateDownloadNotification(message, progress, max) – refreshes the notification
 *   stopDownloadService   – removes the notification and stops the service
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "mam_ai_download"

        private const val ACTION_START  = "mam_ai.download.START"
        private const val ACTION_UPDATE = "mam_ai.download.UPDATE"
        private const val ACTION_STOP   = "mam_ai.download.STOP"

        private const val EXTRA_MESSAGE  = "message"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_MAX      = "max"

        fun start(context: Context) {
            val intent = Intent(context, DownloadForegroundService::class.java)
                .setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, message: String, progress: Int, max: Int) {
            // Update the notification directly via NotificationManager —
            // cheaper than routing through startService for frequent updates.
            ensureChannel(context)
            val nm = context.getSystemService(NotificationManager::class.java)
            nm?.notify(NOTIFICATION_ID, buildNotification(context, message, progress, max))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(NotificationManager::class.java)
                if (nm?.getNotificationChannel(CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        CHANNEL_ID,
                        "MAM-AI Downloads",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Shows progress while MAM-AI model files are downloading"
                        setShowBadge(false)
                    }
                    nm?.createNotificationChannel(channel)
                }
            }
        }

        fun buildNotification(
            context: Context,
            message: String,
            progress: Int,
            max: Int,
        ): Notification {
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("MAM-AI")
                .setContentText(message)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)

            if (max > 0 && progress >= 0) {
                builder.setProgress(max, progress, false)
            } else {
                builder.setProgress(0, 0, true) // indeterminate until we know total
            }

            return builder.build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        when (intent?.action) {
            ACTION_START, null -> {
                // null = system restarted the service after a kill (START_STICKY).
                // Re-show the notification so startForeground() is called promptly.
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(this, "Downloading MAM-AI models…", -1, 0),
                )
            }
            ACTION_STOP -> {
                @Suppress("DEPRECATION")
                stopForeground(true)
                stopSelf()
            }
        }
        // START_STICKY: if the OS kills the service, restart it with a null
        // intent so the foreground notification is re-created and the process
        // stays protected while the Flutter download coroutines resume.
        return START_STICKY
    }
}
