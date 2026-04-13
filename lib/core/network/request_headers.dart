import 'dart:convert';
import 'dart:io';

class RequestHeaders {
  RequestHeaders._();

  static Map<String, String> withAccept(
    Map<String, String>? base, {
    String accept = '*/*',
  }) {
    final headers = <String, String>{...?base};
    headers['Accept'] = accept;
    return headers;
  }

  static Map<String, String> withRange(
    Map<String, String>? base, {
    required int start,
    required int end,
  }) {
    final headers = <String, String>{...?base};
    headers[HttpHeaders.rangeHeader] = 'bytes=$start-$end';
    return headers;
  }

  static Map<String, String> withPrefixRange(
    Map<String, String>? base, {
    required int maxBytes,
  }) {
    final headers = <String, String>{...?base};
    headers[HttpHeaders.rangeHeader] = 'bytes=0-${maxBytes - 1}';
    return headers;
  }

  static Map<String, String> withBasicAuth(
    Map<String, String>? base, {
    required String username,
    required String password,
  }) {
    final headers = <String, String>{...?base};
    final token = base64Encode(utf8.encode('$username:$password'));
    headers[HttpHeaders.authorizationHeader] = 'Basic $token';
    return headers;
  }
}
