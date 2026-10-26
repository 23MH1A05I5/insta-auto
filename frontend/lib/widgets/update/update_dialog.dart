// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — Modern In-App Update Dialog
//
// Features:
// • Polished glassmorphism / gradient header matching InstaAuto design language
// • Version badge, release notes scroll area, and download progress indicator
// • Clean state transitions: Idle -> Downloading -> Verifying -> Ready to Install -> Installing
// • Error banner with retry option and cancellation handling
// • Mandatory vs Optional update control with clear system confirmation notice
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../services/app_updater.dart';

class UpdateDialog extends StatelessWidget {
  final AppUpdaterService updater;

  const UpdateDialog({
    super.key,
    required this.updater,
  });

  /// Displays the update dialog if an update is available and not already shown.
  static Future<void> show(BuildContext context, AppUpdaterService updater) {
    return showDialog<void>(
      context: context,
      barrierDismissible: !(updater.latestRelease?.mandatory ?? false),
      builder: (ctx) => ListenableBuilder(
        listenable: updater,
        builder: (ctx, _) => UpdateDialog(updater: updater),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final release = updater.latestRelease;
    final installed = updater.installedApp;
    final isMandatory = release?.mandatory ?? false;
    final status = updater.status;

    return PopScope(
      canPop: !isMandatory && status != UpdateStatus.downloading,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: AppColors.surface,
        elevation: 16,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header Icon & Title ──────────────────────────────────────
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.system_update_alt_rounded,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                Center(
                  child: Text(
                    isMandatory ? 'Mandatory Update' : 'New Update Available',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                // ── Version Information Badge ───────────────────────────────
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'v${installed?.versionName ?? "1.0.0"} → v${release?.version ?? "Latest"}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Error Banner ─────────────────────────────────────────────
                if (updater.errorMessage != null && updater.errorMessage!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, color: AppColors.error, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            updater.errorMessage!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.error,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // ── Release Notes Card ───────────────────────────────────────
                if (release != null && release.releaseNotes.isNotEmpty) ...[
                  const Text(
                    "What's New:",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 140),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.panelGray,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        release.releaseNotes,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // ── Progress & State View ────────────────────────────────────
                if (status == UpdateStatus.downloading) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Downloading APK...',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${(updater.progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: updater.progress > 0 ? updater.progress : null,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (updater.totalBytes > 0)
                    Text(
                      '${(updater.receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB of ${(updater.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: const TextStyle(fontSize: 11, color: AppColors.textHint),
                      textAlign: TextAlign.end,
                    ),
                  const SizedBox(height: 16),
                ] else if (status == UpdateStatus.verifying) ...[
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Verifying SHA-256 package checksum...',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else if (status == UpdateStatus.readyToInstall || status == UpdateStatus.installing) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.verified, color: AppColors.success, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Package verified & ready. Android system installer will now launch.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppColors.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── Android Security Note ────────────────────────────────────
                const Text(
                  'Note: Android will display an installation confirmation prompt. Your settings and data are preserved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.textHint, height: 1.3),
                ),
                const SizedBox(height: 20),

                // ── Action Buttons ───────────────────────────────────────────
                _buildActionButtons(context, status, isMandatory),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, UpdateStatus status, bool isMandatory) {
    if (status == UpdateStatus.downloading) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.close, size: 18),
        label: const Text('Cancel Download'),
        onPressed: () => updater.cancelDownload(),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.error,
          side: const BorderSide(color: AppColors.error),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      );
    }

    if (status == UpdateStatus.verifying) {
      return const SizedBox.shrink();
    }

    if (status == UpdateStatus.readyToInstall) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.install_mobile_rounded, color: Colors.white, size: 20),
        label: const Text('Install Now', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        onPressed: () => updater.installDownloadedApk(),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.success,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      );
    }

    if (status == UpdateStatus.error || status == UpdateStatus.cancelled) {
      return Row(
        children: [
          if (!isMandatory)
            Expanded(
              child: TextButton(
                onPressed: () {
                  updater.resetError();
                  Navigator.of(context).pop();
                },
                child: const Text('Dismiss', style: TextStyle(color: AppColors.textSecondary)),
              ),
            ),
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
              label: const Text('Retry', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              onPressed: () {
                updater.resetError();
                updater.startDownload();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      );
    }

    // Default: updateAvailable state
    return Row(
      children: [
        if (!isMandatory) ...[
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Later',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          flex: isMandatory ? 1 : 2,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.download_rounded, color: Colors.white, size: 20),
            label: const Text(
              'Update Now',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            onPressed: () => updater.startDownload(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
}
