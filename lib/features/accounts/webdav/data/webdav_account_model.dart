import 'dart:io';

import 'webdav_auth_header_builder.dart';

class WebDavAccount {
  final String id;
  String name;
  String baseUrl;
  String username;

  // Transitional compatibility field. Keep secrets in secure storage for persistence.
  String password;

  WebDavAccount({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
      };

  Map<String, dynamic> toStorageJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
      };

  static WebDavAccount fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString().trim();
    return WebDavAccount(
      id: id.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : id,
      name: ((j['name'] ?? '').toString().trim().isEmpty)
          ? 'WebDAV'
          : (j['name'] ?? '').toString(),
      baseUrl: (j['baseUrl'] ?? '').toString(),
      username: (j['username'] ?? '').toString(),
      password: (j['password'] ?? '').toString(),
    );
  }

  Uri get baseUri {
    var b = baseUrl.trim();
    if (!b.endsWith('/')) b = '$b/';
    return Uri.parse(b);
  }

  Map<String, String> get authHeaders => WebDavAuthHeaderBuilder.build(
        username: username,
        password: password,
      );

  String get basicAuthorization =>
      authHeaders[HttpHeaders.authorizationHeader] ?? '';
}
