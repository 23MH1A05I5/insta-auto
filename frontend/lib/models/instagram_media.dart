class InstagramMedia {
  final String id;
  final String mediaType;   // IMAGE | VIDEO | CAROUSEL_ALBUM
  final String? mediaUrl;
  final String? thumbnailUrl;
  final String? caption;
  final String? timestamp;
  final String? permalink;
  final int likeCount;
  final int commentsCount;
  final int viewsCount;

  const InstagramMedia({
    required this.id,
    required this.mediaType,
    this.mediaUrl,
    this.thumbnailUrl,
    this.caption,
    this.timestamp,
    this.permalink,
    this.likeCount     = 0,
    this.commentsCount = 0,
    this.viewsCount    = 0,
  });

  String get displayUrl => thumbnailUrl ?? mediaUrl ?? '';
  bool   get isVideo    => mediaType == 'VIDEO';
  bool   get isCarousel => mediaType == 'CAROUSEL_ALBUM';

  DateTime? get parsedDate => timestamp != null ? DateTime.tryParse(timestamp!) : null;

  factory InstagramMedia.fromJson(Map<String, dynamic> json) {
    return InstagramMedia(
      id            : json['id']             as String,
      mediaType     : json['media_type']     as String? ?? 'IMAGE',
      mediaUrl      : json['media_url']      as String?,
      thumbnailUrl  : json['thumbnail_url']  as String?,
      caption       : json['caption']        as String?,
      timestamp     : json['timestamp']      as String?,
      permalink     : json['permalink']      as String?,
      likeCount     : json['like_count']     as int? ?? 0,
      commentsCount : json['comments_count'] as int? ?? 0,
      viewsCount    : json['video_views']    as int? ?? 0,
    );
  }

  InstagramMedia copyWithStats({int? likeCount, int? commentsCount, int? viewsCount}) {
    return InstagramMedia(
      id: id, mediaType: mediaType, mediaUrl: mediaUrl, thumbnailUrl: thumbnailUrl,
      caption: caption, timestamp: timestamp, permalink: permalink,
      likeCount     : likeCount      ?? this.likeCount,
      commentsCount : commentsCount  ?? this.commentsCount,
      viewsCount    : viewsCount     ?? this.viewsCount,
    );
  }
}
