import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/automation_model.dart';
import '../models/instagram_media.dart';
import '../services/api_service.dart';

class AutomationProvider extends ChangeNotifier {
  final ApiService _api = ApiService();

  // ── Automations list ─────────────────────────────────────────────────────────
  List<Automation> _automations = [];
  bool   _loadingAutomations = false;
  String? _automationsError;

  List<Automation> get automations      => _automations;
  bool             get loadingAutomations => _loadingAutomations;
  String?          get automationsError => _automationsError;

  // ── Media list ───────────────────────────────────────────────────────────────
  List<InstagramMedia> _media = [];
  bool   _loadingMedia = false;
  String? _mediaError;
  String? _mediaCursor;

  List<InstagramMedia> get media        => _media;
  bool                 get loadingMedia => _loadingMedia;
  String?              get mediaError   => _mediaError;

  /// IDs of all media that already have an automation (excluding the one being edited)
  Set<String> get automatedMediaIds => _automations
      .where((a) => _editingAutomationId == null || a.id != _editingAutomationId)
      .map((a) => a.mediaId)
      .toSet();

  /// Media items that DO NOT have an existing automation yet — used in Create Automation
  List<InstagramMedia> get availableMedia {
    final existing = automatedMediaIds;
    return _media.where((m) => !existing.contains(m.id)).toList();
  }

  bool isMediaAutomated(String mediaId) {
    return _automations.any((a) => a.mediaId == mediaId && (_editingAutomationId == null || a.id != _editingAutomationId));
  }

  Automation? getAutomationForMedia(String mediaId) {
    try {
      return _automations.firstWhere((a) => a.mediaId == mediaId);
    } catch (_) {
      return null;
    }
  }

  // ── Analytics ─────────────────────────────────────────────────────────────────
  AnalyticsSummary? _analytics;
  AnalyticsSummary? get analytics => _analytics;

  // ── Activity ──────────────────────────────────────────────────────────────────
  List<ActivityEntry> _activity = [];
  bool   _loadingActivity = false;
  String? _activityError;
  int    _activityTotal = 0;

  List<ActivityEntry> get activity        => _activity;
  bool                get loadingActivity => _loadingActivity;
  String?             get activityError   => _activityError;
  int                 get activityTotal   => _activityTotal;

  // ── Wizard state (used across create-automation screens) ─────────────────────
  InstagramMedia? _selectedMedia;
  TriggerRule   _draftTrigger     = const TriggerRule();
  ReplyConfig   _draftPublicReply = const ReplyConfig(
    enabled: true,
    messages: [
      '@{username} Sent you the details in DMs! 📩',
      '@{username} Just sent you a private message with everything! ✨',
      '@{username} Check your DM for the direct link 💜',
    ],
  );
  DmConfig      _draftOpeningDm   = const DmConfig(
    enabled: true,
    message: "Hey there! I'm so happy you're here, thanks so much for your interest 😊\n\nClick below and I'll send you the link in just a sec ✨",
    buttonText: 'Send me the link',
  );
  DmConfig      _draftFinalDm     = const DmConfig(enabled: true);
  String?       _editingAutomationId;

  InstagramMedia? get selectedMedia        => _selectedMedia;
  TriggerRule     get draftTrigger         => _draftTrigger;
  ReplyConfig     get draftPublicReply     => _draftPublicReply;
  DmConfig        get draftOpeningDm       => _draftOpeningDm;
  DmConfig        get draftFinalDm         => _draftFinalDm;
  String?         get editingAutomationId  => _editingAutomationId;

  // ── CRUD ─────────────────────────────────────────────────────────────────────
  Future<void> fetchAutomations({bool silent = false}) async {
    if (!silent) {
      _loadingAutomations = true;
      _automationsError = null;
      notifyListeners();
    }
    try {
      final res  = await _api.getAutomations();
      _automations = (res['automations'] as List).map((e) => Automation.fromJson(e)).toList();
    } on DioException catch (e) {
      if (!silent) _automationsError = e.response?.data?['error'] ?? 'Failed to load automations';
    } finally {
      if (!silent) _loadingAutomations = false;
      notifyListeners();
    }
  }

  Future<Automation?> saveAutomation({String status = 'draft'}) async {
    final media = _selectedMedia;
    if (media == null) return null;

    final data = {
      'mediaId'       : media.id,
      'mediaType'     : media.mediaType,
      'mediaThumbnail': media.displayUrl,
      'mediaCaption'  : media.caption ?? '',
      'mediaTimestamp': media.timestamp,
      'trigger'       : _draftTrigger.toJson(),
      'publicReply'   : _draftPublicReply.toJson(),
      'openingDm'     : _draftOpeningDm.toJson(),
      'finalDm'       : _draftFinalDm.toJson(),
      'status'        : status,
    };

    try {
      Map<String, dynamic> res;
      if (_editingAutomationId != null) {
        res = await _api.updateAutomation(_editingAutomationId!, data);
      } else {
        res = await _api.createAutomation(data);
      }
      final automation = Automation.fromJson(res['automation']);
      await fetchAutomations();
      return automation;
    } on DioException catch (e) {
      debugPrint('[saveAutomation] ${e.response?.data}');
      return null;
    }
  }

  Future<bool> updateStatus(String id, String status) async {
    try {
      await _api.patchAutomationStatus(id, status);
      final idx = _automations.indexWhere((a) => a.id == id);
      if (idx >= 0) {
        _automations[idx] = _automations[idx].copyWith(status: status);
        notifyListeners();
      }
      return true;
    } catch (_) { return false; }
  }

  Future<bool> deleteAutomation(String id) async {
    try {
      await _api.deleteAutomation(id);
      _automations.removeWhere((a) => a.id == id);
      notifyListeners();
      return true;
    } catch (_) { return false; }
  }

  // ── Media ────────────────────────────────────────────────────────────────────
  Future<void> fetchMedia({bool reset = false}) async {
    if (reset) { _media = []; _mediaCursor = null; }
    _loadingMedia = true; _mediaError = null; notifyListeners();
    try {
      final res = await _api.getInstagramMedia(cursor: _mediaCursor);
      final items = (res['media'] as List).map((e) => InstagramMedia.fromJson(e)).toList();
      _media.addAll(items);
      _mediaCursor = res['paging']?['cursors']?['after'];
    } on DioException catch (e) {
      _mediaError = e.response?.data?['error'] ?? 'Failed to load posts';
    } finally { _loadingMedia = false; notifyListeners(); }
  }

  // ── Analytics ─────────────────────────────────────────────────────────────────
  Future<void> fetchAnalytics() async {
    try {
      final res = await _api.getAnalyticsSummary();
      _analytics = AnalyticsSummary.fromJson(res['summary']);
      notifyListeners();
    } catch (_) {}
  }

  // ── Activity ──────────────────────────────────────────────────────────────────
  Future<void> fetchActivity({bool reset = false, bool silent = false}) async {
    if (!silent) {
      if (reset) _activity = [];
      _loadingActivity = true;
      _activityError = null;
      notifyListeners();
    }
    try {
      final page = reset ? 1 : (_activity.length ~/ 50) + 1;
      final res  = await _api.getActivity(page: page);
      final items = (res['activity'] as List).map((e) => ActivityEntry.fromJson(e)).toList();
      if (reset) _activity = items; else _activity.addAll(items);
      _activityTotal = res['total'] as int? ?? 0;
    } on DioException catch (e) {
      if (!silent) _activityError = e.response?.data?['error'] ?? 'Failed to load activity';
    } finally {
      if (!silent) _loadingActivity = false;
      notifyListeners();
    }
  }

  // ── Wizard helpers ────────────────────────────────────────────────────────────
  void selectMedia(InstagramMedia? media)          { _selectedMedia    = media;   notifyListeners(); }
  void updateTrigger(TriggerRule rule)             { _draftTrigger     = rule;    notifyListeners(); }
  void updatePublicReply(ReplyConfig cfg)          { _draftPublicReply = cfg;     notifyListeners(); }
  void updateOpeningDm(DmConfig cfg)               { _draftOpeningDm   = cfg;     notifyListeners(); }
  void updateFinalDm(DmConfig cfg)                 { _draftFinalDm     = cfg;     notifyListeners(); }

  void startNewAutomation() {
    _selectedMedia       = null;
    _draftTrigger        = const TriggerRule();
    _draftPublicReply    = const ReplyConfig(
      enabled: true,
      messages: [
        '@{username} Sent you the details in DMs! 📩',
        '@{username} Just sent you a private message with everything! ✨',
        '@{username} Check your DM for the direct link 💜',
      ],
    );
    _draftOpeningDm      = const DmConfig(
      enabled: true,
      message: "Hey there! I'm so happy you're here, thanks so much for your interest 😊\n\nClick below and I'll send you the link in just a sec ✨",
      buttonText: 'Send me the link',
    );
    _draftFinalDm        = const DmConfig(enabled: true);
    _editingAutomationId = null;
    notifyListeners();
  }

  void loadForEditing(Automation a) {
    _editingAutomationId = a.id;
    _selectedMedia       = InstagramMedia(
      id          : a.mediaId,
      mediaType   : a.mediaType ?? 'IMAGE',
      thumbnailUrl: a.mediaThumbnail,
      caption     : a.mediaCaption,
      timestamp   : a.mediaTimestamp,
    );
    _draftTrigger     = a.trigger;
    _draftPublicReply = a.publicReply;
    _draftOpeningDm   = a.openingDm;
    _draftFinalDm     = a.finalDm;
    notifyListeners();
  }
}
