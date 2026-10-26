import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/instagram_comment.dart';
import '../services/api_service.dart';

class CommentProvider extends ChangeNotifier {
  final ApiService _api = ApiService();

  // ── Comments list ─────────────────────────────────────────────────────────
  String? _currentMediaId;
  List<InstagramComment> _comments = [];
  int?    _totalCommentsCount;
  bool    _loading = false;
  String? _error;
  String? _nextCursor;
  bool    _hasMore = false;

  String?                get currentMediaId      => _currentMediaId;
  List<InstagramComment> get comments            => _comments;
  int?                   get totalCommentsCount  => _totalCommentsCount;
  bool                   get loading             => _loading;
  String?                get error               => _error;
  bool                   get hasMore             => _hasMore;

  void setTotalCommentsCount(int count) {
    if (count > (_totalCommentsCount ?? 0)) {
      _totalCommentsCount = count;
      notifyListeners();
    }
  }

  // ── Suggested replies ─────────────────────────────────────────────────────
  List<String> _suggestions = [];
  bool         _loadingSuggestions = false;
  List<String> get suggestions        => _suggestions;
  bool         get loadingSuggestions => _loadingSuggestions;

  // ── Filter ────────────────────────────────────────────────────────────────
  CommentFilter _filter = CommentFilter.all;
  CommentFilter get filter => _filter;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  List<InstagramComment> get filteredComments {
    var list = _comments;
    // Filter by status
    if (_filter == CommentFilter.unreplied) {
      list = list.where((c) => c.isUnreplied).toList();
    } else if (_filter == CommentFilter.replied) {
      list = list.where((c) => c.isConfirmedReplied).toList();
    } else if (_filter == CommentFilter.failed) {
      list = list.where((c) => c.isFailed).toList();
    } else if (_filter == CommentFilter.skipped) {
      list = list.where((c) => c.isSkipped).toList();
    }
    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((c) =>
        c.username.toLowerCase().contains(q) ||
        c.text.toLowerCase().contains(q)
      ).toList();
    }
    return list;
  }

  int get unrepliedCount => _comments.where((c) => c.isUnreplied).length;
  int get repliedCount   => _comments.where((c) => c.isConfirmedReplied).length;
  int get failedCount    => _comments.where((c) => c.isFailed).length;
  int get skippedCount   => _comments.where((c) => c.isSkipped).length;

  void setFilter(CommentFilter f) {
    _filter = f;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  String _extractErrorMessage(dynamic e, String defaultMsg) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final err = data['error'];
        if (err is String && err.isNotEmpty) return err;
        if (err is Map && err['message'] != null) return err['message'].toString();
        if (data['message'] != null) return data['message'].toString();
      }
      if (e.message != null && e.message!.isNotEmpty) return e.message!;
      return defaultMsg;
    }
    return defaultMsg;
  }

  // ── Fetch comments for a media ────────────────────────────────────────────
  Future<void> fetchComments(String mediaId, {bool reset = false, int? initialTotalCount}) async {
    if (reset || _currentMediaId != mediaId) {
      _currentMediaId = mediaId;
      _comments       = [];
      _nextCursor     = null;
      _hasMore        = false;
      _filter         = CommentFilter.all;
      _searchQuery    = '';
      _loading        = false; // Clear any stale loading lock
      if (initialTotalCount != null && initialTotalCount > 0) {
        _totalCommentsCount = initialTotalCount;
      } else if (reset) {
        _totalCommentsCount = null;
      }
    }

    if (_loading) return;
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      final res = await _api.getMediaComments(
        mediaId,
        limit: 50,
        cursor: _nextCursor,
      );
      final raw = (res['comments'] as List? ?? [])
          .map((e) => InstagramComment.fromJson(e as Map<String, dynamic>))
          .toList();
      _comments.addAll(raw);

      final total = res['commentsCount'] as num?;
      if (total != null && total.toInt() > (_totalCommentsCount ?? 0)) {
        _totalCommentsCount = total.toInt();
      } else if (_totalCommentsCount == null || _comments.length > _totalCommentsCount!) {
        _totalCommentsCount = _comments.length;
      }

      final paging = res['paging'] as Map<String, dynamic>?;
      _nextCursor  = paging?['cursors']?['after'] as String?;
      _hasMore     = paging?['next'] != null;
    } on DioException catch (e) {
      _error = _extractErrorMessage(e, 'Failed to load comments');
    } catch (e) {
      _error = 'Failed to load comments: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Auto-load all comments for a media ───────────────────────────────────
  bool _isLoadingAll = false;
  bool get isLoadingAll => _isLoadingAll;

  Future<void> loadAllComments(String mediaId, {bool reset = false, int? initialTotalCount}) async {
    await fetchComments(mediaId, reset: reset, initialTotalCount: initialTotalCount);

    if (_hasMore && !_isLoadingAll) {
      _isLoadingAll = true;
      notifyListeners();
      try {
        while (_hasMore && _currentMediaId == mediaId && _comments.length < (_totalCommentsCount ?? 1000)) {
          final res = await _api.getMediaComments(
            mediaId,
            limit: 50,
            cursor: _nextCursor,
          );
          final raw = (res['comments'] as List? ?? [])
              .map((e) => InstagramComment.fromJson(e as Map<String, dynamic>))
              .toList();

          if (raw.isEmpty) break;

          final existingIds = _comments.map((c) => c.id).toSet();
          for (final c in raw) {
            if (!existingIds.contains(c.id)) {
              _comments.add(c);
              existingIds.add(c.id);
            }
          }

          final total = res['commentsCount'] as num?;
          if (total != null && total.toInt() > (_totalCommentsCount ?? 0)) {
            _totalCommentsCount = total.toInt();
          } else if (_totalCommentsCount == null || _comments.length > _totalCommentsCount!) {
            _totalCommentsCount = _comments.length;
          }

          final paging = res['paging'] as Map<String, dynamic>?;
          _nextCursor  = paging?['cursors']?['after'] as String?;
          _hasMore     = paging?['next'] != null;
          notifyListeners();
        }
      } catch (_) {
        // Silently keep already loaded comments
      } finally {
        _isLoadingAll = false;
        notifyListeners();
      }
    }
  }

  final Set<String> _inFlightDmUserIds = {};
  bool isSendingDmToUser(String userId) => _inFlightDmUserIds.contains(userId);

  // ── Reply to a comment ────────────────────────────────────────────────────
  Future<String?> replyToComment(String commentId, String message) async {
    final idx = _comments.indexWhere((c) => c.id == commentId);
    if (idx < 0) return 'Comment not found';

    if (_comments[idx].isSendingReply) {
      return 'Reply is already in progress';
    }

    _comments[idx].isSendingReply = true;
    notifyListeners();

    try {
      final res = await _api.replyToComment(commentId, message);
      if (res['ok'] != true) {
        _comments[idx].isSendingReply = false;
        notifyListeners();
        return res['error']?.toString() ?? 'Failed to send reply';
      }
      _comments[idx].isReplied    = true;
      _comments[idx].isSendingReply = false;
      _comments[idx].replies.add(CommentReply(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        text: message,
        username: 'You',
        timestamp: DateTime.now(),
      ));
      if (_totalCommentsCount != null) {
        _totalCommentsCount = _totalCommentsCount! + 1;
      }
      notifyListeners();
      return null; // success
    } on DioException catch (e) {
      _comments[idx].isSendingReply = false;
      notifyListeners();
      return _extractErrorMessage(e, 'Failed to send reply');
    } catch (e) {
      _comments[idx].isSendingReply = false;
      notifyListeners();
      return 'Failed to send reply: $e';
    }
  }

  // ── Send DM ───────────────────────────────────────────────────────────────
  /// [igUserId] is the commenter's numeric IGSID (from [InstagramComment.commenterId]).
  /// [username] is for display only.
  Future<String?> sendDm(String? igUserId, String username, String message) async {
    if (igUserId == null || igUserId.isEmpty) {
      return 'Cannot send DM: commenter\'s account ID is not available. '
          'This can happen when the user is not a business/creator account or the API doesn\'t return their ID.';
    }
    if (_inFlightDmUserIds.contains(igUserId)) {
      return 'A direct message is already being sent to this user';
    }

    _inFlightDmUserIds.add(igUserId);
    notifyListeners();

    try {
      final res = await _api.sendDm(igUserId, message);
      if (res['ok'] != true) {
        return res['error']?.toString() ?? 'Failed to send DM';
      }
      return null; // success
    } on DioException catch (e) {
      return _extractErrorMessage(e, 'Failed to send DM');
    } catch (e) {
      return 'Failed to send DM: $e';
    } finally {
      _inFlightDmUserIds.remove(igUserId);
      notifyListeners();
    }
  }

  // ── Get AI suggestions ────────────────────────────────────────────────────
  Future<void> fetchSuggestions(String commentText, {String? username}) async {
    _suggestions        = [];
    _loadingSuggestions = true;
    notifyListeners();

    try {
      final res = await _api.getSuggestedReplies(commentText, username: username);
      _suggestions = List<String>.from(res['suggestions'] ?? []);
    } catch (_) {
      // Fallback suggestions on error
      _suggestions = [
        'Thanks for your comment! Check the link in our bio for more details 💜',
        'We appreciate your support! Feel free to DM us for more info 😊',
        'Thank you for reaching out! We\'d love to help 🌟',
      ];
    } finally {
      _loadingSuggestions = false;
      notifyListeners();
    }
  }

  void clearSuggestions() {
    _suggestions        = [];
    _loadingSuggestions = false;
    notifyListeners();
  }

  void reset() {
    _currentMediaId     = null;
    _comments           = [];
    _totalCommentsCount = null;
    _loading            = false;
    _error              = null;
    _nextCursor         = null;
    _hasMore            = false;
    _filter             = CommentFilter.all;
    _searchQuery        = '';
    _suggestions        = [];
    _loadingSuggestions = false;
    _isLoadingAll       = false;
    notifyListeners();
  }
}
