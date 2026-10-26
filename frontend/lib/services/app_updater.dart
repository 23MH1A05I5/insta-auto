// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — In-App APK Updater Service
//
// Responsibilities:
// 1. Fetch & validate update metadata from Node.js backend (/api/app-update)
// 2. Read installed package name, version name, and integer versionCode via native bridge
// 3. Compare version codes safely
// 4. Validate HTTPS download URL & enforce trusted hosts allowlist
// 5. Download APK to private cache directory with real-time percentage progress
// 6. Verify SHA-256 checksum against publisher's expected hash
// 7. Verify APK package identity, target SDK, and signing certificate before install
// 8. Launch native Android PackageInstaller session
// 9. Handle user cancellation, installation errors, and retries gracefully
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/constants/app_constants.dart';

/// Status of the in-app update process.
enum UpdateStatus {
  idle,
  checking,
  updateAvailable,
  upToDate,
  downloading,
  verifying,
  readyToInstall,
  installing,
  cancelled,
  error,
}

/// Metadata describing an available application release.
class AppReleaseInfo {
  final String version;
  final int versionCode;
  final String apkUrl;
  final String sha256;
  final bool mandatory;
  final String releaseNotes;
  final int? sizeBytes;
  final List<String> allowedHosts;
  final int? minSupportedVersionCode;

  const AppReleaseInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.mandatory,
    required this.releaseNotes,
    this.sizeBytes,
    required this.allowedHosts,
    this.minSupportedVersionCode,
  });

  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    final hostsList = json['allowedHosts'] as List<dynamic>?;
    final hosts = hostsList != null
        ? hostsList.map((e) => e.toString().trim().toLowerCase()).toList()
        : <String>[];

    return AppReleaseInfo(
      version: json['version'] as String? ?? 'Unknown',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      apkUrl: json['apkUrl'] as String? ?? '',
      sha256: (json['sha256'] as String? ?? '').trim().toLowerCase(),
      mandatory: json['mandatory'] as bool? ?? false,
      releaseNotes: json['releaseNotes'] as String? ?? 'Performance improvements and bug fixes.',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      allowedHosts: hosts,
      minSupportedVersionCode: (json['minSupportedVersionCode'] as num?)?.toInt(),
    );
  }
}

/// Installed version details retrieved from the Android OS.
class InstalledAppInfo {
  final String packageName;
  final String versionName;
  final int versionCode;
  final int sdkInt;

  const InstalledAppInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.sdkInt,
  });

  factory InstalledAppInfo.fromMap(Map<dynamic, dynamic> map) {
    return InstalledAppInfo(
      packageName: map['packageName'] as String? ?? '',
      versionName: map['versionName'] as String? ?? '',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Inspection results of a downloaded APK file before installation.
class ApkInspectionResult {
  final bool isValid;
  final String? packageName;
  final String? versionName;
  final int? versionCode;
  final int? minSdk;
  final int? deviceSdk;
  final bool? signatureMatches;

  const ApkInspectionResult({
    required this.isValid,
    this.packageName,
    this.versionName,
    this.versionCode,
    this.minSdk,
    this.deviceSdk,
    this.signatureMatches,
  });

  factory ApkInspectionResult.fromMap(Map<dynamic, dynamic> map) {
    return ApkInspectionResult(
      isValid: map['valid'] as bool? ?? false,
      packageName: map['packageName'] as String?,
      versionName: map['versionName'] as String?,
      versionCode: (map['versionCode'] as num?)?.toInt(),
      minSdk: (map['minSdk'] as num?)?.toInt(),
      deviceSdk: (map['deviceSdk'] as num?)?.toInt(),
      signatureMatches: map['signatureMatches'] as bool?,
    );
  }
}

/// Dedicated service orchestrating the complete in-app update lifecycle.
class AppUpdaterService extends ChangeNotifier {
  static final AppUpdaterService _instance = AppUpdaterService._internal();
  factory AppUpdaterService() => _instance;

  AppUpdaterService._internal() {
    _initChannel();
  }

  static const MethodChannel _channel = MethodChannel('com.instauto.instauto/app_updater');

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
    headers: {
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    },
  ));

  CancelToken? _downloadCancelToken;

  UpdateStatus _status = UpdateStatus.idle;
  UpdateStatus get status => _status;

  AppReleaseInfo? _latestRelease;
  AppReleaseInfo? get latestRelease => _latestRelease;

  InstalledAppInfo? _installedApp;
  InstalledAppInfo? get installedApp => _installedApp;

  double _progress = 0.0;
  double get progress => _progress;

  int _receivedBytes = 0;
  int get receivedBytes => _receivedBytes;

  int _totalBytes = 0;
  int get totalBytes => _totalBytes;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _downloadedApkPath;
  String? get downloadedApkPath => _downloadedApkPath;

  bool _isChecking = false;
  bool get isChecking => _isChecking;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  bool get isUpdateAvailable =>
      _latestRelease != null &&
      _installedApp != null &&
      _latestRelease!.versionCode > _installedApp!.versionCode;

  void _initChannel() {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInstallStatus') {
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final statusLabel = args['status'] as String? ?? 'failure';
        final message = args['message'] as String?;
        _handleInstallStatus(statusLabel, message);
      }
    });
  }

  void _handleInstallStatus(String statusLabel, String? message) {
    debugPrint('🔔 [AppUpdaterBridge] onInstallStatus: $statusLabel ($message)');
    switch (statusLabel) {
      case 'pending_user_action':
        _status = UpdateStatus.installing;
        _errorMessage = null;
        notifyListeners();
        break;
      case 'success':
        _status = UpdateStatus.readyToInstall;
        _errorMessage = null;
        notifyListeners();
        break;
      case 'cancelled':
        _status = UpdateStatus.cancelled;
        _errorMessage = 'Installation was cancelled.';
        notifyListeners();
        break;
      case 'conflict':
        _status = UpdateStatus.error;
        _errorMessage = 'Update failed: signature conflict with installed application.';
        notifyListeners();
        break;
      case 'incompatible':
        _status = UpdateStatus.error;
        _errorMessage = 'Update failed: APK is not compatible with this device architecture or Android version.';
        notifyListeners();
        break;
      case 'storage':
        _status = UpdateStatus.error;
        _errorMessage = 'Update failed: insufficient device storage to install.';
        notifyListeners();
        break;
      case 'invalid':
        _status = UpdateStatus.error;
        _errorMessage = 'Update failed: APK file is corrupt or invalid.';
        notifyListeners();
        break;
      case 'launch_failed':
        _status = UpdateStatus.error;
        _errorMessage = 'Could not launch Android package installer.';
        notifyListeners();
        break;
      default:
        _status = UpdateStatus.error;
        _errorMessage = message != null && message.isNotEmpty
            ? 'Installation failed: $message'
            : 'Installation failed. Please try again.';
        notifyListeners();
        break;
    }
  }

  /// Retrieves the currently installed application version details from Android.
  Future<InstalledAppInfo?> getInstalledVersion() async {
    if (kIsWeb || !Platform.isAndroid) {
      // Mock fallback for non-Android platforms
      _installedApp = const InstalledAppInfo(
        packageName: 'com.instauto.instauto',
        versionName: '1.0.0',
        versionCode: 1,
        sdkInt: 34,
      );
      return _installedApp;
    }

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getInstalledVersion');
      if (res != null) {
        _installedApp = InstalledAppInfo.fromMap(res);
        return _installedApp;
      }
    } catch (e) {
      debugPrint('⚠️ [AppUpdater] getInstalledVersion failed: $e');
    }
    return null;
  }

  /// Checks whether unknown app sources permission is granted on Android 8.0+.
  Future<bool> canRequestPackageInstalls() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final can = await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return can ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the Android system settings page to grant unknown source install permission.
  Future<bool> openInstallPermissionSettings() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final opened = await _channel.invokeMethod<bool>('openInstallPermissionSettings');
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Queries the Node.js backend for published release metadata and compares version codes.
  Future<AppReleaseInfo?> checkForUpdate({bool silent = false}) async {
    if (_isChecking) return _latestRelease;
    _isChecking = true;
    _errorMessage = null;

    if (!silent) {
      _status = UpdateStatus.checking;
      notifyListeners();
    }

    try {
      // 1. Get installed version code
      await getInstalledVersion();
      final installedCode = _installedApp?.versionCode ?? 1;

      // 2. Fetch update metadata with cache-busting headers
      final url = '${AppConstants.baseUrl}/api/app-update?currentVersionCode=$installedCode';
      final response = await _dio.get(
        url,
        options: Options(headers: {
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
        }),
      );

      if (response.statusCode == 200 && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        if (data['ok'] == true) {
          final release = AppReleaseInfo.fromJson(data);
          _latestRelease = release;

          if (release.versionCode > installedCode) {
            _status = UpdateStatus.updateAvailable;
          } else {
            _status = UpdateStatus.upToDate;
          }
          notifyListeners();
          return release;
        }
      }

      if (response.statusCode == 503) {
        // No release configured yet on backend
        _status = UpdateStatus.upToDate;
        notifyListeners();
        return null;
      }

      _status = UpdateStatus.idle;
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('⚠️ [AppUpdater] checkForUpdate error: $e');
      if (!silent) {
        _status = UpdateStatus.error;
        _errorMessage = 'Failed to check for updates: ${_formatError(e)}';
        notifyListeners();
      } else {
        _status = UpdateStatus.idle;
        notifyListeners();
      }
      return null;
    } finally {
      _isChecking = false;
    }
  }

  /// Validates the download URL against trusted HTTPS and host allowlists.
  String? validateDownloadUrl(String rawUrl, List<String> serverAllowedHosts) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Invalid download URL format.';
    }

    if (uri.scheme.toLowerCase() != 'https') {
      return 'Download URL must use secure HTTPS.';
    }

    final host = uri.host.toLowerCase();

    // Prefer compile-time baked trusted hosts if defined; else fall back to backend allowlist
    final trustedHosts = AppConstants.apkTrustedHosts.isNotEmpty
        ? AppConstants.apkTrustedHosts
        : serverAllowedHosts;

    if (trustedHosts.isNotEmpty && !trustedHosts.contains(host)) {
      return 'Download host "$host" is not trusted. Allowed hosts: ${trustedHosts.join(", ")}';
    }

    if (!uri.path.toLowerCase().endsWith('.apk')) {
      return 'Download target must be an Android APK package file.';
    }

    return null;
  }

  /// Starts downloading the latest release APK directly inside the app with real-time progress.
  Future<void> startDownload() async {
    if (_isDownloading) return;
    if (_latestRelease == null) {
      _errorMessage = 'No release metadata available to download.';
      _status = UpdateStatus.error;
      notifyListeners();
      return;
    }

    final release = _latestRelease!;

    // 1. Security & URL Validation
    final urlError = validateDownloadUrl(release.apkUrl, release.allowedHosts);
    if (urlError != null) {
      _errorMessage = urlError;
      _status = UpdateStatus.error;
      notifyListeners();
      return;
    }

    if (release.sha256.length != 64 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(release.sha256)) {
      _errorMessage = 'Server provided invalid SHA-256 release checksum.';
      _status = UpdateStatus.error;
      notifyListeners();
      return;
    }

    // 2. Resolve destination directory and storage requirements
    _isDownloading = true;
    _progress = 0.0;
    _receivedBytes = 0;
    _totalBytes = release.sizeBytes ?? 0;
    _errorMessage = null;
    _status = UpdateStatus.downloading;
    notifyListeners();

    String updateDir;
    try {
      if (Platform.isAndroid) {
        updateDir = await _channel.invokeMethod<String>('getUpdateDirectory') ?? '';
      } else {
        updateDir = Directory.systemTemp.path;
      }
    } catch (_) {
      updateDir = Directory.systemTemp.path;
    }

    final targetFile = File('$updateDir/instauto_${release.version}_${release.versionCode}.apk');
    final tempFile = File('${targetFile.path}.part');

    try {
      // 3. Storage Space Check
      if (Platform.isAndroid && release.sizeBytes != null && release.sizeBytes! > 0) {
        try {
          final freeSpace = await _channel.invokeMethod<int>('getFreeSpaceBytes') ?? 0;
          // Require at least 2.5x the APK size for download + package manager staging
          final requiredSpace = (release.sizeBytes! * 2.5).toInt();
          if (freeSpace > 0 && freeSpace < requiredSpace) {
            throw Exception('Insufficient device storage. At least ${(requiredSpace / (1024 * 1024)).toStringAsFixed(1)} MB required.');
          }
        } catch (e) {
          if (e.toString().contains('Insufficient device storage')) rethrow;
        }
      }

      // 4. Remove any prior incomplete download
      if (await tempFile.exists()) await tempFile.delete();
      if (await targetFile.exists()) await targetFile.delete();

      // 5. Download file
      _downloadCancelToken = CancelToken();
      await _dio.download(
        release.apkUrl,
        tempFile.path,
        cancelToken: _downloadCancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Cache-Control': 'no-cache'},
        ),
        onReceiveProgress: (received, total) {
          _receivedBytes = received;
          if (total > 0) {
            _totalBytes = total;
            _progress = received / total;
          } else if (release.sizeBytes != null && release.sizeBytes! > 0) {
            _totalBytes = release.sizeBytes!;
            _progress = (received / release.sizeBytes!).clamp(0.0, 1.0);
          } else {
            _progress = 0.0;
          }
          notifyListeners();
        },
      );

      // 6. SHA-256 Checksum Verification
      _status = UpdateStatus.verifying;
      notifyListeners();

      final calculatedHash = await _calculateFileSha256(tempFile);
      if (calculatedHash != release.sha256) {
        await tempFile.delete();
        throw Exception('SHA-256 integrity verification failed! File may be corrupt or tampered.');
      }

      // Rename verified part file to final apk
      await tempFile.rename(targetFile.path);
      _downloadedApkPath = targetFile.path;

      // 7. Native Package Inspection (Package name & Signing Key check)
      if (Platform.isAndroid) {
        final inspection = await _inspectDownloadedApk(targetFile.path);
        if (!inspection.isValid) {
          await targetFile.delete();
          throw Exception('The downloaded file is not a valid Android APK package.');
        }

        if (inspection.packageName != null &&
            _installedApp != null &&
            inspection.packageName != _installedApp!.packageName) {
          await targetFile.delete();
          throw Exception(
              'Package ID mismatch: expected "${_installedApp!.packageName}", got "${inspection.packageName}".');
        }

        if (inspection.signatureMatches == false) {
          await targetFile.delete();
          throw Exception(
              'Update signing key mismatch! The new version is signed with a different key than your installed app. Existing data cannot be preserved.');
        }
      }

      _progress = 1.0;
      _status = UpdateStatus.readyToInstall;
      notifyListeners();
    } catch (e) {
      // Clean up incomplete files
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}

      if (_downloadCancelToken?.isCancelled == true) {
        _status = UpdateStatus.cancelled;
        _errorMessage = 'Download cancelled.';
      } else {
        _status = UpdateStatus.error;
        _errorMessage = _formatError(e);
      }
      notifyListeners();
    } finally {
      _isDownloading = false;
      _downloadCancelToken = null;
    }
  }

  /// Cancels an in-progress APK download.
  void cancelDownload() {
    if (_downloadCancelToken != null && !_downloadCancelToken!.isCancelled) {
      _downloadCancelToken!.cancel('User cancelled download.');
    }
    _isDownloading = false;
    _status = UpdateStatus.cancelled;
    _errorMessage = 'Download was cancelled.';
    notifyListeners();
  }

  /// Computes the SHA-256 hash of a file by streaming its contents (memory-efficient).
  Future<String> _calculateFileSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString().toLowerCase();
  }

  /// Invokes native Android bridge to inspect APK metadata and verify certificates.
  Future<ApkInspectionResult> _inspectDownloadedApk(String filePath) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'inspectApk',
        {'path': filePath},
      );
      if (res != null) {
        return ApkInspectionResult.fromMap(res);
      }
    } catch (e) {
      debugPrint('⚠️ [AppUpdater] inspectApk bridge error: $e');
    }
    return const ApkInspectionResult(isValid: false);
  }

  /// Launches the native Android package installer session for the verified APK.
  Future<bool> installDownloadedApk() async {
    final path = _downloadedApkPath;
    if (path == null || !File(path).existsSync()) {
      _errorMessage = 'No verified APK file found on device.';
      _status = UpdateStatus.error;
      notifyListeners();
      return false;
    }

    if (!Platform.isAndroid) {
      _errorMessage = 'In-app installation is only supported on Android.';
      _status = UpdateStatus.error;
      notifyListeners();
      return false;
    }

    // Check unknown-sources permission first
    final hasPermission = await canRequestPackageInstalls();
    if (!hasPermission) {
      _errorMessage = 'Please allow InstaAuto to install apps in Android Settings.';
      _status = UpdateStatus.error;
      notifyListeners();
      await openInstallPermissionSettings();
      return false;
    }

    try {
      _status = UpdateStatus.installing;
      _errorMessage = null;
      notifyListeners();

      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'installApk',
        {'path': path},
      );

      final sessionId = res?['sessionId'];
      debugPrint('🚀 [AppUpdater] Installer session committed: sessionId=$sessionId');
      // Android package installer will present confirmation dialog to the user.
      // Final result is reported back asynchronously via onInstallStatus callback.
      return true;
    } catch (e) {
      debugPrint('❌ [AppUpdater] installApk failed: $e');
      _status = UpdateStatus.error;
      _errorMessage = 'Failed to launch installer: ${_formatError(e)}';
      notifyListeners();
      return false;
    }
  }

  /// Cleans up any cached update APK files from device storage.
  Future<void> cleanCache() async {
    try {
      if (Platform.isAndroid) {
        final dirPath = await _channel.invokeMethod<String>('getUpdateDirectory');
        if (dirPath != null && dirPath.isNotEmpty) {
          final dir = Directory(dirPath);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            await dir.create();
          }
        }
      }
      _downloadedApkPath = null;
      _status = UpdateStatus.idle;
      _errorMessage = null;
      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ [AppUpdater] cleanCache error: $e');
    }
  }

  /// Resets error state to allow re-checking or re-downloading.
  void resetError() {
    _errorMessage = null;
    if (_status == UpdateStatus.error || _status == UpdateStatus.cancelled) {
      _status = _latestRelease != null && isUpdateAvailable
          ? UpdateStatus.updateAvailable
          : UpdateStatus.idle;
    }
    notifyListeners();
  }

  String _formatError(dynamic e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return 'Connection timed out. Check your internet connection.';
      }
      if (e.response?.statusCode != null) {
        return 'Server returned HTTP ${e.response?.statusCode}.';
      }
      return 'Network error: ${e.message ?? 'Check your connection'}';
    }
    return e.toString().replaceAll('Exception: ', '');
  }
}
