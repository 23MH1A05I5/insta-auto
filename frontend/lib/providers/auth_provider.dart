import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
import '../models/user_model.dart';
import '../services/api_service.dart';
import '../core/constants/app_constants.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  AuthStatus _status = AuthStatus.unknown;
  AppUser?   _user;
  String?    _error;
  bool       _loading = false;

  AuthStatus get status  => _status;
  AppUser?   get user    => _user;
  String?    get error   => _error;
  bool       get loading => _loading;
  bool       get isLoggedIn => _status == AuthStatus.authenticated;

  // ── Boot: try to restore session from secure storage ───────────────────────
  Future<void> initialize() async {
    final token = await _storage.read(key: AppConstants.kAuthToken);
    if (token == null) { _status = AuthStatus.unauthenticated; notifyListeners(); return; }

    try {
      final res = await _api.getMe().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Connection timeout'),
      );
      _user   = AppUser.fromJson(res['user']);
      _status = AuthStatus.authenticated;
    } catch (e) {
      await _storage.delete(key: AppConstants.kAuthToken);
      _status = AuthStatus.unauthenticated;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  // ── Register ────────────────────────────────────────────────────────────────
  Future<bool> register(String name, String email, String password) async {
    _loading = true; _error = null; notifyListeners();
    try {
      final res = await _api.register(name, email, password);
      await _storage.write(key: AppConstants.kAuthToken, value: res['token']);
      _user   = AppUser.fromJson(res['user']);
      _status = AuthStatus.authenticated;
      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['error'] ?? (e.type == DioExceptionType.connectionError ? 'Cannot connect to server. Please check internet connection.' : 'Registration failed');
      return false;
    } catch (e) {
      _error = 'Registration failed: $e';
      return false;
    } finally { _loading = false; notifyListeners(); }
  }

  // ── Login ───────────────────────────────────────────────────────────────────
  Future<bool> login(String email, String password) async {
    _loading = true; _error = null; notifyListeners();
    try {
      final res = await _api.login(email, password);
      await _storage.write(key: AppConstants.kAuthToken, value: res['token']);
      _user   = AppUser.fromJson(res['user']);
      _status = AuthStatus.authenticated;
      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['error'] ?? (e.type == DioExceptionType.connectionError ? 'Cannot connect to server. Please check internet connection.' : 'Invalid email or password');
      return false;
    } catch (e) {
      _error = 'Login failed: $e';
      return false;
    } finally { _loading = false; notifyListeners(); }
  }

  // ── Logout ──────────────────────────────────────────────────────────────────
  Future<void> logout() async {
    await _storage.delete(key: AppConstants.kAuthToken);
    _user   = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  // ── Refresh user ────────────────────────────────────────────────────────────
  Future<void> refreshUser() async {
    try {
      final res = await _api.getMe();
      _user = AppUser.fromJson(res['user']);
      notifyListeners();
    } catch (_) {}
  }

  // ── Change Password ─────────────────────────────────────────────────────────
  Future<bool> changePassword(String currentPassword, String newPassword) async {
    _loading = true; _error = null; notifyListeners();
    try {
      await _api.changePassword(currentPassword, newPassword);
      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['error'] ?? 'Failed to update password';
      return false;
    } catch (e) {
      _error = 'Failed to update password: $e';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Update Profile ──────────────────────────────────────────────────────────
  Future<bool> updateProfile(String name) async {
    _loading = true; _error = null; notifyListeners();
    try {
      final res = await _api.updateProfile(name);
      if (res['user'] != null) {
        _user = AppUser.fromJson(res['user']);
      }
      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['error'] ?? 'Failed to update profile';
      return false;
    } catch (e) {
      _error = 'Failed to update profile: $e';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void updateInstagram(InstagramAccount? ig) {
    if (_user == null) return;
    _user = _user!.copyWith(instagram: ig);
    notifyListeners();
  }

  void clearError() { _error = null; notifyListeners(); }
}
