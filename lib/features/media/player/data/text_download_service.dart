import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../../core/network/http_client_factory.dart';
import '../../../../core/network/network_runner.dart';

class TextDownloadService {
  TextDownloadService._();

  static Future<String> downloadText(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final client = HttpClientFactory.createForeground(
      connectionTimeout: const Duration(seconds: 15),
    );
    try {
      final request = await NetworkRunner.run(
        () => client.getUrl(uri),
        label: 'text-download-open',
      );
      request.headers.set('Accept', '*/*');
      headers?.forEach((key, value) => request.headers.set(key, value));

      final response = await NetworkRunner.run(
        () => request.close(),
        label: 'text-download-close',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('GET failed: ${response.statusCode}', uri: uri);
      }

      final bytes = await consolidateHttpClientResponseBytes(response);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }
}
