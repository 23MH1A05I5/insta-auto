import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;

/// Central place for all app-wide constants.
/// Never put real secrets here — use .env on the backend.
class AppConstants {
  // ── API ─────────────────────────────────────────────────────────────────────
  /// Production online backend URL (hosted on Render)
  static const String remoteUrl = 'https://insta-auto-my00.onrender.com';

  /// Dynamically resolved base URL based on platform.
  static String get baseUrl {
    const envUrl = String.fromEnvironment('API_BASE_URL');
    if (envUrl.isNotEmpty) {
      if (kReleaseMode && !envUrl.startsWith('https://')) {
        debugPrint('⚠️ Insecure HTTP base URL rejected in release mode. Falling back to secure remoteUrl.');
        return remoteUrl;
      }
      return envUrl;
    }

    if (kReleaseMode) {
      return remoteUrl;
    }

    if (kIsWeb) {
      final host = Uri.base.host;
      if (host == 'localhost' || host == '127.0.0.1') {
        return 'http://localhost:3000';
      }
      if (host.isNotEmpty && !host.contains('onrender.com')) {
        return Uri.base.origin;
      }
      return remoteUrl;
    }
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        return 'http://localhost:3000';
      }
      if (Platform.isAndroid) {
        return 'http://10.0.2.2:3000';
      }
      if (Platform.isIOS) {
        return 'http://localhost:3000';
      }
    } catch (_) {}
    return remoteUrl;
  }

  static const Duration connectTimeout  = Duration(seconds: 60);
  static const Duration receiveTimeout  = Duration(seconds: 60);

  // ── In-app updates ───────────────────────────────────────────────────────────
  /// Trusted APK download hosts baked into the app at build time, e.g.
  /// `flutter build apk --release --dart-define=APK_ALLOWED_HOSTS=downloads.example.com`.
  /// When set, the backend's `allowedHosts` are ignored and ONLY these hosts are
  /// accepted. When empty, the app falls back to the host list the backend sends.
  static List<String> get apkTrustedHosts {
    const raw = String.fromEnvironment('APK_ALLOWED_HOSTS');
    return raw
        .split(',')
        .map((h) => h.trim().toLowerCase())
        .where((h) => h.isNotEmpty)
        .toList(growable: false);
  }

  // ── Storage Keys ─────────────────────────────────────────────────────────────
  static const String kAuthToken  = 'auth_token';
  static const String kUserData   = 'user_data';

  // ── Deep Link Scheme ─────────────────────────────────────────────────────────
  static const String deepLinkScheme = 'instauto';
  static const String oauthCallback  = 'instauto://oauth-callback';

  // ── UI ────────────────────────────────────────────────────────────────────────
  static const double cardRadius      = 16.0;
  static const double inputRadius     = 12.0;
  static const double pageHPad        = 20.0;
  // ── Instagram Platform & Messaging Rules ─────────────────────────────────────
  static const int    maxReplyLength             = 2200; // Meta max comment reply characters
  static const int    maxDMLength                = 640;  // Meta max DM text characters
  static const int    maxButtonTitleLength       = 20;   // Meta max button title characters
  static const int    privateReplyWindowDays     = 7;    // Meta 7-day window for comment private replies
  static const int    recommendedReplyVariations = 3;    // Meta anti-spam recommended template variations
}
