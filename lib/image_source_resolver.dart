import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'emby.dart';
import 'source_accounts.dart';
import 'source_refs.dart';

typedef ResolvedImageSource = ({String url, Map<String, String> headers});
typedef ResolvedEmbyImageSource = ({
  String url,
  Map<String, String> headers,
  double? aspectRatio
});

class AsyncLimiter {
  final int maxConcurrent;
  int _running = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  AsyncLimiter({required this.maxConcurrent});

  Future<T> run<T>(Future<T> Function() action) async {
    if (_running >= maxConcurrent) {
      final gate = Completer<void>();
      _waiters.add(gate);
      await gate.future;
    }
    _running++;
    try {
      return await action();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) {
        final next = _waiters.removeAt(0);
        if (!next.isCompleted) next.complete();
      }
    }
  }
}

class ImageSourceResolver {
  final AsyncLimiter remoteResolveLimiter;
  final Map<String, Future<Map<String, dynamic>?>> _webdavAccountFutureCache =
      {};
  final Map<String, Future<Map<String, EmbyAccount>>> _embyAccountsMapFuture =
      {};
  final Map<String, Future<EmbyItem?>> _embyItemFutureCache = {};
  final Map<String, Future<ResolvedImageSource?>> _webdavResolveFutureCache =
      {};
  final Map<String, Future<ResolvedEmbyImageSource?>> _embyResolveFutureCache =
      {};

  ImageSourceResolver({AsyncLimiter? remoteResolveLimiter})
      : remoteResolveLimiter =
            remoteResolveLimiter ?? AsyncLimiter(maxConcurrent: 3);

  bool isWebDavSource(String source) => isWebDavSourceRef(source);

  bool isEmbySource(String source) => isEmbySourceRef(source);

  Future<Map<String, dynamic>?> _loadWebDavAccountJson(String accountId) async {
    try {
      return await loadWebDavAccountJsonShared(accountId);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> webdavAccountFutureFor(String accountId) {
    return _webdavAccountFutureCache.putIfAbsent(
      accountId,
      () => _loadWebDavAccountJson(accountId),
    );
  }

  Future<Map<String, EmbyAccount>> embyAccountsMapFutureFor() {
    return _embyAccountsMapFuture.putIfAbsent(
      'all',
      loadEmbyAccountsMapShared,
    );
  }

  Future<EmbyItem?> embyItemFutureFor(EmbyClient client, String itemId) {
    final key = '${client.account.id}|$itemId';
    return _embyItemFutureCache.putIfAbsent(
      key,
      () async {
        try {
          return await client.getItemById(itemId);
        } catch (_) {
          return null;
        }
      },
    );
  }

  Future<ResolvedImageSource?> _resolveWebDav(String source) async {
    try {
      final ref = parseWebDavSource(source);
      if (ref == null) return null;
      final accountId = ref.accountId;
      final rel = encodePathPreserveSlash(ref.relPath);
      final json = await webdavAccountFutureFor(accountId);
      if (json == null) return null;

      final baseUrl = (json['baseUrl'] ?? '').toString();
      final username = (json['username'] ?? '').toString();
      final password = (json['password'] ?? '').toString();
      if (baseUrl.isEmpty) return null;

      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final url = Uri.parse(base).resolve(rel).toString();
      final token = base64Encode(utf8.encode('$username:$password'));
      final headers = <String, String>{
        HttpHeaders.authorizationHeader: 'Basic $token',
      };
      return (url: url, headers: headers);
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedImageSource?> webdavFutureFor(String source) {
    return _webdavResolveFutureCache.putIfAbsent(
      source,
      () => remoteResolveLimiter.run(() => _resolveWebDav(source)),
    );
  }

  Future<ResolvedEmbyImageSource?> _resolveEmby(String source) async {
    try {
      final ref = parseEmbySourceRef(source);
      if (ref == null) return null;
      final map = await embyAccountsMapFutureFor();
      final account = map[ref.accountId];
      if (account == null) return null;
      final client = EmbyClient(account);
      final item = await embyItemFutureFor(client, ref.itemId);
      var url = '';
      if (item != null) {
        url = client.bestImageUrl(item).trim();
      }
      if (url.isEmpty) {
        url = client.originalImageUrl(ref.itemId).trim();
      }
      if (url.isEmpty) return null;
      return (
        url: url,
        headers: client.imageHeaders(),
        aspectRatio: item?.primaryImageAspectRatio,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedEmbyImageSource?> embyFutureFor(String source) {
    return _embyResolveFutureCache.putIfAbsent(
      source,
      () => remoteResolveLimiter.run(() => _resolveEmby(source)),
    );
  }
}

bool isWebDavSourceRef(String source) => isWebDavSource(source);

bool isEmbySourceRef(String source) => isEmbySource(source);
