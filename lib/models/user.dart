class User {
  final int id;
  final String username;
  final String nickname;
  final int avatarId;
  final String createdAt;

  const User({
    required this.id,
    required this.username,
    required this.nickname,
    required this.avatarId,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      username: json['username'] as String,
      nickname: json['nickname'] as String,
      avatarId: json['avatar_id'] as int,
      createdAt: json['created_at'] as String,
    );
  }
}
