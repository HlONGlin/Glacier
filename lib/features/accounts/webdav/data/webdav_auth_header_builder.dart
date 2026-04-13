import 'dart:io';

import '../../../../core/network/request_headers.dart';

class WebDavAuthHeaderBuilder {
  WebDavAuthHeaderBuilder._();

  static Map<String, String> build({
    required String username,
    required String password,
  }) {
    return RequestHeaders.withBasicAuth(
      const <String, String>{},
      username: username,
      password: password,
    );
  }

  static String buildAuthorization({
    required String username,
    required String password,
  }) {
    return build(
            username: username,
            password: password)[HttpHeaders.authorizationHeader] ??
        '';
  }
}
