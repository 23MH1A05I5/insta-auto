// ── Comment Filter ────────────────────────────────────────────────────────────
enum CommentFilter { all, unreplied, replied }

// ── Comment Category ──────────────────────────────────────────────────────────
enum CommentCategory { priceInquiry, linkRequest, positiveFeedback, question, other }

// ── Reply to a Comment ────────────────────────────────────────────────────────
class CommentReply {
  final String id;
  final String text;
  final String? username;
  final DateTime? timestamp;

  const CommentReply({required this.id, required this.text, this.username, this.timestamp});

  factory CommentReply.fromJson(Map<String, dynamic> json) {
    return CommentReply(
      id        : json['id']        as String,
      text      : json['text']      as String? ?? '',
      username  : json['username']  as String?,
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
  final List<CommentReply> replies;

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
    this.replies      = const [],
    this.isReplied    = false,
    this.isSendingReply = false,
    this.isSendingDm  = false,
  });

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

    return InstagramComment(
      id            : json['id']          as String,
      text          : json['text']        as String? ?? '',
      username      : username,
      commenterId   : commenterId,
      profilePicUrl : json['profile_pic'] as String?,
      timestamp     : json['timestamp']   != null ? DateTime.tryParse(json['timestamp']) : null,
      replies       : replyList,
      isReplied     : replyList.isNotEmpty,
    );
  }

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
