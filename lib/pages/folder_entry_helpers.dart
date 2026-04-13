part of '../pages.dart';

extension _FolderEntryHelperMethods on _FolderDetailPageState {
  TagKind _tagKindForEntry(Entry e) {
    if (e.isDir) return TagKind.other;
    if (e.isEmby) {
      if (e.typeKey == 'emby_image') return TagKind.image;
      if (e.typeKey == 'emby_video') return TagKind.video;
    }
    return TagKindX.fromFilename(e.name);
  }

  String _entrySelectionKey(Entry e) {
    if (!_isEntrySelectable(e)) return '';
    if (e.isEmby || e.isWebDav) {
      return tagKeyForEntry(
        isWebDav: e.isWebDav,
        isEmby: e.isEmby,
        localPath: e.localPath,
        wdAccountId: e.wdAccountId,
        wdRelPath: e.wdRelPath,
        wdHref: e.wdHref,
        embyAccountId: e.embyAccountId,
        embyItemId: e.embyItemId,
      );
    }
    return (e.localPath ?? '').trim();
  }

  bool _isEntrySelectable(Entry e) {
    if (e.isLoading) return false;
    if (e.typeKey == 'hint' ||
        e.typeKey == 'emby_login' ||
        e.typeKey == 'emby_empty' ||
        e.typeKey == 'wd_error') {
      return false;
    }
    return _entrySelectionKeyRaw(e).isNotEmpty;
  }

  String _entrySelectionKeyRaw(Entry e) {
    if (e.isEmby || e.isWebDav) {
      return tagKeyForEntry(
        isWebDav: e.isWebDav,
        isEmby: e.isEmby,
        localPath: e.localPath,
        wdAccountId: e.wdAccountId,
        wdRelPath: e.wdRelPath,
        wdHref: e.wdHref,
        embyAccountId: e.embyAccountId,
        embyItemId: e.embyItemId,
      );
    }
    return (e.localPath ?? '').trim();
  }

  String _imageSourceKeyForEntry(Entry e) => _entrySelectionKeyRaw(e);

  String _webDavImageSourceKey({
    required String accountId,
    required String relPath,
    String? href,
  }) {
    return tagKeyForEntry(
      isWebDav: true,
      isEmby: false,
      localPath: null,
      wdAccountId: accountId,
      wdRelPath: relPath,
      wdHref: href,
      embyAccountId: null,
      embyItemId: null,
    );
  }

  GlobalKey _entryAnchorKeyForSource(String sourceKey) {
    return _entryAnchorKeys.putIfAbsent(
      sourceKey,
      () => GlobalKey(debugLabel: 'entry_anchor_${_entryAnchorKeys.length}'),
    );
  }

  Widget _wrapWithEntryAnchor(Entry e, Widget child) {
    final sourceKey = _imageSourceKeyForEntry(e).trim();
    if (sourceKey.isEmpty) return child;
    return KeyedSubtree(key: _entryAnchorKeyForSource(sourceKey), child: child);
  }

  String _folderKeyForCtx(NavCtx ctx) {
    if (ctx.kind == CtxKind.local) return (ctx.localDir ?? '').trim();
    if (ctx.kind == CtxKind.webdav) {
      return buildWebDavSource(ctx.wdAccountId ?? '', ctx.wdRel);
    }
    return '';
  }

  String _folderKeyForEntry(Entry e) {
    if (!e.isDir) return '';
    if (!e.isWebDav) return (e.localPath ?? '').trim();
    var rel = (e.wdRelPath ?? '').trim();
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
    final base = buildWebDavSource(e.wdAccountId ?? '', rel);
    return base.endsWith('/') ? base : '$base/';
  }

  String _normWebDavDirRel(String rel) {
    var r = rel.trim();
    if (r.startsWith('/')) r = r.substring(1);
    if (r.isNotEmpty && !r.endsWith('/')) r = '$r/';
    return r;
  }

  String _folderCoverCacheKey(Entry e) {
    if (!e.isDir) return '';
    if (e.isEmby) {
      return buildEmbySource(
          e.embyAccountId ?? '', 'item:${e.embyItemId ?? ''}');
    }
    if (e.isWebDav) {
      final rel = _normWebDavDirRel(e.wdRelPath ?? '');
      final base = buildWebDavSource(e.wdAccountId ?? '', rel);
      return base.endsWith('/') ? base : '$base/';
    }
    return 'local://${(e.localPath ?? '').trim()}';
  }

  int _estimateLocalMediaCount(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      final ents = d.listSync(followLinks: false);
      var n = 0;
      for (final it in ents) {
        if (it is File) {
          final name = p.basename(it.path);
          if (isPageImageName(name) || isPageVideoName(name)) n++;
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  void _prefillSkeletonForFolder(Entry folder) {
    final key = _folderKeyForEntry(folder);
    var n = 0;
    if (!folder.isWebDav) {
      final dir = folder.localPath;
      if (dir != null) n = _estimateLocalMediaCount(dir);
    }
    if (n <= 0) {
      final cached = _folderMediaCountCache[key];
      n = cached ?? 24;
    }
    n = n.clamp(0, 120);
    if (n <= 0) return;

    _raw = List.generate(n, (i) => Entry.loading(i));
    _loading = false;
    _refreshFolderDetailState();
  }

  void _updateFolderCountCacheFromList(NavCtx ctx, List<Entry> list) {
    final key = _folderKeyForCtx(ctx);
    if (key.trim().isEmpty) return;
    final n = list
        .where((e) =>
            !e.isDir && (isPageImageName(e.name) || isPageVideoName(e.name)))
        .length;
    if (n <= 0) return;
    _folderMediaCountCache[key] = n;
    _saveFolderMediaCountCache();
  }
}
