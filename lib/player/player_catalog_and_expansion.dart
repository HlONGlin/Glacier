part of '../video.dart';

/// 播放器内“目录/同文件夹播放列表”按需扩容结果。
class _ExpandedPlaylist {
  final List<String> sources;
  final int index;
  const _ExpandedPlaylist({required this.sources, required this.index});
}

class _WebDavRef {
  final String accountId;
  final String relPath;
  const _WebDavRef({required this.accountId, required this.relPath});
}

class _WebDavListItem {
  final String name;
  final String relPath;
  final bool isDir;
  final int size;
  final DateTime? modified;
  const _WebDavListItem({
    required this.name,
    required this.relPath,
    required this.isDir,
    required this.size,
    required this.modified,
  });
}

extension _PlayerCatalogAndExpansion on _VideoPlayerPageState {
  static const Set<String> _imgExts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  bool _looksLikeImageFile(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) return false;
    return _imgExts.contains(ext);
  }

  Widget _buildCatalogThumb(String source, {int cacheWidth = 320}) {
    if (isEmbySource(source)) {
      final ref = _parseEmbySourceRef(source);
      if (ref == null) return _catalogThumbPlaceholder();
      _embyAccountMapFuture ??= PlayerSourceResolver.loadEmbyAccountMap();
      return FutureBuilder<Map<String, EmbyAccount>>(
        future: _embyAccountMapFuture,
        builder: (ctx, snap) {
          final m = snap.data;
          final acc = (m == null) ? null : m[ref.accountId];
          if (acc == null) return _catalogThumbPlaceholder();
          final client = EmbyClient(acc);
          final url = client.coverUrl(ref.itemId,
              type: 'Primary', maxWidth: cacheWidth, quality: 85);
          return Image.network(
            url,
            headers: client.imageHeaders(),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            errorBuilder: (_, __, ___) => _catalogThumbPlaceholder(),
          );
        },
      );
    }

    if (isWebDavSource(source)) {
      final cover = _webDavSidecarCoverByVideoSource[source];
      if (cover != null && cover.trim().isNotEmpty) {
        return _buildWebDavImageThumb(cover, cacheWidth: cacheWidth);
      }
      return _buildWebDavVideoThumb(source, cacheWidth: cacheWidth);
    }

    return VideoThumbImage(videoPath: source, cacheOnly: false);
  }

  Widget _catalogThumbPlaceholder() {
    return Container(
      color: Colors.black12,
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 20, color: Colors.white54),
      ),
    );
  }

  Future<({String url, Map<String, String> headers})?> _resolveWebDavHttp(
      String source) {
    final hit = _touchLru(_webDavResolveFutureCache, source);
    if (hit != null) return hit;

    final fut = _rememberLru(_webDavResolveFutureCache, source, () async {
      final ref = _parseWebDavSourceForListing(source);
      if (ref == null) return null;
      final accountId = ref.accountId;
      final relDecoded = ref.relPath;
      if (accountId.isEmpty || relDecoded.isEmpty) return null;

      final accs = await (_webDavAccountCacheFuture ??
          PlayerSourceResolver.loadWebDavAccountCache());
      final acc = accs[accountId];
      if (acc == null) return null;
      final resolved = await PlayerSourceResolver.tryResolveWebDavSource(
        source,
        accounts: accs,
      );
      if (resolved == null) return null;
      return (
        url: resolved.uri.toString(),
        headers: resolved.headers,
      );
    }());
    _trimFutureCache(
      _webDavResolveFutureCache,
      _VideoPlayerPageState._kMaxWebDavResolveEntries,
    );
    return fut;
  }

  Widget _buildWebDavImageThumb(String source, {int cacheWidth = 320}) {
    return FutureBuilder<({String url, Map<String, String> headers})?>(
      future: _resolveWebDavHttp(source),
      builder: (ctx, snap) {
        final r = snap.data;
        if (r == null) return _catalogThumbPlaceholder();
        return Image.network(
          r.url,
          headers: r.headers,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          errorBuilder: (_, __, ___) => _catalogThumbPlaceholder(),
        );
      },
    );
  }

  Widget _buildWebDavVideoThumb(String source, {int cacheWidth = 320}) {
    final fut = _touchLru(_webDavVideoThumbFutureCache, source) ??
        _rememberLru(
          _webDavVideoThumbFutureCache,
          source,
          _getOrCreateWebDavVideoThumb(source),
        );
    _trimFutureCache(
      _webDavVideoThumbFutureCache,
      _VideoPlayerPageState._kMaxWebDavVideoThumbFutureEntries,
    );
    return FutureBuilder<File?>(
      future: fut,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f != null && f.existsSync() && f.lengthSync() > 0) {
          return Image.file(
            f,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );
        }
        return _catalogThumbPlaceholder();
      },
    );
  }

  Future<File?> _getOrCreateWebDavVideoThumb(String source) async {
    return _catalogThumbSemaphore.withPermit(() async {
      try {
        final resolved = await _resolveWebDavHttp(source);
        if (resolved == null) return null;
        final ref = _parseWebDavSourceForListing(source);
        final relExt = ref == null ? '' : p.extension(ref.relPath);

        final key = PersistentStore.instance
            .makeKey('webdav_prefix|${resolved.url}|6mb');
        final ext = relExt.isNotEmpty ? relExt : '.mp4';
        final part = await PersistentStore.instance.getFile(key, 'media', ext);

        final cached = await ThumbCache.getCachedVideoThumb(part.path);
        if (cached != null) return cached;

        if (!await part.exists() || await part.length() <= 0) {
          await RemoteMediaRangeCache.downloadPrefixToFile(
            resolved.url,
            resolved.headers,
            part,
            maxBytes: 6 * 1024 * 1024,
          );
        }

        if (!await part.exists() || await part.length() <= 0) return null;
        final thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
            part.path, Duration.zero);
        if (thumb != null) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
        }
        return thumb;
      } catch (_) {
        return null;
      }
    });
  }

  void _prefetchCatalogThumbsAround(int index) {
    if (!_hasPlaylist) return;
    final start = max(0, index - 2);
    final end = min(_sources.length - 1, index + 2);
    for (var i = start; i <= end; i++) {
      final src = _sources[i];
      if (isWebDavSource(src)) {
        if ((_webDavSidecarCoverByVideoSource[src] ?? '').trim().isEmpty) {
          _touchLru(_webDavVideoThumbFutureCache, src) ??
              _rememberLru(
                _webDavVideoThumbFutureCache,
                src,
                _getOrCreateWebDavVideoThumb(src),
              );
          _trimFutureCache(
            _webDavVideoThumbFutureCache,
            _VideoPlayerPageState._kMaxWebDavVideoThumbFutureEntries,
          );
        }
      }
    }
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromLocalDir(
      String currentPath) async {
    try {
      final f = File(currentPath);
      if (!await f.exists()) return null;
      final dir = f.parent;
      final entries = await dir
          .list(followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();

      final vids = <File>[];
      for (final it in entries) {
        final name = p.basename(it.path);
        if (_looksLikeVideoFile(name)) vids.add(it);
      }
      if (vids.length <= 1) return null;

      vids.sort((a, b) => _naturalCompare(
          p.basename(a.path).toLowerCase(), p.basename(b.path).toLowerCase()));
      final srcs = vids.map((e) => e.path).toList();
      final idx = srcs.indexWhere((s) => p.equals(s, currentPath));
      return _ExpandedPlaylist(sources: srcs, index: idx >= 0 ? idx : 0);
    } catch (_) {
      return null;
    }
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromWebDavDir(
      String currentSource) async {
    final parsed = _parseWebDavSourceForListing(currentSource);
    if (parsed == null) return null;
    final accountId = parsed.accountId;
    final relPath = parsed.relPath;
    if (accountId.isEmpty || relPath.isEmpty) return null;

    final parentRel = _parentRelPath(relPath);
    final accountCache = await (_webDavAccountCacheFuture ??
        Future.value(<String, Map<String, String>>{}));
    final acc = accountCache[accountId];
    if (acc == null) return null;

    final baseUrl = acc['baseUrl'] ?? '';
    final username = acc['username'] ?? '';
    final password = acc['password'] ?? '';
    if (baseUrl.trim().isEmpty) return null;

    final list = await _webDavPropfindList(
      baseUrl: baseUrl,
      username: username,
      password: password,
      relFolder: parentRel,
    );
    if (list.isEmpty) return null;

    final imgItems =
        list.where((e) => !e.isDir && _looksLikeImageFile(e.name)).toList();
    final imgByBaseLower = <String, _WebDavListItem>{};
    for (final it in imgItems) {
      final base = p.basenameWithoutExtension(it.name).toLowerCase();
      imgByBaseLower.putIfAbsent(base, () => it);
    }

    _WebDavListItem? commonCover;
    if (imgItems.isNotEmpty) {
      const commonNames = <String>{
        'poster',
        'cover',
        'folder',
        'thumb',
        'fanart'
      };
      for (final it in imgItems) {
        final b = p.basenameWithoutExtension(it.name).toLowerCase();
        if (commonNames.contains(b)) {
          commonCover = it;
          break;
        }
      }
    }
    final singleCover = imgItems.length == 1 ? imgItems.first : null;

    final items =
        list.where((e) => !e.isDir && _looksLikeVideoFile(e.name)).toList();
    if (items.length <= 1) return null;

    items.sort(
        (a, b) => _naturalCompare(a.name.toLowerCase(), b.name.toLowerCase()));

    final newCoverMap = <String, String>{};
    final srcs = <String>[];
    var idx = 0;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final src = (it.relPath == relPath)
          ? currentSource
          : _buildWebDavSource(accountId, it.relPath);
      srcs.add(src);
      if (it.relPath == relPath) idx = i;

      final baseLower = p.basenameWithoutExtension(it.name).toLowerCase();
      final img = imgByBaseLower[baseLower] ?? commonCover ?? singleCover;
      if (img != null && img.relPath.trim().isNotEmpty) {
        final coverSrc = _buildWebDavSource(accountId, img.relPath);
        newCoverMap[src] = coverSrc;
      }
    }

    if (newCoverMap.isNotEmpty) {
      _webDavSidecarCoverByVideoSource
        ..removeWhere((k, v) => srcs.contains(k))
        ..addAll(newCoverMap);
      _trimStringCache(
        _webDavSidecarCoverByVideoSource,
        _VideoPlayerPageState._kMaxWebDavSidecarCoverEntries,
      );
    }
    return _ExpandedPlaylist(sources: srcs, index: idx);
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromEmbyDir(
      String currentSource) async {
    final ref = _parseEmbySourceRef(currentSource);
    if (ref == null) return null;
    final accId = ref.accountId;
    final itemId = ref.itemId;
    if (accId.isEmpty || itemId.isEmpty) return null;

    final accs = await EmbyStore.load();
    EmbyAccount? acc;
    for (final a in accs) {
      if (a.id == accId) {
        acc = a;
        break;
      }
    }
    if (acc == null) return null;
    final client = EmbyClient(acc);

    final parentId = await client.getItemParentId(itemId).timeout(
          const Duration(seconds: 6),
          onTimeout: () => null,
        );
    if (parentId == null || parentId.trim().isEmpty) return null;

    final children = await client.listChildren(parentId: parentId).timeout(
          const Duration(seconds: 10),
          onTimeout: () => <EmbyItem>[],
        );
    if (children.isEmpty) return null;

    bool isPlayableVideo(EmbyItem it) {
      final mt = (it.mediaType ?? '').toLowerCase();
      if (mt == 'video') return true;
      final t = it.type.toLowerCase();
      return t == 'movie' || t == 'episode' || t == 'video';
    }

    final vids =
        children.where((e) => !e.isFolder && isPlayableVideo(e)).toList();
    if (vids.length <= 1) return null;

    vids.sort(
        (a, b) => _naturalCompare(a.name.toLowerCase(), b.name.toLowerCase()));

    final srcs = <String>[];
    var idx = 0;
    for (var i = 0; i < vids.length; i++) {
      final it = vids[i];
      final nm = it.name.trim();
      final src = (it.id == itemId)
          ? currentSource
          : (nm.isEmpty
              ? 'emby://$accId/item:${it.id}'
              : 'emby://$accId/item:${it.id}?name=${Uri.encodeComponent(nm)}');
      srcs.add(src);
      if (it.id == itemId) idx = i;
    }
    return _ExpandedPlaylist(sources: srcs, index: idx);
  }

  Future<void> _ensureCatalogSourcesReady({bool force = false}) async {
    if (!_hasPlaylist) return;
    if (_sourcesExpanding) return;
    if (!force && (_sources.length > 1 || _sourcesExpandedOnce)) return;

    _sourcesExpanding = true;
    try {
      final cur = _currentPath;

      _ExpandedPlaylist? expanded;
      if (isWebDavSource(cur)) {
        expanded = await _expandPlaylistFromWebDavDir(cur);
      } else if (isEmbySource(cur)) {
        expanded = await _expandPlaylistFromEmbyDir(cur);
      } else {
        expanded = await _expandPlaylistFromLocalDir(cur);
      }

      if (expanded == null || expanded.sources.length <= 1) {
        _sourcesExpandedOnce = true;
      } else {
        final oldPos = _player.state.position;
        final wasPlaying = _player.state.playing;

        _sources = expanded.sources;
        _index = expanded.index.clamp(0, _sources.length - 1);
        _refreshCatalogExpansionState();

        final medias = await _buildMedias();
        await _player.open(Playlist(medias, index: _index), play: wasPlaying);
        _player.setRate(_rate);
        _player.setVolume(_volume);
        if (oldPos > Duration.zero) {
          await _player.seek(oldPos);
        }
        _autoLoadSrtIfAny();
        _armHistoryRecordForCurrent();
        _sourcesExpandedOnce = true;
      }
    } catch (e) {
      _sourcesExpandedOnce = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录加载失败：${redactSensitiveText(e.toString())}')),
      );
    } finally {
      _sourcesExpanding = false;
    }
  }

  static const Set<String> _videoExts = <String>{
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    'vob',
    'ogv',
    'f4v',
    'ts',
    'm2ts',
    'mts',
    '3gp',
    'rm',
    'rmvb',
  };

  bool _looksLikeVideoFile(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) return false;
    return _videoExts.contains(ext);
  }

  int _naturalCompare(String a, String b) {
    var aIdx = 0, bIdx = 0;
    final aLen = a.length, bLen = b.length;
    bool isDigit(String c) =>
        c.length == 1 && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

    while (aIdx < aLen && bIdx < bLen) {
      final aChar = a[aIdx];
      final bChar = b[bIdx];

      if (isDigit(aChar) && isDigit(bChar)) {
        var aNum = '', bNum = '';
        while (aIdx < aLen && isDigit(a[aIdx])) {
          aNum += a[aIdx++];
        }
        while (bIdx < bLen && isDigit(b[bIdx])) {
          bNum += b[bIdx++];
        }
        final aVal = int.tryParse(aNum) ?? 0;
        final bVal = int.tryParse(bNum) ?? 0;
        if (aVal != bVal) return aVal.compareTo(bVal);
        final z = aNum.length.compareTo(bNum.length);
        if (z != 0) return z;
      } else {
        if (aChar != bChar) return aChar.compareTo(bChar);
        aIdx++;
        bIdx++;
      }
    }
    return (aLen - aIdx).compareTo(bLen - bIdx);
  }

  String _parentRelPath(String relPath) {
    final s = relPath.trim();
    final idx = s.lastIndexOf('/');
    if (idx <= 0) return '';
    return s.substring(0, idx + 1);
  }

  String _buildWebDavSource(String accountId, String relDecoded) {
    return buildWebDavSource(accountId, relDecoded);
  }

  _WebDavRef? _parseWebDavSourceForListing(String source) {
    final parsed = parseWebDavSource(source);
    if (parsed == null) return null;
    return _WebDavRef(accountId: parsed.accountId, relPath: parsed.relPath);
  }

  Future<List<_WebDavListItem>> _webDavPropfindList({
    required String baseUrl,
    required String username,
    required String password,
    required String relFolder,
  }) async {
    final client = HttpClientFactory.createForeground(
      connectionTimeout: const Duration(seconds: 15),
    );
    try {
      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final folderEncoded = encodePathPreserveSlash(relFolder);
      final url =
          Uri.parse(base).resolve(folderEncoded.isEmpty ? '' : folderEncoded);

      final token = base64Encode(utf8.encode('$username:$password'));
      final req = await NetworkRunner.run(
        () => client.openUrl('PROPFIND', url),
        label: 'player-catalog-propfind-open',
      );
      req.followRedirects = true;
      req.headers.set('Depth', '1');
      req.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/xml; charset="utf-8"');

      const body = '''<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype />
    <D:displayname />
    <D:getcontentlength />
    <D:getlastmodified />
  </D:prop>
</D:propfind>
''';
      req.add(utf8.encode(body));
      final resp = await NetworkRunner.run(
        () => req.close(),
        label: 'player-catalog-propfind-close',
      );
      final text = await utf8.decodeStream(resp);
      if (resp.statusCode != 207 && resp.statusCode != 200) {
        throw Exception('WebDAV PROPFIND 失败：HTTP ${resp.statusCode}');
      }

      final basePath = () {
        final p0 = Uri.parse(base).path;
        if (p0.isEmpty) return '/';
        return p0.endsWith('/') ? p0 : '$p0/';
      }();

      return _parseWebDavPropfind(text, basePath: basePath);
    } finally {
      client.close(force: true);
    }
  }

  List<_WebDavListItem> _parseWebDavPropfind(String xmlText,
      {required String basePath}) {
    final items = <_WebDavListItem>[];
    final respRe = RegExp(r'<[^>]*:response\b[\s\S]*?<\/[^>]*:response>',
        caseSensitive: false);
    final hrefRe =
        RegExp(r'<[^>]*:href>([\s\S]*?)<\/[^>]*:href>', caseSensitive: false);
    final displayRe = RegExp(
        r'<[^>]*:displayname>([\s\S]*?)<\/[^>]*:displayname>',
        caseSensitive: false);
    final lenRe = RegExp(
        r'<[^>]*:getcontentlength>([0-9]+)<\/[^>]*:getcontentlength>',
        caseSensitive: false);
    final lmRe = RegExp(
        r'<[^>]*:getlastmodified>([\s\S]*?)<\/[^>]*:getlastmodified>',
        caseSensitive: false);
    final collRe = RegExp(r'<[^>]*:collection\s*\/?>', caseSensitive: false);

    for (final m in respRe.allMatches(xmlText)) {
      final block = m.group(0) ?? '';
      final href = hrefRe.firstMatch(block)?.group(1)?.trim();
      if (href == null || href.isEmpty) continue;

      Uri hrefUri;
      try {
        hrefUri = Uri.parse(href);
      } catch (_) {
        continue;
      }
      final path = hrefUri.path;
      if (path.isEmpty) continue;
      if (!path.startsWith(basePath)) continue;
      var rel = path.substring(basePath.length);
      if (rel.isEmpty) continue;
      if (rel.startsWith('/')) rel = rel.substring(1);
      try {
        rel = Uri.decodeFull(rel);
      } catch (_) {}
      final isDir = path.endsWith('/') || collRe.hasMatch(block);

      final dispRaw = displayRe.firstMatch(block)?.group(1)?.trim() ?? '';
      var name = dispRaw;
      if (name.isEmpty) {
        final segs = path.split('/').where((s) => s.isNotEmpty).toList();
        name = segs.isEmpty ? rel : segs.last;
      }
      try {
        name = Uri.decodeFull(name);
      } catch (_) {}

      final sizeStr = lenRe.firstMatch(block)?.group(1);
      final sz = int.tryParse(sizeStr ?? '') ?? 0;
      DateTime? lm;
      final lmStr = lmRe.firstMatch(block)?.group(1)?.trim();
      if (lmStr != null && lmStr.isNotEmpty) {
        try {
          lm = HttpDate.parse(lmStr);
        } catch (_) {}
      }

      items.add(_WebDavListItem(
        name: name,
        relPath: rel,
        isDir: isDir,
        size: sz,
        modified: lm,
      ));
    }
    return items;
  }

  _EmbyRef? _parseEmbySourceRef(String source) {
    final parsed = parseEmbySourceRef(source);
    if (parsed == null) return null;
    return _EmbyRef(accountId: parsed.accountId, itemId: parsed.itemId);
  }
}
