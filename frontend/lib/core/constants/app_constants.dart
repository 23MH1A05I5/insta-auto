import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;

/// Central place for all app-wide constants.
/// Never put real secrets here — use .env on the backend.
class AppConstants {
  // ── API ─────────────────────────────────────────────────────────────────────
  /// Production online backend URL (via ngrok tunnel or deployed cloud host)
  static const String remoteUrl = 'https://hunting-imprudent-limb.ngrok-free.dev';

  /// Dynamically resolved base URL based on platform.
  static String get baseUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        return Uri.base.origin;
      }
      return 'http://localhost:3000';
    }
    try {
      if (Platform.isAndroid || Platform.isIOS) return remoteUrl;
    } catch (_) {}
    return remoteUrl;
  }

  static const Duration connectTimeout  = Duration(seconds: 15);
  static const Duration receiveTimeout  = Duration(seconds: 30);

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
