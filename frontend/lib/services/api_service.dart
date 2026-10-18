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

  // ── Auth ────────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> register(String name, String email, String password) async {
    final res = await _dio.post('/api/auth/register', data: {'name': name, 'email': email, 'password': password});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await _dio.post('/api/auth/login', data: {'email': email, 'password': password});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMe() async {
    final res = await _dio.get('/api/auth/me');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteAccount() async {
    final res = await _dio.delete('/api/auth/account');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> changePassword(String currentPassword, String newPassword) async {
    final res = await _dio.put('/api/auth/change-password', data: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
    return res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{'ok': true};
  }

  Future<Map<String, dynamic>> updateProfile(String name) async {
    final res = await _dio.put('/api/auth/profile', data: {'name': name});
    return res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{'ok': true};
  }

  // ── Instagram ───────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> startInstagramOAuth() async {
    final res = await _dio.post('/api/instagram/oauth/start');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getInstagramStatus() async {
    final res = await _dio.get('/api/instagram/status');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getInstagramMedia({int limit = 20, String? cursor}) async {
    final res = await _dio.get('/api/instagram/media',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> disconnectInstagram() async {
    final res = await _dio.delete('/api/instagram/disconnect');
    return res.data as Map<String, dynamic>;
  }

  // ── Comments ─────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getMediaComments(String mediaId, {int limit = 50, String? cursor}) async {
    final res = await _dio.get('/api/instagram/media/$mediaId/comments',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> replyToComment(String commentId, String message) async {
    final res = await _dio.post('/api/instagram/comments/$commentId/reply',
        data: {'message': message});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendDm(String igUserId, String message) async {
    final res = await _dio.post('/api/instagram/users/$igUserId/dm',
        data: {'message': message});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSuggestedReplies(String commentText, {String? username}) async {
    final res = await _dio.post('/api/instagram/comments/suggest-replies',
        data: {'commentText': commentText, if (username != null) 'username': username});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMediaStats(String mediaId) async {
    final res = await _dio.get('/api/instagram/media/$mediaId/stats');
    return res.data as Map<String, dynamic>;
  }

  // ── Automations ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getAutomations() async {
    final res = await _dio.get('/api/automations');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createAutomation(Map<String, dynamic> data) async {
    final res = await _dio.post('/api/automations', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAutomation(String id) async {
    final res = await _dio.get('/api/automations/$id');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateAutomation(String id, Map<String, dynamic> data) async {
    final res = await _dio.put('/api/automations/$id', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> patchAutomationStatus(String id, String status) async {
    final res = await _dio.patch('/api/automations/$id/status', data: {'status': status});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteAutomation(String id) async {
    final res = await _dio.delete('/api/automations/$id');
    return res.data as Map<String, dynamic>;
  }

  // ── Activity / Analytics ────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getActivity({int page = 1, int limit = 50}) async {
    final res = await _dio.get('/api/activity', queryParameters: {'page': page, 'limit': limit});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAnalyticsSummary() async {
    final res = await _dio.get('/api/analytics/summary');
    return res.data as Map<String, dynamic>;
  }
}
