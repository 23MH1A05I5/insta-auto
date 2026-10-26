class InstagramAccount {
  final String userId;
  final String username;
  final String? accountType;
  final DateTime? connectedAt;
  final DateTime? tokenExpiry;

  const InstagramAccount({
    required this.userId,
    required this.username,
    this.accountType,
    this.connectedAt,
    this.tokenExpiry,
  });

  factory InstagramAccount.fromJson(Map<String, dynamic> json) {
    return InstagramAccount(
      userId      : (json['userId'] ?? '').toString(),
      username    : (json['username'] ?? '').toString(),
      accountType : json['accountType'] as String?,
      connectedAt : json['connectedAt'] != null ? DateTime.tryParse(json['connectedAt'].toString()) : null,
      tokenExpiry : json['tokenExpiry'] != null ? DateTime.tryParse(json['tokenExpiry'].toString()) : null,
    );
  }

  bool get isExpired => tokenExpiry != null && tokenExpiry!.isBefore(DateTime.now());
}

class AppUser {
  final String id;
  final String name;
  final String email;
  final InstagramAccount? instagram;
  final DateTime? createdAt;

  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    this.instagram,
    this.createdAt,
  });

  bool get hasInstagram => instagram != null;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final ig = json['instagram'];
    return AppUser(
      id        : (json['_id'] ?? json['id'] ?? '').toString(),
      name      : (json['name'] ?? '').toString(),
      email     : (json['email'] ?? '').toString(),
      createdAt : json['createdAt'] != null ? DateTime.tryParse(json['createdAt'].toString()) : null,
      instagram : (ig != null && ig is Map && (ig['userId'] != null || ig['username'] != null))
          ? InstagramAccount.fromJson(Map<String, dynamic>.from(ig))
          : null,
    );
  }

  AppUser copyWith({InstagramAccount? instagram}) {
    return AppUser(
      id: id, name: name, email: email,
      instagram: instagram ?? this.instagram,
      createdAt: createdAt,
    );
  }
}
