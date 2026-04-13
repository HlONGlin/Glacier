part of '../pages.dart';

extension _FolderScopeSearchMethods on _FolderDetailPageState {
  Future<void> _loadSearchScopeSettings() async {
    if (_searchScopeSettingsLoaded) return;
    try {
      final values = await Future.wait<Object?>([
        AppSettings.getFolderSearchScope(),
        AppSettings.getFolderSearchSingleCollectionId(),
      ]);
      final scopeRaw = values[0] as String;
      final singleId = values[1] as String?;
      if (!mounted) return;
      switch (scopeRaw) {
        case 'currentDirectory':
          _searchScope = FolderSearchScope.currentDirectory;
          break;
        case 'allCollections':
          _searchScope = FolderSearchScope.allCollections;
          break;
        case 'singleCollection':
          _searchScope = FolderSearchScope.singleCollection;
          break;
        case 'currentCollection':
        default:
          _searchScope = FolderSearchScope.currentCollection;
          break;
      }
      final sid = (singleId ?? '').trim();
      if (sid.isNotEmpty) {
        _singleSearchCollectionId = sid;
      } else {
        _singleSearchCollectionId ??= widget.collection.id;
      }
      _searchScopeSettingsLoaded = true;
      _refreshFolderDetailState();
    } catch (_) {
      if (!mounted) return;
      _searchScope = FolderSearchScope.currentCollection;
      _singleSearchCollectionId ??= widget.collection.id;
      _searchScopeSettingsLoaded = true;
      _refreshFolderDetailState();
    }
  }

  Future<void> _persistSearchScopeSettings() async {
    await AppSettings.setFolderSearchScope(_searchScope.name);
    final sid = (_singleSearchCollectionId ?? '').trim();
    if (sid.isEmpty) {
      await AppSettings.setFolderSearchSingleCollectionId(null);
    } else {
      await AppSettings.setFolderSearchSingleCollectionId(sid);
    }
    _searchScopeSettingsLoaded = true;
  }

  FavoriteCollection? _collectionById(String? id) {
    final key = (id ?? '').trim();
    if (key.isEmpty) return null;
    if (widget.collection.id == key) return widget.collection;
    for (final c in _searchCollections) {
      if (c.id == key) return c;
    }
    return null;
  }

  List<FavoriteCollection> _allSearchCollections() {
    final out = <FavoriteCollection>[widget.collection];
    for (final c in _searchCollections) {
      if (out.any((x) => x.id == c.id)) continue;
      out.add(c);
    }
    return out;
  }

  Future<void> _ensureSearchCollectionsLoaded() async {
    if (_searchCollectionsLoaded) return;
    try {
      final list = await FavoriteStore.load();
      if (!mounted) return;
      _searchCollections = list;
      _searchCollectionsLoaded = true;
      _singleSearchCollectionId ??= widget.collection.id;
      _refreshFolderDetailState();
    } catch (_) {
      if (!mounted) return;
      _searchCollectionsLoaded = true;
      _singleSearchCollectionId ??= widget.collection.id;
      _refreshFolderDetailState();
    }
  }

  String _searchPathHint(Entry e) {
    if (e.isWebDav) {
      final rel = (e.wdRelPath ?? '').trim();
      if (rel.isEmpty) return 'WebDAV';
      final d = p.dirname(rel);
      if (d == '.' || d == '/') return 'WebDAV 根目录';
      return 'WebDAV/$d';
    }
    if (e.isEmby) return 'Emby';
    final lp = (e.localPath ?? '').trim();
    if (lp.isEmpty) return '本地';
    final d = p.dirname(lp);
    if (d == '.' || d.trim().isEmpty) return '本地';
    final base = p.basename(d).trim();
    return base.isEmpty ? d : base;
  }

  Entry _cloneEntry(
    Entry e, {
    String? origin,
    String? searchCollectionId,
    String? searchCollectionName,
  }) {
    return Entry(
      isDir: e.isDir,
      name: e.name,
      size: e.size,
      modified: e.modified,
      typeKey: e.typeKey,
      origin: origin ?? e.origin,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      searchCollectionId: searchCollectionId ?? e.searchCollectionId,
      searchCollectionName: searchCollectionName ?? e.searchCollectionName,
    );
  }

  Entry _asSearchResult(FavoriteCollection c, Entry e) {
    final cName = c.name.trim().isEmpty ? '未命名收藏夹' : c.name.trim();
    final hint = _searchPathHint(e);
    final label = hint.trim().isEmpty ? cName : '$cName · $hint';
    return _cloneEntry(
      e,
      origin: label,
      searchCollectionId: c.id,
      searchCollectionName: cName,
    );
  }

  String _scopeSearchCacheKey(String qLower, List<FavoriteCollection> cols) {
    final scope = _searchScope.name;
    final ids = cols.map((e) => e.id).join(',');
    return '$scope|$_singleSearchCollectionId|$ids|$qLower';
  }

  void _clearScopeSearchState({bool clearCache = false}) {
    _scopeSearchDebounce?.cancel();
    _scopeSearchToken++;
    _scopeSearching = false;
    _scopeSearchError = null;
    _scopeSearchRaw = const <Entry>[];
    if (clearCache) _scopeSearchCache.clear();
  }

  void _scheduleScopeSearch({bool immediate = false}) {
    _scopeSearchDebounce?.cancel();
    if (!_usingScopeSearch) {
      if (_scopeSearching ||
          _scopeSearchError != null ||
          _scopeSearchRaw.isNotEmpty) {
        _clearScopeSearchState();
        _refreshFolderDetailState();
      }
      return;
    }
    _scopeSearching = true;
    _scopeSearchError = null;
    _scopeSearchRaw = const <Entry>[];
    _refreshFolderDetailState();
    void run() {
      _runScopeSearchNow();
    }

    if (immediate) {
      run();
    } else {
      _scopeSearchDebounce = Timer(const Duration(milliseconds: 260), run);
    }
  }

  void _onSearchQueryChanged(String v) {
    _q = v;
    _refreshFolderDetailState();
    _scheduleScopeSearch();
  }

  Future<List<Entry>> _loadRootEntriesForCollection(
    FavoriteCollection collection, {
    String searchQuery = '',
  }) async {
    final out = <Entry>[];
    final q = searchQuery.trim();
    for (final src in collection.sources) {
      try {
        if (isPageEmbySource(src)) {
          final ref = parsePageEmbySource(src);
          if (ref == null) continue;
          if (q.isNotEmpty) {
            out.addAll(await _searchEmbyEntriesBySource(ref, q));
            continue;
          }
          final path = ref.path.trim().isEmpty ? 'favorites' : ref.path.trim();
          out.addAll(await _loadEmby(ref.accountId, path));
          continue;
        }

        if (isPageWebDavSource(src)) {
          final ref = parsePageWebDavSource(src);
          if (ref == null) continue;
          if (!ref.isDir) {
            final fileName = p.basename(ref.relPath);
            out.add(
              Entry(
                isDir: false,
                name: fileName.isEmpty ? '文件' : fileName,
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: p.extension(fileName).toLowerCase().isEmpty
                    ? 'file'
                    : p.extension(fileName).toLowerCase(),
                origin: null,
                wdAccountId: ref.accountId,
                wdRelPath: ref.relPath,
                wdHref: '',
              ),
            );
            continue;
          }
          var rel = ref.relPath.trim();
          if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
          out.addAll(await _loadWebDavDir(ref.accountId, rel));
          continue;
        }

        final folder = src.trim();
        if (folder.isEmpty) continue;
        out.addAll(await _loadLocalDir(folder));
      } catch (_) {}
    }
    return out;
  }

  Entry _entryFromEmbySearchItem({
    required EmbyAccount account,
    required EmbyClient client,
    required EmbyItem item,
  }) {
    final isDir = item.isFolder || _embyTypeIsDir(item.type);
    final isImg = !isDir && _embyTypeIsImage(item.type);
    final thumbWidth = _active.viewMode == ViewMode.grid ? 420 : 220;
    return Entry(
      isDir: isDir,
      name: item.name.isEmpty ? '未命名' : item.name,
      size: isDir ? 0 : item.size,
      modified: item.dateCreated ??
          item.dateModified ??
          DateTime.fromMillisecondsSinceEpoch(0),
      typeKey: isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
      origin: null,
      embyAccountId: account.id,
      embyItemId: item.id,
      embyCoverUrl: client.bestCoverUrl(item, maxWidth: thumbWidth),
    );
  }

  Future<List<Entry>> _searchEmbyEntriesByTraversalFallback({
    required EmbyAccount account,
    required EmbyClient client,
    required String sourcePath,
    required String query,
  }) async {
    final qLower = query.trim().toLowerCase();
    if (qLower.isEmpty) return const <Entry>[];

    final out = <Entry>[];
    final seenItemIds = <String>{};
    final dirQueue = <String>[];
    var cursor = 0;
    final maxVisit = (_FolderDetailPageState._maxScopeSearchResults * 10)
        .clamp(400, 5000)
        .toInt();

    void pushItem(EmbyItem item) {
      final isDirCandidate = item.isFolder || _embyTypeIsDir(item.type);
      if (!isDirCandidate) return;

      final id = item.id.trim();
      if (id.isEmpty || !seenItemIds.add(id)) return;
      final e = _entryFromEmbySearchItem(
        account: account,
        client: client,
        item: item,
      );
      if (e.isDir &&
          e.name.toLowerCase().contains(qLower) &&
          out.length < _FolderDetailPageState._maxScopeSearchResults) {
        out.add(e);
      }
      if (e.isDir && seenItemIds.length < maxVisit) {
        dirQueue.add(id);
      }
    }

    Future<void> seedQueue() async {
      if (sourcePath.startsWith('view:')) {
        final pid = sourcePath.substring('view:'.length).trim();
        if (pid.isEmpty) return;
        final root = await client.listChildren(parentId: pid);
        for (final it in root) {
          pushItem(it);
        }
        return;
      }

      if (sourcePath == 'favorites') {
        final fav = await client.listFavorites();
        for (final it in fav) {
          pushItem(it);
        }
        final views = await client.listViews();
        for (final it in views) {
          pushItem(it);
        }
        return;
      }

      final firstLevel = await _loadEmby(account.id, sourcePath);
      for (final e in firstLevel) {
        if (e.isLoading ||
            e.typeKey == 'hint' ||
            e.typeKey == 'emby_login' ||
            e.typeKey == 'emby_empty') {
          continue;
        }
        final id = (e.embyItemId ?? '').trim();
        if (e.isDir && id.isNotEmpty) {
          seenItemIds.add(id);
        }
        if (e.isDir &&
            e.name.toLowerCase().contains(qLower) &&
            out.length < _FolderDetailPageState._maxScopeSearchResults) {
          out.add(e);
        }
        if (e.isDir && id.isNotEmpty && seenItemIds.length < maxVisit) {
          dirQueue.add(id);
        }
      }
    }

    await seedQueue();

    while (cursor < dirQueue.length &&
        out.length < _FolderDetailPageState._maxScopeSearchResults &&
        seenItemIds.length < maxVisit) {
      final parentId = dirQueue[cursor];
      cursor++;

      List<EmbyItem> children;
      try {
        children = await client.listChildren(parentId: parentId);
      } catch (_) {
        continue;
      }

      for (final it in children) {
        pushItem(it);
        if (out.length >= _FolderDetailPageState._maxScopeSearchResults) break;
      }
    }

    return out;
  }

  Future<List<Entry>> _searchEmbyEntriesBySource(
      _EmbyRef ref, String query) async {
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[ref.accountId];
    if (a == null) return const <Entry>[];

    final client = EmbyClient(a);
    final sourcePath = ref.path.trim().isEmpty ? 'favorites' : ref.path.trim();
    String? parentId;

    if (sourcePath.startsWith('view:')) {
      final pid = sourcePath.substring('view:'.length).trim();
      if (pid.isEmpty) return const <Entry>[];
      parentId = pid;
    } else if (sourcePath == 'favorites') {
      parentId = null;
    } else {
      final qLower = query.trim().toLowerCase();
      final fallback = await _loadEmby(a.id, sourcePath);
      return fallback
          .where((e) => e.isDir && e.name.toLowerCase().contains(qLower))
          .toList(growable: false);
    }

    try {
      final items = await client.searchItems(
        query: query,
        parentId: parentId,
        recursive: true,
        limit: _FolderDetailPageState._maxScopeSearchResults,
      );
      final dirs = items
          .map((it) => _entryFromEmbySearchItem(
                account: a,
                client: client,
                item: it,
              ))
          .where((e) => e.isDir)
          .toList(growable: false);
      if (dirs.isNotEmpty) return dirs;
    } catch (_) {}
    return _searchEmbyEntriesByTraversalFallback(
      account: a,
      client: client,
      sourcePath: sourcePath,
      query: query,
    );
  }

  Future<void> _runScopeSearchNow() async {
    final qRaw = _q.trim();
    final qLower = qRaw.toLowerCase();
    if (!_usingScopeSearch || qLower.isEmpty) {
      if (!mounted) return;
      _clearScopeSearchState();
      _refreshFolderDetailState();
      return;
    }

    List<FavoriteCollection> targets = <FavoriteCollection>[];
    switch (_searchScope) {
      case FolderSearchScope.currentDirectory:
        targets = <FavoriteCollection>[];
        break;
      case FolderSearchScope.currentCollection:
        targets = <FavoriteCollection>[widget.collection];
        break;
      case FolderSearchScope.allCollections:
        await _ensureSearchCollectionsLoaded();
        targets = _allSearchCollections();
        break;
      case FolderSearchScope.singleCollection:
        await _ensureSearchCollectionsLoaded();
        var selected = _collectionById(_singleSearchCollectionId);
        if (selected == null) {
          selected = widget.collection;
          _singleSearchCollectionId = widget.collection.id;
          _persistSearchScopeSettings();
        }
        targets = <FavoriteCollection>[selected];
        break;
    }

    if (targets.isEmpty) {
      if (!mounted) return;
      _scopeSearching = false;
      _scopeSearchError = null;
      _scopeSearchRaw = const <Entry>[];
      _refreshFolderDetailState();
      return;
    }

    final token = ++_scopeSearchToken;
    final cacheKey = _scopeSearchCacheKey(qLower, targets);
    final cached = _scopeSearchCache[cacheKey];
    if (cached != null) {
      if (!mounted || token != _scopeSearchToken) return;
      _scopeSearching = false;
      _scopeSearchError = null;
      _scopeSearchRaw = cached;
      _refreshFolderDetailState();
      return;
    }

    try {
      final out = <Entry>[];
      final seen = <String>{};
      for (final c in targets) {
        if (out.length >= _FolderDetailPageState._maxScopeSearchResults) break;
        final list = await _loadRootEntriesForCollection(c, searchQuery: qRaw);
        for (final e in list) {
          if (out.length >= _FolderDetailPageState._maxScopeSearchResults) {
            break;
          }
          final name = e.name.toLowerCase();
          final matchedByName = name.contains(qLower);
          if (!matchedByName && !(e.isEmby && qRaw.isNotEmpty)) continue;
          if (e.isLoading ||
              e.typeKey == 'hint' ||
              e.typeKey == 'wd_error' ||
              e.typeKey == 'emby_login' ||
              e.typeKey == 'emby_empty') {
            continue;
          }
          final key = '${c.id}|${e.displayPath}|${e.name}|${e.typeKey}';
          if (!seen.add(key)) continue;
          out.add(_asSearchResult(c, e));
        }
      }
      if (!mounted || token != _scopeSearchToken) return;
      _scopeSearchCache[cacheKey] = out;
      _scopeSearching = false;
      _scopeSearchError = null;
      _scopeSearchRaw = out;
      _refreshFolderDetailState();
    } catch (e) {
      if (!mounted || token != _scopeSearchToken) return;
      _scopeSearching = false;
      _scopeSearchError = e;
      _scopeSearchRaw = const <Entry>[];
      _refreshFolderDetailState();
    }
  }
}
