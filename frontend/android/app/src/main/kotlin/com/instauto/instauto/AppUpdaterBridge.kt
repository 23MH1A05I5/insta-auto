package com.instauto.instauto

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.security.MessageDigest

/**
 * Native bridge for the in-app APK updater.
 *
 * Installation uses the platform [PackageInstaller] session API, so Android
 * always shows its own confirmation UI (no silent installs) and reports a real
 * result: cancelled, conflict (different signing key), incompatible, storage…
 * A launched installer is never reported to Dart as a successful install.
 *
 * Only files inside the app-private update directory can be inspected or
 * installed (path-traversal protection).
 */
class AppUpdaterBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.instauto.instauto/app_updater"
        const val ACTION_INSTALL_STATUS = "com.instauto.instauto.APP_UPDATE_INSTALL_STATUS"
        private const val UPDATE_DIR = "app_updates"

        /** Set while a bridge is alive; receives results from [InstallResultReceiver]. */
        @Volatile
        var statusListener: ((Intent) -> Unit)? = null
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    var activity: Activity? = null

    init {
        channel.setMethodCallHandler(this)
        statusListener = { intent -> mainHandler.post { handleInstallStatus(intent) } }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        statusListener = null
        activity = null
    }

    private fun updateDir(): File = File(context.cacheDir, UPDATE_DIR).apply { mkdirs() }

    /** Resolves [path] and guarantees it lives inside the update directory. */
    private fun safeUpdateFile(path: String?): File? {
        if (path.isNullOrBlank()) return null
        val dir = updateDir().canonicalFile
        val file = File(path).canonicalFile
        if (file.parentFile != dir || !file.name.endsWith(".apk") || !file.isFile) return null
        return file
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getInstalledVersion" -> result.success(installedVersion())
                "getUpdateDirectory" -> result.success(updateDir().absolutePath)
                "getFreeSpaceBytes" -> result.success(StatFs(updateDir().absolutePath).availableBytes)
                "canRequestPackageInstalls" -> result.success(canRequestInstalls())
                "openInstallPermissionSettings" -> result.success(openInstallSettings())
                "inspectApk" -> {
                    val file = safeUpdateFile(call.argument<String>("path"))
                        ?: return result.error("invalid_path", "APK path is outside the update directory", null)
                    result.success(inspectApk(file))
                }
                "installApk" -> {
                    val file = safeUpdateFile(call.argument<String>("path"))
                        ?: return result.error("invalid_path", "APK path is outside the update directory", null)
                    installApk(file, result)
                }
                "abandonSessions" -> {
                    abandonOwnSessions()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // ── Version info ────────────────────────────────────────────────────────

    @Suppress("DEPRECATION")
    private fun installedVersion(): Map<String, Any?> {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        return mapOf(
            "packageName" to context.packageName,
            "versionName" to (info.versionName ?: ""),
            "versionCode" to code,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    // ── Unknown-sources permission (per-app on Android 8+) ──────────────────

    private fun canRequestInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.packageManager.canRequestPackageInstalls() else true

    private fun openInstallSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        return try {
            val act = activity
            if (act != null) act.startActivity(intent)
            else context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ── APK inspection (package name, version, signing certificate) ─────────

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo?): Set<String>? {
        if (info == null) return null
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si = info.signingInfo ?: return legacyDigests(info)
            if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
        } else {
            info.signatures
        }
        if (sigs == null || sigs.isEmpty()) return null
        return sigs.map { sha256Hex(it.toByteArray()) }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun legacyDigests(info: PackageInfo): Set<String>? =
        info.signatures?.takeIf { it.isNotEmpty() }?.map { sha256Hex(it.toByteArray()) }?.toSet()

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Suppress("DEPRECATION")
    private fun inspectApk(file: File): Map<String, Any?> {
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        var archive = pm.getPackageArchiveInfo(file.absolutePath, flags)
        if (archive != null && signerDigests(archive) == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Some OEM builds only populate legacy signatures for archives.
            archive = pm.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNATURES) ?: archive
        }
        if (archive == null) {
            return mapOf("valid" to false)
        }
        val installed = pm.getPackageInfo(context.packageName, flags)
        val apkSigners = signerDigests(archive)
        val ownSigners = signerDigests(installed)
        // For a single signer with rotation history, the new APK's current signer
        // (or any cert in its lineage) must match one of ours.
        val signatureMatches: Boolean? =
            if (apkSigners == null || ownSigners == null) null else apkSigners.any { it in ownSigners }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) archive.longVersionCode else archive.versionCode.toLong()
        val minSdk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) archive.applicationInfo?.minSdkVersion else null
        return mapOf(
            "valid" to true,
            "packageName" to archive.packageName,
            "versionName" to (archive.versionName ?: ""),
            "versionCode" to code,
            "minSdk" to minSdk,
            "deviceSdk" to Build.VERSION.SDK_INT,
            "signatureMatches" to signatureMatches,
        )
    }

    // ── Installation via PackageInstaller session ───────────────────────────

    private fun abandonOwnSessions() {
        val installer = context.packageManager.packageInstaller
        for (s in installer.mySessions) {
            try { installer.abandonSession(s.sessionId) } catch (_: Exception) {}
        }
    }

    private fun installApk(file: File, result: MethodChannel.Result) {
        abandonOwnSessions() // never keep stale half-written sessions around
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setInstallReason(PackageManager.INSTALL_REASON_USER)
            }
        }
        var sessionId = -1
        try {
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                FileInputStream(file).use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { out ->
                        input.copyTo(out, 64 * 1024)
                        session.fsync(out)
                    }
                }
                val intent = Intent(context, InstallResultReceiver::class.java)
                    .setAction(ACTION_INSTALL_STATUS)
                    .setPackage(context.packageName)
                var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
                // The system must add EXTRA_STATUS to this explicit intent, so it must be mutable.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) piFlags = piFlags or PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(context, sessionId, intent, piFlags)
                session.commit(pending.intentSender)
            }
            result.success(mapOf("sessionId" to sessionId))
        } catch (e: IOException) {
            if (sessionId != -1) try { installer.abandonSession(sessionId) } catch (_: Exception) {}
            val msg = e.message ?: "I/O error"
            val code = if (msg.contains("ENOSPC", true) || msg.contains("No space", true)) "insufficient_storage" else "io_error"
            result.error(code, msg, null)
        } catch (e: SecurityException) {
            if (sessionId != -1) try { installer.abandonSession(sessionId) } catch (_: Exception) {}
            result.error("permission_denied", e.message, null)
        } catch (e: Exception) {
            if (sessionId != -1) try { installer.abandonSession(sessionId) } catch (_: Exception) {}
            result.error("session_failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun handleInstallStatus(intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val label = when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirm == null) {
                    "failure"
                } else {
                    try {
                        val act = activity
                        if (act != null) act.startActivity(confirm)
                        else context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        "pending_user_action"
                    } catch (_: Exception) {
                        "launch_failed"
                    }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> "success"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "cancelled"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "conflict"
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
            PackageInstaller.STATUS_FAILURE_INVALID -> "invalid"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
            else -> "failure"
        }
        channel.invokeMethod("onInstallStatus", mapOf("status" to label, "message" to message))
    }
}
