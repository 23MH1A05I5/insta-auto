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

  const DmConfig({
    this.enabled    = true,
    this.message    = '',
    this.buttonText = 'Send me the link',
    this.link       = '',
  });

  factory DmConfig.fromJson(Map<String, dynamic> json) {
    return DmConfig(
      enabled    : json['enabled']    as bool?   ?? true,
      message    : json['message']    as String? ?? '',
      buttonText : json['buttonText'] as String? ?? 'Send me the link',
      link       : json['link']       as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled'   : enabled,
    'message'   : message,
    'buttonText': buttonText,
    'link'      : link,
  };

  DmConfig copyWith({bool? enabled, String? message, String? buttonText, String? link}) {
    return DmConfig(
      enabled    : enabled    ?? this.enabled,
      message    : message    ?? this.message,
      buttonText : buttonText ?? this.buttonText,
      link       : link       ?? this.link,
    );
  }
}

// ── Stats ────────────────────────────────────────────────────────────────────
class AutomationStats {
  final int commentsReceived;
  final int repliesSent;
  final int dmsSent;
  final int failed;

  const AutomationStats({
    this.commentsReceived = 0,
    this.repliesSent = 0,
    this.dmsSent = 0,
    this.failed = 0,
  });

  factory AutomationStats.fromJson(Map<String, dynamic> json) {
    return AutomationStats(
      commentsReceived : json['commentsReceived'] as int? ?? 0,
      repliesSent      : json['repliesSent']      as int? ?? 0,
      dmsSent          : json['dmsSent']          as int? ?? 0,
      failed           : json['failed']           as int? ?? 0,
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
      id              : json['_id']            as String,
      mediaId         : json['mediaId']         as String,
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
      createdAt       : json['createdAt']   != null ? DateTime.tryParse(json['createdAt'])      : null,
      updatedAt       : json['updatedAt']   != null ? DateTime.tryParse(json['updatedAt'])      : null,
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
}

// ── Analytics Summary ─────────────────────────────────────────────────────────
class AnalyticsSummary {
  final int totalAutomations;
  final int activeAutomations;
  final int commentsReceived;
  final int repliesSent;
  final int dmsSent;
  final int failedActions;

  const AnalyticsSummary({
    this.totalAutomations  = 0,
    this.activeAutomations = 0,
    this.commentsReceived  = 0,
    this.repliesSent       = 0,
    this.dmsSent           = 0,
    this.failedActions     = 0,
  });

  factory AnalyticsSummary.fromJson(Map<String, dynamic> json) {
    return AnalyticsSummary(
      totalAutomations  : json['totalAutomations']  as int? ?? 0,
      activeAutomations : json['activeAutomations']  as int? ?? 0,
      commentsReceived  : json['commentsReceived']   as int? ?? 0,
      repliesSent       : json['repliesSent']        as int? ?? 0,
      dmsSent           : json['dmsSent']            as int? ?? 0,
      failedActions     : json['failedActions']      as int? ?? 0,
    );
  }

  int get failed => failedActions;
}

// ── Activity Entry ────────────────────────────────────────────────────────────
class ActivityEntry {
  final String? automationId;
  final String? automationName;
  final String? commentId;
  final String? username;
  final String? text;
  final String? ruleMatched;
  final bool publicReplySent;
  final String? publicReplyStatus;
  final bool privateReplySent;
  final String? privateReplyStatus;
  final DateTime? timestamp;
  final bool isDuplicate;
  final String? error;
  final String? mediaThumbnail;
  final String? publicReplyMessage;
  final String? privateReplyMessage;

  const ActivityEntry({
    this.automationId,
    this.automationName,
    this.commentId,
    this.username,
    this.text,
    this.ruleMatched,
    this.publicReplySent    = false,
    this.publicReplyStatus,
    this.privateReplySent   = false,
    this.privateReplyStatus,
    this.timestamp,
    this.isDuplicate        = false,
    this.error,
    this.mediaThumbnail,
    this.publicReplyMessage,
    this.privateReplyMessage,
  });

  DateTime? get createdAt => timestamp;
  String get status => error != null ? 'error' : (isDuplicate ? 'skipped' : 'success');
  String? get publicReply => publicReplySent ? (publicReplyMessage ?? publicReplyStatus ?? 'Reply sent') : null;
  String? get privateReply => privateReplySent ? (privateReplyMessage ?? privateReplyStatus ?? 'DM sent') : null;

  factory ActivityEntry.fromJson(Map<String, dynamic> json) {
    final pr  = json['publicReply']  as Map<String, dynamic>?;
    final pvr = json['privateReply'] as Map<String, dynamic>?;
    return ActivityEntry(
      automationId       : json['automationId']   as String?,
      automationName     : json['automationName'] as String?,
      commentId          : json['commentId']      as String?,
      username           : json['username']       as String?,
      text               : json['text']           as String?,
      ruleMatched        : json['ruleMatched']    as String?,
      publicReplySent    : pr?['sent']  as bool? ?? (json['publicReplySent'] as bool? ?? false),
      publicReplyStatus  : pr?['status'] as String?,
      publicReplyMessage : pr?['message'] as String?,
      privateReplySent   : pvr?['sent'] as bool? ?? (json['privateReplySent'] as bool? ?? false),
      privateReplyStatus : pvr?['status'] as String?,
      privateReplyMessage: pvr?['message'] as String?,
      timestamp          : json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'])
          : (json['createdAt'] != null ? DateTime.tryParse(json['createdAt']) : null),
      isDuplicate        : json['isDuplicate'] as bool? ?? false,
      error              : json['error']       as String?,
      mediaThumbnail     : json['mediaThumbnail'] as String?,
    );
  }
}
