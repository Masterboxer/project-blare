package com.masterboxer.project_blare

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.pravera.flutter_foreground_task.service.ForegroundService

class PowerReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {

        if (intent.action == Intent.ACTION_POWER_CONNECTED) {

            val serviceIntent = Intent(
                context,
                ForegroundService::class.java
            )

            serviceIntent.putExtra(
                "data",
                "STOP_ALARM"
            )

            context.startService(serviceIntent)
        }
    }
}