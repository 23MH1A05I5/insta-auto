import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/constants/app_constants.dart';

/// Central Dio instance with auth interceptor.
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  late final Dio _dio = Dio(BaseOptions(
    baseUrl        : AppConstants.baseUrl,
    connectTimeout : AppConstants.connectTimeout,
    receiveTimeout : AppConstants.receiveTimeout,
    headers        : {
      'Content-Type': 'application/json',
      'ngrok-skip-browser-warning': 'true',
    },
  ))..interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _storage.read(key: AppConstants.kAuthToken);
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        return handler.next(options);
      },
      onError: (error, handler) {
        debugPrint('⚠️ [API ${error.requestOptions.method}] ${error.requestOptions.path} (${error.response?.statusCode}): ${error.response?.data ?? error.message}');
        return handler.next(error);
      },
    ));

  Dio get dio => _dio;

  static Map<String, dynamic> toMap(dynamic data) {
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return <String, dynamic>{
      'ok': false,
      'error': 'Invalid API response format',
    };
  }

  Map<String, dynamic> _toMap(dynamic data) => toMap(data);

  // ── Auth ────────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> register(String name, String email, String password) async {
    final res = await _dio.post('/api/auth/register', data: {'name': name, 'email': email, 'password': password});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await _dio.post('/api/auth/login', data: {'email': email, 'password': password});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getMe() async {
    final res = await _dio.get('/api/auth/me');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> deleteAccount() async {
    final res = await _dio.delete('/api/auth/account');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> changePassword(String currentPassword, String newPassword) async {
    final res = await _dio.put('/api/auth/change-password', data: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> updateProfile(String name) async {
    final res = await _dio.put('/api/auth/profile', data: {'name': name});
    return _toMap(res.data);
  }

  // ── Instagram ───────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> startInstagramOAuth() async {
    final res = await _dio.post('/api/instagram/oauth/start');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getInstagramStatus() async {
    final res = await _dio.get('/api/instagram/status');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getInstagramMedia({int limit = 20, String? cursor}) async {
    final res = await _dio.get('/api/instagram/media',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> disconnectInstagram() async {
    final res = await _dio.delete('/api/instagram/disconnect');
    return _toMap(res.data);
  }

  // ── Comments ─────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getMediaComments(String mediaId, {int limit = 50, String? cursor}) async {
    final res = await _dio.get('/api/instagram/media/$mediaId/comments',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> replyToComment(String commentId, String message) async {
    final res = await _dio.post('/api/instagram/comments/$commentId/reply',
        data: {'message': message});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> sendDm(String igUserId, String message) async {
    final res = await _dio.post('/api/instagram/users/$igUserId/dm',
        data: {'message': message});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getSuggestedReplies(String commentText, {String? username}) async {
    final res = await _dio.post('/api/instagram/comments/suggest-replies',
        data: {'commentText': commentText, if (username != null) 'username': username});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getMediaStats(String mediaId) async {
    final res = await _dio.get('/api/instagram/media/$mediaId/stats');
    return _toMap(res.data);
  }

  // ── Automations ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getAutomations() async {
    final res = await _dio.get('/api/automations');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> createAutomation(Map<String, dynamic> data) async {
    final res = await _dio.post('/api/automations', data: data);
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getAutomation(String id) async {
    final res = await _dio.get('/api/automations/$id');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> updateAutomation(String id, Map<String, dynamic> data) async {
    final res = await _dio.put('/api/automations/$id', data: data);
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> patchAutomationStatus(String id, String status) async {
    final res = await _dio.patch('/api/automations/$id/status', data: {'status': status});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> deleteAutomation(String id) async {
    final res = await _dio.delete('/api/automations/$id');
    return _toMap(res.data);
  }

  // ── Activity / Analytics ────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getActivity({int page = 1, int limit = 50}) async {
    final res = await _dio.get('/api/activity', queryParameters: {'page': page, 'limit': limit});
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getAnalyticsSummary() async {
    final res = await _dio.get('/api/analytics/summary');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> retryDm(String activityId) async {
    final res = await _dio.post('/api/activity/$activityId/retry-dm');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> resendAllFailed() async {
    final res = await _dio.post('/api/activity/retry-all-failed');
    return _toMap(res.data);
  }

  // ── Backfill Existing Comments ──────────────────────────────────────────────
  Future<Map<String, dynamic>> previewBackfill(String automationId, {String? mediaId}) async {
    final res = await _dio.post(
      '/api/automations/$automationId/backfill/preview',
      data: {if (mediaId != null) 'mediaId': mediaId},
    );
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> startBackfill(
    String automationId, {
    String? mediaId,
    List<String>? selectedCommentIds,
  }) async {
    final res = await _dio.post(
      '/api/automations/$automationId/backfill/start',
      data: {
        if (mediaId != null) 'mediaId': mediaId,
        if (selectedCommentIds != null) 'selectedCommentIds': selectedCommentIds,
      },
    );
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getLatestBackfillJob(String automationId) async {
    final res = await _dio.get('/api/automations/$automationId/backfill/latest');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> getBackfillJob(String jobId) async {
    final res = await _dio.get('/api/automations/backfill/jobs/$jobId');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> retryBackfillJob(String jobId) async {
    final res = await _dio.post('/api/automations/backfill/jobs/$jobId/retry');
    return _toMap(res.data);
  }

  Future<Map<String, dynamic>> resumeBackfillJob(String jobId) async {
    final res = await _dio.post('/api/automations/backfill/jobs/$jobId/resume');
    return _toMap(res.data);
  }
}
