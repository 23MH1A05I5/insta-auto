package com.instauto.instauto

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var appUpdater: AppUpdaterBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appUpdater = AppUpdaterBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger).also {
            it.activity = this
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appUpdater?.dispose()
        appUpdater = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
