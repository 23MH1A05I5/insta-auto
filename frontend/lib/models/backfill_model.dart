class BackfillPreviewComment {
  final String commentId;
  final String username;
  final String text;
  final DateTime? timestamp;
  final bool isEligible;
  final String status;
  final String? reason;
  final bool isOlderThan7Days;
  final bool willSendPublicReply;
  final bool willSendDm;

  const BackfillPreviewComment({
    required this.commentId,
    required this.username,
    required this.text,
    this.timestamp,
    required this.isEligible,
    required this.status,
    this.reason,
    required this.isOlderThan7Days,
    required this.willSendPublicReply,
    required this.willSendDm,
  });

  factory BackfillPreviewComment.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    final isEligible = (json['isEligible'] as bool?) ?? (status == 'eligible');
    final isOlderThan7Days = (json['isOlderThan7Days'] as bool?) ?? (json['dmExpired'] as bool? ?? false);
    final willSendPublicReply = (json['willSendPublicReply'] as bool?) ?? (json['canSendPublic'] as bool? ?? false);
    final willSendDm = (json['willSendDm'] as bool?) ?? (json['canSendDm'] as bool? ?? false);

    return BackfillPreviewComment(
      commentId: json['commentId'] as String? ?? '',
      username: json['username'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'].toString())
          : (json['commentTimestamp'] != null ? DateTime.tryParse(json['commentTimestamp'].toString()) : null),
      isEligible: isEligible,
      status: status,
      reason: json['reason'] as String?,
      isOlderThan7Days: isOlderThan7Days,
      willSendPublicReply: willSendPublicReply,
      willSendDm: willSendDm,
    );
  }
}

class BackfillPreviewResponse {
  final int totalComments;
  final int eligibleCount;
  final int alreadyProcessedCount;
  final int unmatchedCount;
  final int expiredDmCount;
  final List<BackfillPreviewComment> comments;

  const BackfillPreviewResponse({
    this.totalComments = 0,
    this.eligibleCount = 0,
    this.alreadyProcessedCount = 0,
    this.unmatchedCount = 0,
    this.expiredDmCount = 0,
    this.comments = const [],
  });

  factory BackfillPreviewResponse.fromJson(Map<String, dynamic> json) {
    final map = json['preview'] is Map ? Map<String, dynamic>.from(json['preview'] as Map) : json;
    final total = (map['totalComments'] as num?)?.toInt() ??
        (map['totalFound'] as num?)?.toInt() ??
        (map['comments'] as List?)?.length ??
        0;

    return BackfillPreviewResponse(
      totalComments: total,
      eligibleCount: (map['eligibleCount'] as num?)?.toInt() ?? 0,
      alreadyProcessedCount: (map['alreadyProcessedCount'] as num?)?.toInt() ?? 0,
      unmatchedCount: (map['unmatchedCount'] as num?)?.toInt() ?? 0,
      expiredDmCount: (map['expiredDmCount'] as num?)?.toInt() ?? 0,
      comments: (map['comments'] as List<dynamic>? ?? [])
          .map((c) => BackfillPreviewComment.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList(),
    );
  }
}

class BackfillActionItem {
  final String commentId;
  final String username;
  final String commentText;
  final String publicReplyStatus;
  final String dmStatus;
  final String? publicReplyError;
  final String? dmError;
  final DateTime? processedAt;
  final bool canRetryDm;
  final bool canRetryPublicReply;
  final String? retryReason;
  final String? skipReason;

  const BackfillActionItem({
    required this.commentId,
    required this.username,
    required this.commentText,
    required this.publicReplyStatus,
    required this.dmStatus,
    this.publicReplyError,
    this.dmError,
    this.processedAt,
    this.canRetryDm = false,
    this.canRetryPublicReply = false,
    this.retryReason,
    this.skipReason,
  });

  bool get isDmSkipped => dmStatus == 'skipped';
  bool get isDmUnknown => dmStatus == 'unknown' || dmStatus == 'reconciliation_required';
  bool get isDmSent => dmStatus == 'sent' || dmStatus == 'success' || dmStatus == 'already_sent' || dmStatus == 'already_processed';
  bool get isDmFailed => dmStatus == 'failed' || dmStatus == 'error' || dmStatus == 'api_error';

  static String normalizeStatus(String? raw) {
    final s = raw?.toLowerCase().trim();
    if (s == 'sent' || s == 'success' || s == 'already_sent' || s == 'already_processed') return 'sent';
    if (s == 'skipped') return 'skipped';
    if (s == 'failed' || s == 'error' || s == 'api_error' || s == 'network_error') return 'failed';
    if (s == 'unknown') return 'unknown';
    if (s == 'reconciliation_required') return 'reconciliation_required';
    if (s == 'processing') return 'processing';
    if (s == 'pending') return 'pending';
    if (s == 'disabled') return 'disabled';
    return s ?? 'unknown';
  }

  factory BackfillActionItem.fromJson(Map<String, dynamic> json) {
    final pubMap = json['publicReply'] is Map ? Map<String, dynamic>.from(json['publicReply'] as Map) : null;
    final dmMap = json['privateReply'] is Map ? Map<String, dynamic>.from(json['privateReply'] as Map) : null;

    final rawPub = json['publicReplyStatus'] as String? ?? pubMap?['status'] as String? ?? (pubMap?['sent'] == true ? 'sent' : 'disabled');
    final rawDm = json['dmStatus'] as String? ?? dmMap?['status'] as String? ?? (dmMap?['sent'] == true ? 'sent' : 'disabled');
    final pubStatus = normalizeStatus(rawPub);
    final dmStatus = normalizeStatus(rawDm);

    final pubErr = json['publicReplyError'] as String? ?? pubMap?['error'] as String?;
    final dmErr = json['dmError'] as String? ?? dmMap?['error'] as String?;

    // Safety rule: Never offer unsafe retry for confirmed sent or permanently skipped actions
    final isSent = dmStatus == 'sent';
    final isSkipped = dmStatus == 'skipped';
    final rawCanRetryDm = json['canRetryDm'] as bool? ?? dmMap?['retryEligible'] as bool? ?? false;
    final canRetryDm = !isSent && !isSkipped && rawCanRetryDm;

    final canRetryPub = json['canRetryPublic'] as bool? ?? pubMap?['retryEligible'] as bool? ?? false;
    final text = json['commentText'] as String? ?? json['text'] as String? ?? '';
    final skipReason = json['skipReason'] as String? ?? dmMap?['skipReason'] as String? ?? dmMap?['retryReason'] as String?;
    final retryReason = dmMap?['retryReason'] as String? ?? pubMap?['retryReason'] as String? ?? json['retryReason'] as String?;

    return BackfillActionItem(
      commentId: json['commentId'] as String? ?? '',
      username: json['username'] as String? ?? 'user',
      commentText: text,
      publicReplyStatus: pubStatus,
      dmStatus: dmStatus,
      publicReplyError: pubErr,
      dmError: dmErr,
      processedAt: json['processedAt'] != null ? DateTime.tryParse(json['processedAt'].toString()) : null,
      canRetryDm: canRetryDm,
      canRetryPublicReply: canRetryPub,
      retryReason: retryReason,
      skipReason: skipReason,
    );
  }
}

class BackfillJobModel {
  final String id;
  final String automationId;
  final String mediaId;
  final String status; // pending, processing, completed, completed_with_errors, failed, paused
  final int totalComments;
  final int processedCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final List<BackfillActionItem> actions;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? error;

  const BackfillJobModel({
    required this.id,
    required this.automationId,
    required this.mediaId,
    required this.status,
    this.totalComments = 0,
    this.processedCount = 0,
    this.successCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.actions = const [],
    this.startedAt,
    this.completedAt,
    this.error,
  });

  bool get isProcessing => status == 'processing' || status == 'pending';
  bool get isPaused => status == 'paused';
  bool get isCompleted => status == 'completed' || status == 'completed_with_errors';
  bool get hasFailedDms => actions.any((a) => a.canRetryDm || a.dmStatus == 'failed');
  bool get hasFailedActions => actions.any((a) => a.dmStatus == 'failed' || a.publicReplyStatus == 'failed');
  bool get hasIncompleteActions => actions.any((a) => a.dmStatus == 'pending' || a.publicReplyStatus == 'pending');
  bool get canResume => (isPaused || hasIncompleteActions) && !isProcessing;

  double get progressPercentage {
    if (totalComments <= 0) return 0.0;
    return (processedCount / totalComments).clamp(0.0, 1.0);
  }

  factory BackfillJobModel.fromJson(Map<String, dynamic> json) {
    return BackfillJobModel(
      id: (json['_id'] ?? json['id'] ?? '') as String,
      automationId: json['automationId'] as String? ?? '',
      mediaId: json['mediaId'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      totalComments: (json['totalComments'] as num?)?.toInt() ?? 0,
      processedCount: (json['processedCount'] as num?)?.toInt() ?? 0,
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      failedCount: (json['failedCount'] as num?)?.toInt() ?? 0,
      skippedCount: (json['skippedCount'] as num?)?.toInt() ?? 0,
      actions: (json['actions'] as List<dynamic>? ?? [])
          .map((a) => BackfillActionItem.fromJson(Map<String, dynamic>.from(a as Map)))
          .toList(),
      startedAt: json['startedAt'] != null ? DateTime.tryParse(json['startedAt'].toString()) : null,
      completedAt: json['completedAt'] != null ? DateTime.tryParse(json['completedAt'].toString()) : null,
      error: json['error'] as String?,
    );
  }
}
