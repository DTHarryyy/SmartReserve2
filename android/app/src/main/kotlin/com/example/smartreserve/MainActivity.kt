package com.example.SmartReserve

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createAlertsChannel()
    }

    // Pushes name this channel (send-push contract.ts). IMPORTANCE_HIGH makes
    // them heads-up alerts; the FCM fallback channel only posts silently.
    private fun createAlertsChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            ALERTS_CHANNEL_ID,
            "Reservation alerts",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Reservation decisions, payments, and reminders"
        }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private companion object {
        const val ALERTS_CHANNEL_ID = "smartreserve_alerts"
    }
}
