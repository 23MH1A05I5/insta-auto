// ── Trigger Rule ─────────────────────────────────────────────────────────────
class TriggerRule {
  final String matchType;   // 'keywords' | 'any'
  final List<String> keywords;
  final bool wholeWord;

  const TriggerRule({
    this.matchType = 'keywords',
    this.keywords  = const [],
    this.wholeWord = false,
  });

  factory TriggerRule.fromJson(Map<String, dynamic> json) {
    return TriggerRule(
      matchType : json['matchType'] as String? ?? 'keywords',
      keywords  : List<String>.from(json['keywords'] ?? []),
      wholeWord : json['wholeWord'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'matchType': matchType,
    'keywords' : keywords,
    'wholeWord': wholeWord,
  };

  TriggerRule copyWith({String? matchType, List<String>? keywords, bool? wholeWord}) {
    return TriggerRule(
      matchType : matchType ?? this.matchType,
      keywords  : keywords  ?? this.keywords,
      wholeWord : wholeWord ?? this.wholeWord,
    );
  }
}

// ── Reply Config ──────────────────────────────────────────────────────────────
class ReplyConfig {
  final bool enabled;
  final List<String> messages;

  const ReplyConfig({this.enabled = true, this.messages = const []});

  factory ReplyConfig.fromJson(Map<String, dynamic> json) {
    return ReplyConfig(
      enabled  : json['enabled'] as bool? ?? true,
      messages : List<String>.from(json['messages'] ?? []),
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'messages': messages};

  ReplyConfig copyWith({bool? enabled, List<String>? messages}) {
    return ReplyConfig(
      enabled : enabled  ?? this.enabled,
      messages: messages ?? this.messages,
    );
  }
}

// ── DM Config ─────────────────────────────────────────────────────────────────
class DmConfig {
  final bool enabled;
  final String message;
  final String buttonText;
  final String link;
  final bool buttonEnabled;

  const DmConfig({
    this.enabled       = true,
    this.message       = '',
    this.buttonText    = 'Send me the link',
    this.link          = '',
    this.buttonEnabled = true,
  });

  factory DmConfig.fromJson(Map<String, dynamic> json) {
    return DmConfig(
      enabled       : json['enabled']       as bool?   ?? true,
      message       : json['message']       as String? ?? '',
      buttonText    : json['buttonText']    as String? ?? 'Send me the link',
      link          : json['link']          as String? ?? '',
      buttonEnabled : json['buttonEnabled'] as bool?   ?? ((json['buttonText'] as String?)?.isNotEmpty ?? true),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled'      : enabled,
    'message'      : message,
    'buttonText'   : buttonText,
    'link'         : link,
    'buttonEnabled': buttonEnabled,
  };

  DmConfig copyWith({
    bool? enabled,
    String? message,
    String? buttonText,
    String? link,
    bool? buttonEnabled,
  }) {
    return DmConfig(
      enabled       : enabled       ?? this.enabled,
      message       : message       ?? this.message,
      buttonText    : buttonText    ?? this.buttonText,
      link          : link          ?? this.link,
      buttonEnabled : buttonEnabled ?? this.buttonEnabled,
    );
  }
}

// ── Stats ────────────────────────────────────────────────────────────────────
class AutomationStats {
  final int commentsReceived;
  final int repliesSent;
  final int dmsSent;
  final int failed;
  final int totalFailedAttempts;

  const AutomationStats({
    this.commentsReceived    = 0,
    this.repliesSent         = 0,
    this.dmsSent             = 0,
    this.failed              = 0,
    this.totalFailedAttempts = 0,
  });

  factory AutomationStats.fromJson(Map<String, dynamic> json) {
    return AutomationStats(
      commentsReceived    : (json['commentsReceived']    as num?)?.toInt() ?? 0,
      repliesSent         : (json['repliesSent']         as num?)?.toInt() ?? 0,
      dmsSent             : (json['dmsSent']             as num?)?.toInt() ?? 0,
      failed              : (json['failed']              as num?)?.toInt() ?? 0,
      totalFailedAttempts : (json['totalFailedAttempts'] as num?)?.toInt() ?? 0,
    );
  }
}

// ── Automation ───────────────────────────────────────────────────────────────
class Automation {
  final String id;
  final String mediaId;
  final String? mediaType;
  final String? mediaThumbnail;
  final String? mediaCaption;
  final String? mediaTimestamp;
  final String name;
  final String status;   // 'active' | 'paused' | 'draft'
  final TriggerRule trigger;
  final ReplyConfig publicReply;
  final DmConfig openingDm;
  final DmConfig finalDm;
  final AutomationStats stats;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Automation({
    required this.id,
    required this.mediaId,
    this.mediaType,
    this.mediaThumbnail,
    this.mediaCaption,
    this.mediaTimestamp,
    this.name        = '',
    this.status      = 'draft',
    this.trigger     = const TriggerRule(),
    this.publicReply = const ReplyConfig(),
    this.openingDm   = const DmConfig(),
    this.finalDm     = const DmConfig(),
    this.stats       = const AutomationStats(),
    this.createdAt,
    this.updatedAt,
  });

  bool get isActive => status == 'active';
  bool get isDraft  => status == 'draft';

  factory Automation.fromJson(Map<String, dynamic> json) {
    return Automation(
      id              : (json['_id'] ?? json['id'] ?? '').toString(),
      mediaId         : (json['mediaId'] ?? '').toString(),
      mediaType       : json['mediaType']       as String?,
      mediaThumbnail  : json['mediaThumbnail']  as String?,
      mediaCaption    : json['mediaCaption']    as String?,
      mediaTimestamp  : json['mediaTimestamp']  as String?,
      name            : json['name']            as String? ?? '',
      status          : json['status']          as String? ?? 'draft',
      trigger         : json['trigger']     != null ? TriggerRule.fromJson(json['trigger'])     : const TriggerRule(),
      publicReply     : json['publicReply'] != null ? ReplyConfig.fromJson(json['publicReply']) : const ReplyConfig(),
      openingDm       : json['openingDm']   != null ? DmConfig.fromJson(json['openingDm'])      : const DmConfig(),
      finalDm         : json['finalDm']     != null ? DmConfig.fromJson(json['finalDm'])        : const DmConfig(),
      stats           : json['stats']       != null ? AutomationStats.fromJson(json['stats'])   : const AutomationStats(),
      createdAt       : json['createdAt']   != null ? DateTime.tryParse(json['createdAt'].toString()) : null,
      updatedAt       : json['updatedAt']   != null ? DateTime.tryParse(json['updatedAt'].toString()) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'mediaId'       : mediaId,
    'mediaType'     : mediaType,
    'mediaThumbnail': mediaThumbnail,
    'mediaCaption'  : mediaCaption,
    'mediaTimestamp': mediaTimestamp,
    'name'          : name,
    'status'        : status,
    'trigger'       : trigger.toJson(),
    'publicReply'   : publicReply.toJson(),
    'openingDm'     : openingDm.toJson(),
    'finalDm'       : finalDm.toJson(),
  };

  Automation copyWith({
    String? name, String? status,
    TriggerRule? trigger, ReplyConfig? publicReply,
    DmConfig? openingDm, DmConfig? finalDm,
  }) {
    return Automation(
      id: id, mediaId: mediaId, mediaType: mediaType,
      mediaThumbnail: mediaThumbnail, mediaCaption: mediaCaption,
      mediaTimestamp: mediaTimestamp, stats: stats,
      createdAt: createdAt, updatedAt: updatedAt,
      name        : name        ?? this.name,
      status      : status      ?? this.status,
      trigger     : trigger     ?? this.trigger,
      publicReply : publicReply ?? this.publicReply,
      openingDm   : openingDm   ?? this.openingDm,
      finalDm     : finalDm     ?? this.finalDm,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Automation && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

// ── Analytics Summary ─────────────────────────────────────────────────────────
class AnalyticsSummary {
  final int totalAutomations;
  final int activeAutomations;
  final int commentsReceived;
  final int repliesSent;
  final int dmsSent;
  final int confirmedReplies;
  final int confirmedDms;
  final int failedActions;
  final int skippedActions;
  final int pendingActions;
  final int unknownActions;
  final int totalFailedAttempts;

  const AnalyticsSummary({
    this.totalAutomations    = 0,
    this.activeAutomations   = 0,
    this.commentsReceived    = 0,
    this.repliesSent         = 0,
    this.dmsSent             = 0,
    this.confirmedReplies    = 0,
    this.confirmedDms        = 0,
    this.failedActions       = 0,
    this.skippedActions      = 0,
    this.pendingActions      = 0,
    this.unknownActions      = 0,
    this.totalFailedAttempts = 0,
  });

  factory AnalyticsSummary.fromJson(Map<String, dynamic> json) {
    final replies = (json['repliesSent'] as num?)?.toInt() ?? 0;
    final dms = (json['dmsSent'] as num?)?.toInt() ?? 0;
    return AnalyticsSummary(
      totalAutomations    : (json['totalAutomations']   as num?)?.toInt() ?? 0,
      activeAutomations   : (json['activeAutomations']  as num?)?.toInt() ?? 0,
      commentsReceived    : (json['commentsReceived']   as num?)?.toInt() ?? 0,
      repliesSent         : replies,
      dmsSent             : dms,
      confirmedReplies    : (json['confirmedReplies']   as num?)?.toInt() ?? replies,
      confirmedDms        : (json['confirmedDms']       as num?)?.toInt() ?? dms,
      failedActions       : (json['failedActions']      as num?)?.toInt() ?? 0,
      skippedActions      : (json['skippedActions']     as num?)?.toInt() ?? 0,
      pendingActions      : (json['pendingActions']     as num?)?.toInt() ?? 0,
      unknownActions      : (json['unknownActions']     as num?)?.toInt() ?? 0,
      totalFailedAttempts : (json['totalFailedAttempts'] as num?)?.toInt() ?? 0,
    );
  }

  int get failed => failedActions;
}

// ── Activity Entry ────────────────────────────────────────────────────────────
class ActivityEntry {
  final String? id;
  final String? automationId;
  final String? automationName;
  final String? commentId;
  final String? mediaId;
  final String? username;
  final String? text;
  final String? ruleMatched;
  final bool publicReplySent;
  final String? publicReplyStatus;
  final String? publicReplyError;
  final bool privateReplySent;
  final String? privateReplyStatus;
  final String? privateReplyError;
  final DateTime? timestamp;
  final bool isDuplicate;
  final String? error;
  final String? mediaThumbnail;
  final String? publicReplyMessage;
  final String? privateReplyMessage;
  final bool retryEligible;
  final String? retryReason;
  final int attempts;
  final String? errorCategory;
  final bool isProcessing;
  final String? rawStatus;
  final bool reconciliationRequired;
  final String? messageId;
  final DateTime? sentAt;
  final String? skipReason;

  const ActivityEntry({
    this.id,
    this.automationId,
    this.automationName,
    this.commentId,
    this.mediaId,
    this.username,
    this.text,
    this.ruleMatched,
    this.publicReplySent    = false,
    this.publicReplyStatus,
    this.publicReplyError,
    this.privateReplySent   = false,
    this.privateReplyStatus,
    this.privateReplyError,
    this.timestamp,
    this.isDuplicate        = false,
    this.error,
    this.mediaThumbnail,
    this.publicReplyMessage,
    this.privateReplyMessage,
    this.retryEligible      = false,
    this.retryReason,
    this.attempts           = 0,
    this.errorCategory,
    this.isProcessing       = false,
    this.rawStatus,
    this.reconciliationRequired = false,
    this.messageId,
    this.sentAt,
    this.skipReason,
  });

  DateTime? get createdAt => timestamp;

  /// Authoritative status: NEVER defaults to success.
  /// Only returns 'sent' / 'success' when confirmed delivered or reliably reconciled.
  String get status {
    final explicit = rawStatus?.toLowerCase().trim();
    if (explicit != null && explicit.isNotEmpty) {
      if (explicit == 'failed' || explicit == 'error' || explicit == 'api_error' || explicit == 'network_error') {
        return 'failed';
      }
      if (explicit == 'unknown') {
        return 'unknown';
      }
      if (explicit == 'reconciliation_required') {
        return 'reconciliation_required';
      }
      if (explicit == 'processing') {
        return 'processing';
      }
      if (explicit == 'pending') {
        return 'pending';
      }
      if (explicit == 'skipped') {
        return 'skipped';
      }
      if (explicit == 'sent' || explicit == 'success' || explicit == 'already_sent' || explicit == 'already_processed') {
        return 'sent';
      }
    }

    // Evaluate sub-action statuses independently
    final dm = privateReplyStatus?.toLowerCase().trim();
    final pub = publicReplyStatus?.toLowerCase().trim();

    if (dm == 'failed' || pub == 'failed' || (error != null && error!.isNotEmpty)) {
      return 'failed';
    }
    if (dm == 'unknown' || pub == 'unknown') {
      return 'unknown';
    }
    if (dm == 'reconciliation_required' || pub == 'reconciliation_required' || reconciliationRequired) {
      return 'reconciliation_required';
    }
    if (dm == 'processing' || pub == 'processing' || isProcessing) {
      return 'processing';
    }
    if (dm == 'pending' || pub == 'pending') {
      return 'pending';
    }
    if (isDuplicate || (dm == 'skipped' && pub == 'skipped') || (dm == 'skipped' && pub == null) || (pub == 'skipped' && dm == null)) {
      return 'skipped';
    }

    // Only confirm sent if confirmed delivered or confirmed sent flag
    if (privateReplySent || publicReplySent || dm == 'sent' || pub == 'sent') {
      return 'sent';
    }

    // Safety rule: Never default unknown delivery states to success
    return 'unknown';
  }

  bool get isSuccess => status == 'sent' || status == 'success';
  bool get isFailed => status == 'failed' || status == 'error';
  bool get isSkipped => status == 'skipped';
  bool get isUnknown => status == 'unknown' || status == 'reconciliation_required';

  String? get publicReply => publicReplySent ? (publicReplyMessage ?? publicReplyStatus ?? 'Reply sent') : null;
  String? get privateReply => privateReplySent ? (privateReplyMessage ?? privateReplyStatus ?? 'DM sent') : null;

  factory ActivityEntry.fromJson(Map<String, dynamic> json) {
    final pr  = json['publicReply']  as Map<String, dynamic>?;
    final pvr = json['privateReply'] as Map<String, dynamic>?;
    final entryId = (json['_id'] ?? json['id'] ?? json['commentId'] ?? json['actionId'])?.toString();
    return ActivityEntry(
      id                 : entryId,
      automationId       : json['automationId']   as String?,
      automationName     : json['automationName'] as String?,
      commentId          : json['commentId']      as String?,
      mediaId            : json['mediaId']        as String?,
      username           : json['username']       as String?,
      text               : json['text']           as String?,
      ruleMatched        : json['ruleMatched']    as String?,
      publicReplySent    : pr?['sent']  as bool? ?? (json['publicReplySent'] as bool? ?? false),
      publicReplyStatus  : pr?['status'] as String? ?? (json['publicReplyStatus'] as String?),
      publicReplyMessage : pr?['message'] as String? ?? (json['publicReplyMessage'] as String?),
      publicReplyError   : pr?['error'] as String? ?? (pr?['errorMessage'] as String?),
      privateReplySent   : pvr?['sent'] as bool? ?? (json['privateReplySent'] as bool? ?? false),
      privateReplyStatus : pvr?['status'] as String? ?? (json['privateReplyStatus'] as String?),
      privateReplyMessage: pvr?['message'] as String? ?? (json['privateReplyMessage'] as String?),
      privateReplyError  : pvr?['error'] as String? ?? (pvr?['errorMessage'] as String?),
      timestamp          : json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'].toString())
          : (json['createdAt'] != null ? DateTime.tryParse(json['createdAt'].toString()) : null),
      isDuplicate        : json['isDuplicate'] as bool? ?? false,
      error              : json['error']       as String?,
      mediaThumbnail     : json['mediaThumbnail'] as String?,
      retryEligible      : pvr?['retryEligible'] as bool? ?? (json['retryEligible'] as bool? ?? false),
      retryReason        : pvr?['retryReason'] as String? ?? (json['retryReason'] as String?),
      attempts           : (pvr?['attempts'] as num?)?.toInt() ?? ((json['attempts'] as num?)?.toInt() ?? 0),
      errorCategory      : pvr?['errorCategory'] as String? ?? (json['errorCategory'] as String?),
      isProcessing       : pvr?['isProcessing'] as bool? ?? (json['isProcessing'] as bool? ?? false),
      rawStatus          : json['status'] as String?,
      reconciliationRequired: json['reconciliationRequired'] as bool? ?? false,
      messageId          : json['messageId'] as String?,
      sentAt             : json['sentAt'] != null ? DateTime.tryParse(json['sentAt'].toString()) : null,
      skipReason         : json['skipReason'] as String? ?? pvr?['skipReason'] as String? ?? pr?['skipReason'] as String?,
    );
  }
}
