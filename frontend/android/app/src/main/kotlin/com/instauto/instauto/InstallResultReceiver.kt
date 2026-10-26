package com.instauto.instauto

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives PackageInstaller session results (non-exported; only reachable via
 * the explicit PendingIntent created by [AppUpdaterBridge]) and forwards them.
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppUpdaterBridge.ACTION_INSTALL_STATUS) return
        AppUpdaterBridge.statusListener?.invoke(intent)
    }
}
