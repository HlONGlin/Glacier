part of '../video.dart';

Future<Media?> _createDesktopEmbyMedia(
  String source,
  Map<String, EmbyAccount> accMap, {
  bool prefetchPlaybackInfo = false,
}) async {
  try {
    final u = Uri.parse(source);
    final ref = parseEmbySourceRef(source);
    final accId = ref?.accountId.trim() ?? '';
    final itemId = ref?.itemId.trim() ?? '';
    if (accId.isEmpty || itemId.isEmpty) return null;

    final acc = accMap[accId];
    if (acc == null) return null;
    final client = EmbyClient(acc);
    final name = (u.queryParameters['name'] ?? '').trim();
    final streamName = name.isNotEmpty && name.runes.length <= 96 ? name : null;
    String? mediaSourceId;
    if (prefetchPlaybackInfo) {
      try {
        mediaSourceId = (await client
                .playbackInfo(itemId)
                .timeout(const Duration(seconds: 2), onTimeout: () => null))
            ?.mediaSourceId;
      } catch (_) {
        mediaSourceId = null;
      }
    }
    final deviceId = await EmbyStore.getOrCreateDeviceId();
    final url = client.streamUrl(
      itemId,
      name: streamName,
      deviceId: deviceId,
      mediaSourceId: mediaSourceId,
    );
    return Media(url);
  } catch (e) {
    debugPrint('Create Emby Media Error: $e');
    return null;
  }
}

Future<Media?> _createDesktopWebDavMedia(
  String source,
  Map<String, Map<String, String>> accounts,
) async {
  try {
    final ref = parseWebDavSource(source);
    if (ref == null) return null;
    final accountId = ref.accountId;
    final relEncoded = encodePathPreserveSlash(ref.relPath);

    final acc = accounts[accountId];
    if (acc == null) return null;

    final baseUrl = acc['baseUrl']!;
    final username = acc['username']!;
    final password = acc['password']!;
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final resolvedUrl = Uri.parse(base).resolve(relEncoded).toString();
    final token = base64Encode(utf8.encode('$username:$password'));

    return Media(
      resolvedUrl,
      httpHeaders: <String, String>{
        HttpHeaders.authorizationHeader: 'Basic $token',
      },
    );
  } catch (e) {
    debugPrint(
        'Create WebDav Media Error: ${redactSensitiveText(e.toString())}');
    return null;
  }
}

class _MobileResolvedSource {
  final Uri? networkUri;
  final String? localPath;
  final Map<String, String> headers;
  final String title;

  const _MobileResolvedSource.network(
    this.networkUri, {
    required this.title,
    this.headers = const <String, String>{},
  }) : localPath = null;

  const _MobileResolvedSource.local(
    this.localPath, {
    required this.title,
  })  : networkUri = null,
        headers = const <String, String>{};

  bool get isLocal => localPath != null && localPath!.trim().isNotEmpty;
}

extension _DesktopVideoSourceResolution on _VideoPlayerPageState {
  Future<Media?> _createEmbyMediaAsync(
    String source,
    Map<String, EmbyAccount> accMap, {
    bool prefetchPlaybackInfo = false,
  }) {
    return _createDesktopEmbyMedia(
      source,
      accMap,
      prefetchPlaybackInfo: prefetchPlaybackInfo,
    );
  }

  Future<Media?> _createWebDavMediaAsync(
    String source,
    Map<String, Map<String, String>> accounts,
  ) {
    return _createDesktopWebDavMedia(source, accounts);
  }
}

extension _MobileVideoSourceResolution on _MobileVideoPlayerPageState {
  Future<_MobileResolvedSource> _resolveEmbySource(String source) async {
    final ref = _parseEmbyRef(source);
    if (ref == null) {
      throw Exception('不支持的 Emby 源：$source');
    }

    _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
    final acc = _embyAccounts![ref.accountId];
    if (acc == null) {
      throw Exception('Emby 账号不存在：${ref.accountId}');
    }

    final client = EmbyClient(acc);
    final name = (() {
      try {
        final u = Uri.parse(source);
        return (u.queryParameters['name'] ?? '').trim();
      } catch (_) {
        return '';
      }
    })();
    final streamName = name.isNotEmpty && name.runes.length <= 96 ? name : null;
    String? mediaSourceId;
    try {
      mediaSourceId = (await client
              .playbackInfo(ref.itemId)
              .timeout(const Duration(seconds: 2), onTimeout: () => null))
          ?.mediaSourceId;
    } catch (_) {}

    final deviceId = await EmbyStore.getOrCreateDeviceId();
    final url = client.streamUrl(
      ref.itemId,
      name: streamName,
      deviceId: deviceId,
      mediaSourceId: mediaSourceId,
    );
    return _MobileResolvedSource.network(
      Uri.parse(url),
      title: PlayerSourceResolver.displayName(source),
    );
  }

  Future<_MobileResolvedSource> _resolveWebDavSource(String source) async {
    _webDavAccounts ??= await PlayerSourceResolver.loadWebDavAccountCache();
    final resolved = await PlayerSourceResolver.resolveWebDavSource(
      source,
      accounts: _webDavAccounts,
    );
    return _MobileResolvedSource.network(
      resolved.uri,
      title: resolved.title,
      headers: resolved.headers,
    );
  }

  Future<_MobileResolvedSource> _resolveSource(String source) async {
    if (isEmbySource(source)) return _resolveEmbySource(source);
    if (isWebDavSource(source)) return _resolveWebDavSource(source);
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return _MobileResolvedSource.network(
        Uri.parse(source),
        title: PlayerSourceResolver.displayName(source),
      );
    }
    return _MobileResolvedSource.local(
      source,
      title: PlayerSourceResolver.displayName(source),
    );
  }
}
