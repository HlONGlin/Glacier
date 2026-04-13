part of '../pages.dart';

extension _FolderDetailCoverResolution on _FolderDetailPageState {
  bool _isMediaName(String name) =>
      isPageImageName(name) || isPageVideoName(name);

  Future<_CoverInfo?> _findCoverInDir(String dirPath) async {
    const maxScan = 2500;
    var scanned = 0;

    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return null;

      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        scanned++;
        if (scanned > maxScan) break;

        if (ent is File) {
          final name = ent.path.split(Platform.pathSeparator).last;
          if (!_isMediaName(name)) continue;

          final isVideo = isPageVideoName(name);
          return _CoverInfo.local(ent.path, isVideo: isVideo);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<_CoverInfo?> _findCoverInWebDavDir(
      String accountId, String relPath) async {
    const maxScan = 2500;
    var scanned = 0;
    try {
      final accs = await loadPageWebDavAccountsMap();
      final acc = accs[accountId];
      if (acc == null) return null;
      final client = WebDavClient(acc);

      final queue = <String>[relPath];
      while (queue.isNotEmpty && scanned < maxScan) {
        final curRel = queue.removeAt(0);
        final list = await client.list(curRel);
        for (final item in list) {
          scanned++;
          if (scanned > maxScan) break;
          if (item.isDir) {
            var childRel = item.relPath;
            if (!childRel.endsWith('/')) childRel = '$childRel/';
            queue.add(childRel);
          } else if (_isMediaName(item.name)) {
            return _CoverInfo.webdav(
              wdAccountId: accountId,
              wdRelPath: item.relPath,
              wdHref: item.href,
              isVideo: isPageVideoName(item.name),
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<_CoverInfo?> _getFolderCoverInfo(Entry e) async {
    if (!e.isDir) return null;
    final key = _folderCoverCacheKey(e);

    final cache = _folderCoverCache;
    final cached =
        (cache == null || key.isEmpty) ? null : cache.getIfFresh(key);
    if (cached != null) return cached;

    final fut = _dirCoverJobs.putIfAbsent(key, () async {
      _CoverInfo? info;

      if (e.isEmby) {
        final accMap = await _loadEmbyAccountsMap();
        final a = accMap[e.embyAccountId ?? ''];
        if (a != null && (e.embyItemId ?? '').trim().isNotEmpty) {
          try {
            final client = EmbyClient(a);
            final auto = await client.pickAutoFolderCoverUrl(
              folderId: e.embyItemId!.trim(),
              maxWidth: 420,
              quality: 85,
              fallbackToVideo: true,
            );
            final fallback = (e.embyCoverUrl ?? '').trim();
            final useUrl =
                (auto ?? '').trim().isNotEmpty ? auto!.trim() : fallback;
            if (useUrl.isNotEmpty) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: useUrl);
            }
          } catch (_) {
            final url = (e.embyCoverUrl ?? '').trim();
            if (url.isNotEmpty) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: url);
            }
          }
        } else {
          final url = (e.embyCoverUrl ?? '').trim();
          if (url.isNotEmpty) {
            info = _CoverInfo.emby(
                embyAccountId: e.embyAccountId ?? '', embyCoverUrl: url);
          }
        }
      } else if (e.isWebDav) {
        final accId = e.wdAccountId;
        var rel = e.wdRelPath;
        if (accId != null && rel != null) {
          rel = _normWebDavDirRel(rel);
          info = await _findCoverInWebDavDir(accId, rel);
        }
      } else {
        final dir = (e.localPath ?? '').trim();
        if (dir.isNotEmpty) info = await _findCoverInDir(dir);
      }

      if (info != null && cache != null && key.isNotEmpty) {
        cache.put(key, info);
      }
      return info;
    });

    try {
      return await fut;
    } finally {
      _dirCoverJobs.remove(key);
    }
  }
}
