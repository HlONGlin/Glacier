import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../core/logging/app_logger.dart';
import '../../../../emby.dart';
import '../../../../sources/accounts.dart';
import '../../../../sources/refs.dart';
import '../../../../core/utils/app_shared.dart';

class ResolvedNetworkMediaSource {
  final Uri uri;
  final Map<String, String> headers;
  final String title;

  const ResolvedNetworkMediaSource({
    required this.uri,
    this.headers = const <String, String>{},
    required this.title,
  });
}

class PlayerSourceResolver {
  PlayerSourceResolver._();

  static Future<Map<String, Map<String, String>>>
      loadWebDavAccountCache() async {
    try {
      return await loadWebDavAccountAuthMapShared();
    } catch (error, stackTrace) {
      AppLogger.error(
        'failed to load webdav account cache',
        error: error,
        stackTrace: stackTrace,
        tag: 'player',
      );
      return <String, Map<String, String>>{};
    }
  }

  static Future<Map<String, EmbyAccount>> loadEmbyAccountMap() async {
    try {
      return await loadEmbyAccountsMapShared();
    } catch (error, stackTrace) {
      AppLogger.error(
        'failed to load emby account map',
        error: error,
        stackTrace: stackTrace,
        tag: 'player',
      );
      return <String, EmbyAccount>{};
    }
  }

  static String displayName(String source) {
    if (isEmbySource(source)) {
      try {
        final uri = Uri.parse(source);
        final name = (uri.queryParameters['name'] ?? '').trim();
        if (name.isNotEmpty) return safeDecodeUriComponent(name);
      } catch (_) {}
      return 'Emby 媒体';
    }
    if (isWebDavSource(source)) {
      try {
        final uri = Uri.parse(source);
        final rel = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
        final base = rel.split('/').isEmpty ? rel : rel.split('/').last;
        return safeDecodeUriComponent(base);
      } catch (_) {}
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      try {
        final uri = Uri.parse(source);
        final queryName = (uri.queryParameters['name'] ?? '').trim();
        if (queryName.isNotEmpty) return safeDecodeUriComponent(queryName);
        if (uri.pathSegments.isNotEmpty) {
          return safeDecodeUriComponent(uri.pathSegments.last);
        }
      } catch (_) {}
    }
    return p.basename(source);
  }

  static Future<ResolvedNetworkMediaSource?> tryResolveWebDavSource(
    String source, {
    Map<String, Map<String, String>>? accounts,
  }) async {
    final ref = parseWebDavSource(source);
    if (ref == null) return null;

    final accountMap = accounts ?? await loadWebDavAccountCache();
    final account = accountMap[ref.accountId];
    if (account == null) return null;

    final baseUrl = (account['baseUrl'] ?? '').trim();
    final authorization = (account['authorization'] ?? '').trim();
    if (baseUrl.isEmpty) return null;

    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final relEncoded = encodePathPreserveSlash(ref.relPath);
    final resolvedUrl = Uri.parse(base).resolve(relEncoded);

    return ResolvedNetworkMediaSource(
      uri: resolvedUrl,
      title: displayName(source),
      headers: authorization.isEmpty
          ? const <String, String>{}
          : <String, String>{HttpHeaders.authorizationHeader: authorization},
    );
  }

  static Future<ResolvedNetworkMediaSource> resolveWebDavSource(
    String source, {
    Map<String, Map<String, String>>? accounts,
  }) async {
    final resolved = await tryResolveWebDavSource(source, accounts: accounts);
    if (resolved != null) return resolved;

    final ref = parseWebDavSource(source);
    if (ref == null) {
      throw Exception('无效的 WebDAV 源：$source');
    }
    final accountMap = accounts ?? await loadWebDavAccountCache();
    if (!accountMap.containsKey(ref.accountId)) {
      throw Exception('WebDAV 账号不存在：${ref.accountId}');
    }
    throw Exception('WebDAV 账号缺少 baseUrl：${ref.accountId}');
  }
}
