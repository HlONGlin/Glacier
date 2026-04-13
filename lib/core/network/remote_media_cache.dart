import 'dart:io';

import 'http_client_factory.dart';
import 'network_runner.dart';
import 'request_headers.dart';

class RemoteMediaRangeCache {
  RemoteMediaRangeCache._();

  static Future<void> downloadPrefixToFile(
    String url,
    Map<String, String> headers,
    File out, {
    required int maxBytes,
    HttpClient? client,
    Future<void> Function()? beforeRequest,
    bool Function()? shouldAbort,
    Object Function()? abortError,
  }) async {
    await beforeRequest?.call();

    final httpClient = client ?? HttpClientFactory.createBackground();
    final ownsClient = client == null;
    IOSink? sink;
    try {
      final uri = Uri.parse(url);
      final req = await NetworkRunner.run(
        () => httpClient.getUrl(uri),
        label: 'range-prefix-open',
      );
      RequestHeaders.withPrefixRange(
        RequestHeaders.withAccept(headers),
        maxBytes: maxBytes,
      ).forEach(req.headers.set);
      final res = await NetworkRunner.run(
        () => req.close(),
        label: 'range-prefix-close',
      );

      if (res.statusCode != 200 && res.statusCode != 206) {
        throw HttpException('GET failed: ${res.statusCode}', uri: uri);
      }

      final tmp = File('${out.path}.download');
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      await tmp.parent.create(recursive: true);
      sink = tmp.openWrite();

      var received = 0;
      await for (final chunk in res) {
        if (shouldAbort?.call() ?? false) {
          if (!ownsClient) {
            httpClient.close(force: true);
          }
          throw abortError?.call() ?? StateError('download aborted');
        }
        if (received >= maxBytes) break;
        final remain = maxBytes - received;
        if (chunk.length <= remain) {
          sink.add(chunk);
          received += chunk.length;
        } else {
          sink.add(chunk.sublist(0, remain));
          received += remain;
          break;
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (await out.exists()) {
        try {
          await out.delete();
        } catch (_) {}
      }
      await tmp.rename(out.path);
    } catch (_) {
      if (sink != null) {
        await sink.close();
      }
      final tmp = File('${out.path}.download');
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        if (ownsClient) {
          httpClient.close(force: true);
        }
      } catch (_) {}
    }
  }
}
