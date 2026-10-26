// ── Comment Filter ────────────────────────────────────────────────────────────
enum CommentFilter { all, unreplied, replied, failed, skipped }

// ── Comment Category ──────────────────────────────────────────────────────────
enum CommentCategory { priceInquiry, linkRequest, positiveFeedback, question, other }

// ── Reply to a Comment ────────────────────────────────────────────────────────
class CommentReply {
  final String id;
  final String text;
  final String? username;
  final DateTime? timestamp;

  const CommentReply({required this.id, required this.text, this.username, this.timestamp});

  String get timeAgo {
    if (timestamp == null) return '';
    final diff = DateTime.now().difference(timestamp!);
    if (diff.inSeconds < 60)  return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)    return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  factory CommentReply.fromJson(Map<String, dynamic> json) {
    final from = json['from'] as Map<String, dynamic>?;
    final user = json['username'] as String? ?? from?['username'] as String? ?? 'User';
    return CommentReply(
      id        : (json['id'] ?? '').toString(),
      text      : json['text']      as String? ?? '',
      username  : user,
      timestamp : json['timestamp'] != null ? DateTime.tryParse(json['timestamp']) : null,
    );
  }
}

// ── Instagram Comment ─────────────────────────────────────────────────────────
class InstagramComment {
  final String id;
  final String text;
  final String username;
  final String? commenterId;   // Numeric IGSID — needed for sending DMs
  final String? profilePicUrl;
  final DateTime? timestamp;
  List<CommentReply> replies;

  // Real action statuses from backend / ledger
  final String? publicReplyStatus;
  final String? dmStatus;
  final bool isEligibleForDm;
  final String? dmIneligibleReason;
  final Map<String, dynamic>? actionLedger;

  // Local UI state (not from API)
  bool isReplied;
  bool isSendingReply;
  bool isSendingDm;

  InstagramComment({
    required this.id,
    required this.text,
    required this.username,
    this.commenterId,
    this.profilePicUrl,
    this.timestamp,
    List<CommentReply>? replies,
    this.publicReplyStatus,
    this.dmStatus,
    this.isEligibleForDm = true,
    this.dmIneligibleReason,
    this.actionLedger,
    this.isReplied    = false,
    this.isSendingReply = false,
    this.isSendingDm  = false,
  }) : replies = replies ?? [];

  factory InstagramComment.fromJson(Map<String, dynamic> json) {
    final repliesData = json['replies'] as Map<String, dynamic>?;
    final replyList   = repliesData != null
        ? (repliesData['data'] as List? ?? []).map((r) => CommentReply.fromJson(r as Map<String, dynamic>)).toList()
        : <CommentReply>[];

    // The commenter's IGSID comes from the `from` field (not top-level `username`)
    final from        = json['from'] as Map<String, dynamic>?;
    final commenterId = from?['id'] as String?;
    final username    = from?['username'] as String?
                     ?? json['username'] as String?
                     ?? 'unknown';

    final parsedTime = json['timestamp'] != null ? DateTime.tryParse(json['timestamp']) : null;
    final isOld = parsedTime != null && DateTime.now().difference(parsedTime).inDays >= 7;

    final pubStatus = json['publicReplyStatus'] as String? ?? (replyList.isNotEmpty ? 'sent' : 'none');
    final rawDmStatus = json['dmStatus'] as String?;
    final dmEligible = json['isEligibleForDm'] as bool? ?? (!isOld && rawDmStatus != 'ineligible');
    final ineligibleReason = json['dmIneligibleReason'] as String? ??
        (isOld ? 'Meta messaging policy: Comments older than 7 days cannot receive private DMs.' : null);

    final finalDmStatus = rawDmStatus ?? (dmEligible ? 'none' : 'ineligible');
    final repliedFlag = pubStatus == 'sent' || finalDmStatus == 'sent' || replyList.isNotEmpty;

    return InstagramComment(
      id                  : json['id']          as String,
      text                : json['text']        as String? ?? '',
      username            : username,
      commenterId         : commenterId,
      profilePicUrl       : json['profile_pic'] as String? ?? json['profilePicUrl'] as String?,
      timestamp           : parsedTime,
      replies             : replyList,
      publicReplyStatus   : pubStatus,
      dmStatus            : finalDmStatus,
      isEligibleForDm     : dmEligible,
      dmIneligibleReason  : ineligibleReason,
      actionLedger        : json['actionLedger'] as Map<String, dynamic>?,
      isReplied           : repliedFlag,
    );
  }

  bool get isFailed => publicReplyStatus == 'failed' || dmStatus == 'failed';
  bool get isSkipped => dmStatus == 'ineligible' || dmStatus == 'skipped' || publicReplyStatus == 'skipped';
  bool get isConfirmedReplied => publicReplyStatus == 'sent' || dmStatus == 'sent' || isReplied;
  bool get isUnreplied => !isConfirmedReplied && !isFailed && !isSkipped;

  // Classify the comment into a category
  CommentCategory get category {
    final t = text.toLowerCase();
    if (RegExp(r'price|cost|how much|rate|charge|fee|₹|rs\.|rupee').hasMatch(t)) return CommentCategory.priceInquiry;
    if (RegExp(r'link|buy|order|purchase|where.*get|get.*where|shop').hasMatch(t)) return CommentCategory.linkRequest;
    if (RegExp(r'love|amazing|great|awesome|beautiful|nice|wow|fantastic|excellent|best|wonderful').hasMatch(t)) return CommentCategory.positiveFeedback;
    if (RegExp(r'\?|how|what|when|which|where|tell me|explain|info|detail').hasMatch(t)) return CommentCategory.question;
    return CommentCategory.other;
  }

  String get categoryLabel {
    switch (category) {
      case CommentCategory.priceInquiry:   return 'Price Inquiry';
      case CommentCategory.linkRequest:    return 'Link Request';
      case CommentCategory.positiveFeedback: return 'Positive';
      case CommentCategory.question:       return 'Question';
      case CommentCategory.other:          return 'Other';
    }
  }

  String get timeAgo {
    if (timestamp == null) return '';
    final diff = DateTime.now().difference(timestamp!);
    if (diff.inSeconds < 60)  return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)    return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Meta Messaging Policy: Private replies can only be sent within 7 days
  bool get isOlderThan7Days {
    if (timestamp == null) return false;
    return DateTime.now().difference(timestamp!).inDays >= 7;
  }
}
