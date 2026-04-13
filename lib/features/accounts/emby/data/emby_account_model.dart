class EmbyAccount {
  final String id;
  String name;
  String serverUrl;
  String username;

  // Transitional compatibility field. Keep secrets in secure storage for persistence.
  String password;

  String userId;

  // Transitional compatibility field. Keep secrets in secure storage for persistence.
  String apiKey;

  EmbyAccount({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    this.password = '',
    required this.userId,
    required this.apiKey,
  });

  Uri get baseUri {
    var s = serverUrl.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return Uri.parse(s);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'userId': userId,
        'apiKey': apiKey,
      };

  Map<String, dynamic> toStorageJson() => {
        'id': id,
        'name': name,
        'serverUrl': serverUrl,
        'username': username,
        'userId': userId,
      };

  static EmbyAccount fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString().trim();
    return EmbyAccount(
      id: id.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : id,
      name: ((j['name'] ?? '').toString().trim().isEmpty)
          ? 'Emby'
          : (j['name'] ?? '').toString(),
      serverUrl: (j['serverUrl'] ?? '').toString(),
      username: (j['username'] ?? '').toString(),
      password: (j['password'] ?? '').toString(),
      userId: (j['userId'] ?? '').toString(),
      apiKey: (j['apiKey'] ?? '').toString(),
    );
  }
}
