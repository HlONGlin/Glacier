part of '../pages.dart';

class _FolderDetailPageState extends State<_FolderDetailPageHost> {
  late final folder_detail_controller.FolderDetailController _controller;
  final Map<String, Future<_CoverInfo?>> _dirCoverJobs =
      <String, Future<_CoverInfo?>>{};

  // ✅ Folder cover result cache (memory + SharedPreferences + TTL)
  _FolderCoverCache? _folderCoverCache;

  // 🔥 1. 新增：滚动控制器和位置记录
  final ScrollController _scrollController = ScrollController();
  final Map<int, double> _scrollOffsets = {};

  final List<NavCtx> _stack = const [NavCtx.root()].toList();
  int _deferredInitialNavToken = 0;
  bool _contentHasAppeared = false;
  int _previewPrefetchEpoch = 0;
  bool _previewWarmupRunning = false;
  int _postLoadWorkEpoch = 0;
  int _embyDirCoverRefreshEpoch = 0;
  bool _loading = true;
  List<Entry> _raw = [];

  /// Emby 文件大小补全缓存（仅内存）。
  ///
  /// ✅ 背景：部分 Emby 服务端/版本在列表接口不返回 MediaSources（或返回不完整），
  /// 导致 size=0，从而“按大小排序”看起来不生效。
  ///
  /// 方案：当用户选择“按大小排序”且当前是 Emby 目录时，按需对 size=0 的条目做补全。
  /// - 只对前 N 个可见/候选条目补全，避免一次性请求过多。
  /// - 结果写入内存缓存，避免来回切换排序重复请求。
  final Map<String, int> _embySizeCache = <String, int>{};
  bool _embySizeHydrating = false;

  // Folder media count cache (for skeleton prefill). Key: localPath or webdav://<acc>/<rel>/
  final Map<String, int> _folderMediaCountCache = <String, int>{};
  bool _folderMediaCountLoaded = false;

  String get _q => _controller.query;
  set _q(String value) => _controller.query = value;

  bool get _searchExpanded => _controller.searchExpanded;
  set _searchExpanded(bool value) => _controller.searchExpanded = value;
  FolderSearchScope _searchScope = FolderSearchScope.currentCollection;
  String? _singleSearchCollectionId;
  List<FavoriteCollection> _searchCollections = const <FavoriteCollection>[];
  bool _searchCollectionsLoaded = false;
  bool _searchScopeSettingsLoaded = false;
  bool _scopeSearching = false;
  Object? _scopeSearchError;
  List<Entry> get _scopeSearchRaw => _controller.scopeSearchRaw;
  set _scopeSearchRaw(List<Entry> value) => _controller.scopeSearchRaw = value;
  final Map<String, List<Entry>> _scopeSearchCache = <String, List<Entry>>{};
  Timer? _scopeSearchDebounce;
  int _scopeSearchToken = 0;
  static const int _maxScopeSearchResults = 400;
  String? get _selectedTagId => _controller.selectedTagId;
  set _selectedTagId(String? value) => _controller.selectedTagId = value;

  bool get _usingScopeSearch =>
      _searchScope != FolderSearchScope.currentDirectory &&
      _q.trim().isNotEmpty;

  bool _tagEnabled = true; // 由设置控制，避免用户不需要时被打扰
  bool get _selectionMode => _controller.selectionMode;
  set _selectionMode(bool value) => _controller.selectionMode = value;

  Set<String> get _selectedEntryKeys => _controller.selectedEntryKeys;
  final Map<String, GlobalKey> _entryAnchorKeys = <String, GlobalKey>{};

  Future<void> _openTagForEntry(Entry e) async {
    if (!_tagEnabled) return;

    final key = tagKeyForEntry(
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
    );
    if (key.trim().isEmpty) return;

    final meta = TagTargetMeta(
      key: key,
      name: e.name,
      kind: _tagKindForEntry(e),
      isDir: e.isDir,
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      localPath: e.localPath,
    );

    await TagUI.showTagPicker(context,
        target: meta, title: e.isDir ? '标记目录Tag' : '标记Tag');

    if (!mounted) return;
    setState(() {}); // 让 TagChipsBar / 列表过滤即时刷新
  }

  void _syncEntryAnchorKeys(List<Entry> visibleEntries) {
    final aliveKeys = visibleEntries
        .map(_imageSourceKeyForEntry)
        .where((k) => k.trim().isNotEmpty)
        .toSet();
    _entryAnchorKeys.removeWhere((k, _) => !aliveKeys.contains(k));
  }

  int _gridCrossAxisCount({
    required double viewportWidth,
    required double horizontalPadding,
    required double maxCrossAxisExtent,
    required double crossAxisSpacing,
  }) {
    final usableWidth =
        (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
    int count = ((usableWidth + crossAxisSpacing) /
            (maxCrossAxisExtent + crossAxisSpacing))
        .floor();
    if (count < 1) count = 1;
    return count;
  }

  double _estimateScrollOffsetForIndex(int index) {
    final viewportWidth = MediaQuery.of(context).size.width;
    if (index <= 0) return 0;
    switch (_active.viewMode) {
      case ViewMode.list:
        const topPadding = 8.0;
        const estimatedItemExtent = 88.0;
        return topPadding + index * estimatedItemExtent;
      case ViewMode.gallery:
        const horizontalPadding = 12.0;
        const maxCrossAxisExtent = 420.0;
        const crossAxisSpacing = 12.0;
        const mainAxisSpacing = 12.0;
        const childAspectRatio = 1.45;
        final crossAxisCount = _gridCrossAxisCount(
          viewportWidth: viewportWidth,
          horizontalPadding: horizontalPadding,
          maxCrossAxisExtent: maxCrossAxisExtent,
          crossAxisSpacing: crossAxisSpacing,
        );
        final usableWidth =
            (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
        final tileWidth =
            (usableWidth - (crossAxisCount - 1) * crossAxisSpacing) /
                crossAxisCount;
        final tileHeight = tileWidth / childAspectRatio;
        final row = index ~/ crossAxisCount;
        return horizontalPadding + row * (tileHeight + mainAxisSpacing);
      case ViewMode.grid:
        const horizontalPadding = 12.0;
        const maxCrossAxisExtent = 220.0;
        const crossAxisSpacing = 10.0;
        const mainAxisSpacing = 10.0;
        const childAspectRatio = 0.95;
        final crossAxisCount = _gridCrossAxisCount(
          viewportWidth: viewportWidth,
          horizontalPadding: horizontalPadding,
          maxCrossAxisExtent: maxCrossAxisExtent,
          crossAxisSpacing: crossAxisSpacing,
        );
        final usableWidth =
            (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
        final tileWidth =
            (usableWidth - (crossAxisCount - 1) * crossAxisSpacing) /
                crossAxisCount;
        final tileHeight = tileWidth / childAspectRatio;
        final row = index ~/ crossAxisCount;
        return horizontalPadding + row * (tileHeight + mainAxisSpacing);
    }
  }

  bool _isEntrySelected(Entry e) =>
      _controller.isSelected(e, keyOf: _entrySelectionKey);

  void _clearSelection() {
    _controller.clearSelection();
  }

  void _toggleSelection(Entry e) {
    _controller.toggleSelection(e, keyOf: _entrySelectionKey);
  }

  List<Entry> _selectedEntriesFrom(List<Entry> list) {
    if (_selectedEntryKeys.isEmpty) return const [];
    return list.where(_isEntrySelected).toList();
  }

  TagTargetMeta? _tagMetaForEntry(Entry e) {
    final key = tagKeyForEntry(
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
    );
    if (key.trim().isEmpty) return null;
    return TagTargetMeta(
      key: key,
      name: e.name,
      kind: _tagKindForEntry(e),
      isDir: e.isDir,
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      localPath: e.localPath,
    );
  }

  Future<void> _tagSelectedEntries(List<Entry> visible) async {
    final targets = _selectedEntriesFrom(visible)
        .map(_tagMetaForEntry)
        .whereType<TagTargetMeta>()
        .toList();
    if (targets.isEmpty) {
      showAppToast(context, '没有可标记的项目', error: true);
      return;
    }
    final picked = await TagUI.showTagPicker(
      context,
      target: targets.first,
      title: '批量标记（共 ${targets.length} 项）',
    );
    if (picked == null) return;
    await TagStore.I.ensureLoaded();
    for (final t in targets) {
      await TagStore.I.setTagsForTarget(t, picked);
    }
    if (!mounted) return;
    setState(() {});
    showAppToast(context, '已更新 ${targets.length} 项标签');
  }

  String _searchScopeBaseLabel(FolderSearchScope scope) {
    switch (scope) {
      case FolderSearchScope.currentDirectory:
        return '当前目录';
      case FolderSearchScope.currentCollection:
        return '当前收藏夹';
      case FolderSearchScope.allCollections:
        return '全部收藏夹';
      case FolderSearchScope.singleCollection:
        return '单个收藏夹';
    }
  }

  IconData _searchScopeIcon(FolderSearchScope scope) {
    switch (scope) {
      case FolderSearchScope.currentDirectory:
        return Icons.search_outlined;
      case FolderSearchScope.currentCollection:
        return Icons.folder_special_outlined;
      case FolderSearchScope.allCollections:
        return Icons.collections_bookmark_outlined;
      case FolderSearchScope.singleCollection:
        return Icons.bookmark_outline;
    }
  }

  String _searchScopeChipLabel() {
    if (_searchScope == FolderSearchScope.singleCollection) {
      final c = _collectionById(_singleSearchCollectionId);
      final name = (c?.name ?? '').trim();
      return name.isEmpty ? '范围: 单个收藏夹' : '范围: $name';
    }
    return '范围: ${_searchScopeBaseLabel(_searchScope)}';
  }

  String _searchHintText() {
    switch (_searchScope) {
      case FolderSearchScope.currentDirectory:
        return '搜索当前目录';
      case FolderSearchScope.currentCollection:
        return '搜索当前收藏夹';
      case FolderSearchScope.allCollections:
        return '搜索全部收藏夹';
      case FolderSearchScope.singleCollection:
        final c = _collectionById(_singleSearchCollectionId);
        final name = (c?.name ?? '').trim();
        if (name.isEmpty) return '搜索单个收藏夹';
        return '搜索收藏夹：$name';
    }
  }

  Future<void> _showSearchScopePanel() async {
    await _ensureSearchCollectionsLoaded();
    if (!mounted) return;
    final picked = await showModalBottomSheet<FolderSearchScope>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        Widget tile(FolderSearchScope scope, {String? subtitle}) {
          final selected = _searchScope == scope;
          return ListTile(
            leading: Icon(_searchScopeIcon(scope)),
            title: Text(_searchScopeBaseLabel(scope)),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: selected
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
            onTap: () => Navigator.pop(ctx, scope),
          );
        }

        final singleName =
            (_collectionById(_singleSearchCollectionId)?.name ?? '').trim();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile(FolderSearchScope.currentDirectory, subtitle: '仅筛选当前打开目录'),
              tile(FolderSearchScope.currentCollection,
                  subtitle: '在“${widget.collection.name}”内搜索'),
              tile(FolderSearchScope.allCollections, subtitle: '在全部收藏夹内搜索'),
              tile(
                FolderSearchScope.singleCollection,
                subtitle: singleName.isEmpty ? '选择一个收藏夹' : '当前：$singleName',
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;

    if (picked == FolderSearchScope.singleCollection) {
      final id = await _pickSingleSearchCollection();
      if (id == null || !mounted) return;
      setState(() {
        _searchScope = picked;
        _singleSearchCollectionId = id;
      });
      _persistSearchScopeSettings();
      _scheduleScopeSearch(immediate: true);
      return;
    }

    setState(() => _searchScope = picked);
    _persistSearchScopeSettings();
    _scheduleScopeSearch(immediate: true);
  }

  Future<String?> _pickSingleSearchCollection() async {
    await _ensureSearchCollectionsLoaded();
    if (!mounted) return null;
    final all = _allSearchCollections()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (all.isEmpty) return null;

    return showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(
          builder: (ctx2, setS) {
            final filtered = q.trim().isEmpty
                ? all
                : all
                    .where((c) =>
                        c.name.toLowerCase().contains(q.trim().toLowerCase()))
                    .toList(growable: false);
            final h =
                (MediaQuery.of(ctx2).size.height * 0.72).clamp(320.0, 560.0);
            return SizedBox(
              height: h,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setS(() => q = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索收藏夹',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: q.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空',
                                onPressed: () => setS(() => q = ''),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('没有匹配的收藏夹'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final c = filtered[i];
                              final selected =
                                  c.id == _singleSearchCollectionId;
                              return ListTile(
                                leading: const Icon(Icons.bookmark_outline),
                                title: Text(c.name),
                                subtitle: Text('来源: ${c.sources.length}'),
                                trailing: selected
                                    ? const Icon(Icons.check_circle,
                                        color: Colors.green)
                                    : null,
                                onTap: () => Navigator.pop(ctx2, c.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showTagFilterPanel() async {
    final all = List<Tag>.from(TagStore.I.allTags)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    String q = '';
    bool searchExpanded = false;
    String? pick;
    Widget tileAll(BuildContext ctx) {
      final isAll = _selectedTagId == null || _selectedTagId!.isEmpty;
      return ListTile(
        leading: Icon(isAll ? Icons.check_circle : Icons.circle_outlined),
        title: const Text('全部'),
        onTap: () => Navigator.pop(ctx, null),
      );
    }

    Widget tileTag(BuildContext ctx, Tag t) {
      final sel = _selectedTagId == t.id;
      return ListTile(
        leading: CircleAvatar(
          radius: 10,
          backgroundColor: Color(t.colorValue),
          child: sel
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
        title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: sel ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(ctx, t.id),
      );
    }

    Future<String?> showMobile() {
      return showModalBottomSheet<String?>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState) {
              final size = MediaQuery.of(ctx2).size;
              final insets = MediaQuery.of(ctx2).viewInsets;
              final h = (size.height * 0.68).clamp(300.0, 560.0);
              final filtered = q.trim().isEmpty
                  ? all
                  : all
                      .where((t) =>
                          t.name.toLowerCase().contains(q.trim().toLowerCase()))
                      .toList();

              return AnimatedPadding(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: insets.bottom),
                child: SizedBox(
                  height: h,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '标签筛选',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx2, null),
                              child: const Text('全部'),
                            ),
                            IconButton(
                              tooltip: searchExpanded || q.trim().isNotEmpty
                                  ? '收起搜索'
                                  : '展开搜索',
                              onPressed: () => setState(() {
                                final showing =
                                    searchExpanded || q.trim().isNotEmpty;
                                if (showing) {
                                  q = '';
                                  searchExpanded = false;
                                } else {
                                  searchExpanded = true;
                                }
                              }),
                              icon: Icon(
                                searchExpanded || q.trim().isNotEmpty
                                    ? Icons.close
                                    : Icons.search,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (searchExpanded || q.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: SizedBox(
                            height: 40,
                            child: TextField(
                              autofocus: true,
                              onChanged: (v) => setState(() => q = v),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '搜索标签…',
                                prefixIcon: const Icon(Icons.search, size: 18),
                                suffixIcon: q.trim().isEmpty
                                    ? IconButton(
                                        tooltip: '收起',
                                        icon: const Icon(Icons.expand_less,
                                            size: 18),
                                        onPressed: () => setState(
                                            () => searchExpanded = false),
                                      )
                                    : IconButton(
                                        tooltip: '清除',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: () => setState(() => q = ''),
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                              ),
                            ),
                          ),
                        ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          children: [
                            tileAll(ctx2),
                            const Divider(height: 1),
                            if (filtered.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(20),
                                child: Center(child: Text('没有匹配的标签')),
                              )
                            else
                              for (final t in filtered) tileTag(ctx2, t),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }

    Future<String?> showDesktop() {
      return showGeneralDialog<String?>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'tag_filter',
        barrierColor: Colors.black26,
        transitionDuration: Duration.zero,
        pageBuilder: (ctx, _, __) {
          final size = MediaQuery.of(ctx).size;
          final w = (size.width * 0.78).clamp(280.0, 420.0);
          return StatefulBuilder(builder: (ctx2, setState) {
            final filtered = q.trim().isEmpty
                ? all
                : all
                    .where((t) =>
                        t.name.toLowerCase().contains(q.trim().toLowerCase()))
                    .toList();
            return Align(
              alignment: Alignment.centerRight,
              child: Material(
                color: Theme.of(ctx2).colorScheme.surface,
                elevation: 10,
                child: SizedBox(
                  width: w,
                  height: size.height,
                  child: SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '标签筛选',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                tooltip: searchExpanded || q.trim().isNotEmpty
                                    ? '收起搜索'
                                    : '展开搜索',
                                onPressed: () => setState(() {
                                  final showing =
                                      searchExpanded || q.trim().isNotEmpty;
                                  if (showing) {
                                    q = '';
                                    searchExpanded = false;
                                  } else {
                                    searchExpanded = true;
                                  }
                                }),
                                icon: Icon(
                                  searchExpanded || q.trim().isNotEmpty
                                      ? Icons.close
                                      : Icons.search,
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭',
                                onPressed: () => Navigator.pop(ctx2),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                        if (searchExpanded || q.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: SizedBox(
                              height: 40,
                              child: TextField(
                                onChanged: (v) => setState(() => q = v),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: '搜索标签…',
                                  prefixIcon:
                                      const Icon(Icons.search, size: 18),
                                  suffixIcon: q.trim().isEmpty
                                      ? IconButton(
                                          tooltip: '收起',
                                          icon: const Icon(Icons.expand_less,
                                              size: 18),
                                          onPressed: () => setState(
                                              () => searchExpanded = false),
                                        )
                                      : IconButton(
                                          tooltip: '清除',
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          onPressed: () =>
                                              setState(() => q = ''),
                                        ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                ),
                              ),
                            ),
                          ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView(
                            children: [
                              tileAll(ctx2),
                              const Divider(height: 1),
                              if (filtered.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Center(child: Text('没有匹配的标签')),
                                )
                              else
                                for (final t in filtered) tileTag(ctx2, t),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          });
        },
      );
    }

    final compact = isCompactWidth(context);
    final selected = compact ? await showMobile() : await showDesktop();

    if (!mounted) return;
    pick = selected;
    if (pick != _selectedTagId) {
      setState(() => _selectedTagId = pick);
    }
  }

  final Map<String, WebDavAccount> _wdAccMap = <String, WebDavAccount>{};
  final Map<String, WebDavClient> _wdClientMap = <String, WebDavClient>{};
  bool _wdAccLoaded = false;

  final bool _wdAutoVideoThumb = true;
  final int _wdVideoThumbMaxBytes = 4 * 1024 * 1024;
  final Map<String, Future<File?>> _wdVideoThumbJobs =
      <String, Future<File?>>{};

  bool get _favoritePerDirectoryDisplaySettingsEnabled =>
      _controller.favoritePerDirectoryDisplaySettingsEnabled;
  set _favoritePerDirectoryDisplaySettingsEnabled(bool value) =>
      _controller.favoritePerDirectoryDisplaySettingsEnabled = value;

  LinkedHashMap<String, LayerSettings> get _perDirectoryDisplaySettings =>
      _controller.perDirectoryDisplaySettings;
  static const int _maxPerDirectoryDisplaySettingsEntries =
      folder_detail_controller
          .FolderDetailController.maxPerDirectoryDisplaySettingsEntries;

  String _displaySettingsKeyForCtx(NavCtx ctx) {
    return _controller.displaySettingsKeyForCtx(ctx);
  }

  String _normalizePersistedDisplaySettingsKey(String rawKey) {
    return _controller.normalizePersistedDisplaySettingsKey(rawKey);
  }

  LayerSettings _ensurePerDirectoryLayerSettings(String key) {
    return _controller.ensurePerDirectoryLayerSettings(
      key,
      seed: widget.collection.layer2,
    );
  }

  LayerSettings get _active {
    if (_stack.length == 1) return widget.collection.layer1;
    if (!_favoritePerDirectoryDisplaySettingsEnabled) {
      return widget.collection.layer2;
    }
    final key = _displaySettingsKeyForCtx(_stack.last);
    if (key.isEmpty) return widget.collection.layer2;
    return _ensurePerDirectoryLayerSettings(key);
  }

  Map<String, dynamic> _buildPerDirectoryDisplaySettingsJson() {
    return _controller.buildPerDirectoryDisplaySettingsJson();
  }

  Future<void> _persistPerDirectoryDisplaySettings() async {
    if (!_favoritePerDirectoryDisplaySettingsEnabled) return;
    try {
      await AppSettings.setFavoritePerDirectoryDisplaySettingsState(
        _buildPerDirectoryDisplaySettingsJson(),
      );
    } catch (_) {}
  }

  Future<void> _loadPerDirectoryDisplaySettings() async {
    bool enabled = false;
    final loaded = <String, LayerSettings>{};
    try {
      enabled =
          await AppSettings.getFavoritePerDirectoryDisplaySettingsEnabled();
      if (enabled) {
        final raw =
            await AppSettings.getFavoritePerDirectoryDisplaySettingsState();
        for (final e in raw.entries) {
          final key = _normalizePersistedDisplaySettingsKey(e.key);
          if (key.isEmpty) continue;
          loaded[key] = LayerSettings.fromJson(e.value);
          if (loaded.length >= _maxPerDirectoryDisplaySettingsEntries) break;
        }
      }
    } catch (_) {
      enabled = false;
      loaded.clear();
    }
    if (!mounted) return;
    final disableFromEnabled =
        _favoritePerDirectoryDisplaySettingsEnabled && !enabled;
    final fallbackUnified = disableFromEnabled ? _active.copy() : null;
    setState(() {
      if (fallbackUnified != null && _stack.length > 1) {
        widget.collection.layer2 = fallbackUnified;
      }
      _favoritePerDirectoryDisplaySettingsEnabled = enabled;
      _perDirectoryDisplaySettings
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _reloadDynamicSettings() async {
    bool tagEnabled = _tagEnabled;
    try {
      tagEnabled = await AppSettings.getTagEnabled();
    } catch (_) {}
    if (mounted && tagEnabled != _tagEnabled) {
      setState(() => _tagEnabled = tagEnabled);
    }
    await _loadPerDirectoryDisplaySettings();
  }

  void _refreshFolderDetailState() {
    if (!mounted) return;
    setState(() {});
  }

  void _updateActiveLayerSettings(
      void Function(LayerSettings settings) updater) {
    setState(() {
      final active = _active;
      updater(active);
      if (_stack.length > 1 && !_favoritePerDirectoryDisplaySettingsEnabled) {
        widget.collection.layer2 = active.copy();
      }
    });
    _persistPerDirectoryDisplaySettings();
  }

  String get _title {
    if (_stack.length == 1) return widget.collection.name;
    final cur = _stack.last;
    if (cur.kind == CtxKind.local) return p.basename(cur.localDir ?? '');
    if (cur.kind == CtxKind.webdav) {
      final rel = cur.wdRel.endsWith('/')
          ? cur.wdRel.substring(0, cur.wdRel.length - 1)
          : cur.wdRel;
      return rel.isEmpty ? 'WebDAV' : p.basename(rel);
    }
    if (cur.kind == CtxKind.emby) {
      final t = (cur.title ?? '').trim();
      return t.isEmpty ? widget.collection.name : t;
    }
    return widget.collection.name;
  }

  @override
  void initState() {
    super.initState();
    _controller = folder_detail_controller.FolderDetailController(
        collection: widget.collection)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _singleSearchCollectionId = widget.collection.id;
    _loadSearchScopeSettings();
    WebDavManager.instance.addListener(_onWebDavAccountsChanged);
    _ensureWebDavAccountsLoaded();
    _loadFolderMediaCountCache();
    _ensureSearchCollectionsLoaded();

    final initNav = widget.initialNav;
    if (initNav != null && initNav.kind != CtxKind.root) {
      _stack.add(initNav);
    }
    _attachDeferredInitialNav(widget.deferredInitialNav);

    _reloadDynamicSettings();
    _refresh();
    _initFolderCoverCache();
    TagStore.I.ensureLoaded().then((_) => mounted ? setState(() {}) : null);
    TagStore.I.addListener(_onTagStoreChanged);
  }

  void _attachDeferredInitialNav(Future<NavCtx?>? future) {
    if (future == null) return;
    final token = ++_deferredInitialNavToken;
    unawaited(() async {
      try {
        final nav = await future;
        if (!mounted || token != _deferredInitialNavToken) return;
        if (nav == null || nav.kind == CtxKind.root) return;
        if (_stack.length != 1 || _stack.last.kind != CtxKind.root) return;
        setState(() {
          _stack.add(nav);
          _loading = true;
        });
        await _refresh(showGlobalLoading: false);
      } catch (_) {}
    }());
  }

  Future<void> _initFolderCoverCache() async {
    try {
      final c = await _FolderCoverCache.init(ttl: const Duration(hours: 12));
      if (!mounted) return;
      setState(() => _folderCoverCache = c);
    } catch (_) {}
  }

  void _onWebDavAccountsChanged() {
    _wdAccLoaded = false;
    _wdAccMap.clear();
    _wdClientMap.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchCache.clear();
    _clearScopeSearchState();
    if (mounted) {
      _refresh();
    }
  }

  void _onTagStoreChanged() {
    if (mounted) setState(() {});
  }

  void _schedulePreviewWarmup(List<Entry> list) {
    if (_previewWarmupRunning) return;
    final epoch = ++_previewPrefetchEpoch;
    final snapshot = List<Entry>.from(list, growable: false);
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (!mounted || epoch != _previewPrefetchEpoch) return;
      _previewWarmupRunning = true;
      await _warmVisibleEntryPreviews(snapshot);
      _previewWarmupRunning = false;
    }());
  }

  void _schedulePostLoadWork(List<Entry> list) {
    final epoch = ++_postLoadWorkEpoch;
    final snapshot = List<Entry>.from(list, growable: false);
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted || epoch != _postLoadWorkEpoch || _loading) return;
      _schedulePreviewWarmup(snapshot);
      _scheduleEmbyDirectoryCoverRefresh(snapshot);
      unawaited(_hydrateEmbySizesIfNeeded());
    }());
  }

  void _scheduleEmbyDirectoryCoverRefresh(List<Entry> list) {
    final epoch = ++_embyDirCoverRefreshEpoch;
    final snapshot = List<Entry>.from(list, growable: false);
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || epoch != _embyDirCoverRefreshEpoch || _loading) return;

      final targets = snapshot
          .where((e) => e.isDir && e.isEmby)
          .take(6)
          .toList(growable: false);
      if (targets.isEmpty) return;

      final updates = <String, String>{};
      for (final entry in targets) {
        if (!mounted || epoch != _embyDirCoverRefreshEpoch) return;
        final info = await _getFolderCoverInfo(entry);
        final url = (info?.embyCoverUrl ?? '').trim();
        if (url.isEmpty) continue;
        final key = _imageSourceKeyForEntry(entry);
        if (key.isEmpty) continue;
        if ((entry.embyCoverUrl ?? '').trim() == url) continue;
        updates[key] = url;
      }

      if (!mounted || epoch != _embyDirCoverRefreshEpoch || updates.isEmpty) {
        return;
      }

      var changed = false;
      final next = <Entry>[];
      for (final entry in _raw) {
        final key = _imageSourceKeyForEntry(entry);
        final url = key.isEmpty ? null : updates[key];
        if (url == null) {
          next.add(entry);
          continue;
        }
        changed = true;
        next.add(Entry(
          isDir: entry.isDir,
          name: entry.name,
          size: entry.size,
          modified: entry.modified,
          typeKey: entry.typeKey,
          origin: entry.origin,
          localPath: entry.localPath,
          wdAccountId: entry.wdAccountId,
          wdRelPath: entry.wdRelPath,
          wdHref: entry.wdHref,
          embyAccountId: entry.embyAccountId,
          embyItemId: entry.embyItemId,
          embyCoverUrl: url,
          embyAspectRatio: entry.embyAspectRatio,
          searchCollectionId: entry.searchCollectionId,
          searchCollectionName: entry.searchCollectionName,
        ));
      }
      if (!changed) return;

      setState(() {
        _raw = next;
        _controller.raw = next;
      });
    }());
  }

  Future<void> _warmVisibleEntryPreviews(List<Entry> list) async {
    if (!mounted || list.isEmpty) return;

    final dirCandidates = <Entry>[];
    final mediaCandidates = <Entry>[];
    for (final entry in list) {
      if (entry.isLoading) continue;
      if (entry.typeKey == 'hint' ||
          entry.typeKey == 'emby_login' ||
          entry.typeKey == 'emby_empty' ||
          entry.typeKey == 'wd_error') {
        continue;
      }

      if (entry.isDir) {
        if (entry.isEmby) {
          dirCandidates.add(entry);
          if (dirCandidates.length >= 3 && mediaCandidates.length >= 5) {
            break;
          }
        }
        continue;
      }

      mediaCandidates.add(entry);
      if (dirCandidates.length >= 3 && mediaCandidates.length >= 5) {
        break;
      }
    }

    final candidates = <Entry>[
      ...dirCandidates.take(3),
      ...mediaCandidates.take(5),
    ];
    if (candidates.isEmpty) return;

    for (final entry in candidates) {
      if (!mounted || _previewPrefetchEpoch == 0) return;
      await _warmPreviewForEntry(entry);
      if (!mounted) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _warmPreviewForEntry(Entry e) async {
    final imageContext = context;
    try {
      if (e.isDir) {
        if (!e.isEmby) return;
        final cover = await _getFolderCoverInfo(e);
        final url = (cover?.embyCoverUrl ?? '').trim();
        if (url.isEmpty || !imageContext.mounted) return;
        await precacheImage(
          CachedNetworkImageProvider(url),
          imageContext,
        );
        return;
      }

      if (e.isEmby) {
        final url = (e.embyCoverUrl ?? '').trim();
        if (url.isEmpty) return;
        if (!mounted) return;
        await precacheImage(
          CachedNetworkImageProvider(url),
          imageContext,
        );
        return;
      }

      if (e.isWebDav) {
        final accId = e.wdAccountId;
        if (accId == null) return;
        final acc = _wdAccMap[accId];
        final client =
            _wdClientMap[accId] ?? (acc == null ? null : WebDavClient(acc));
        if (client == null) return;

        final href = (e.wdHref != null && e.wdHref!.trim().isNotEmpty)
            ? e.wdHref!.trim()
            : (e.wdRelPath != null
                ? client.resolveRel(e.wdRelPath!).toString()
                : '');
        if (href.isEmpty) return;

        if (_isImgName(e.name)) {
          final cached = await client.ensureCoverCached(href, e.name);
          if (await cached.exists()) {
            if (!imageContext.mounted) return;
            await precacheImage(FileImage(cached), imageContext);
          }
          return;
        }

        if (_isVidName(e.name)) {
          final thumb = await getPageWebDavVideoThumbFile(
            client,
            href,
            e.name,
            maxBytes: _wdVideoThumbMaxBytes,
            expectedSize: e.size,
          );
          if (thumb != null && await thumb.exists()) {
            if (!imageContext.mounted) return;
            await precacheImage(FileImage(thumb), imageContext);
          }
          return;
        }
        return;
      }

      final local = (e.localPath ?? '').trim();
      if (local.isEmpty) return;
      if (_isImg(local)) {
        final file = File(local);
        if (await file.exists()) {
          if (!imageContext.mounted) return;
          await precacheImage(FileImage(file), imageContext);
        }
        return;
      }
      if (_isVid(local)) {
        final thumb = await ThumbCache.getOrCreateVideoThumb(local);
        if (thumb != null && await thumb.exists()) {
          if (!imageContext.mounted) return;
          await precacheImage(FileImage(thumb), imageContext);
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _deferredInitialNavToken++;
    _previewPrefetchEpoch = 0;
    _previewWarmupRunning = false;
    _postLoadWorkEpoch++;
    _embyDirCoverRefreshEpoch++;
    _controller.dispose();
    WebDavManager.instance.removeListener(_onWebDavAccountsChanged);
    TagStore.I.removeListener(_onTagStoreChanged);
    _dirCoverJobs.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchDebounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFolderMediaCountCache() async {
    if (_folderMediaCountLoaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('folder_media_count_cache_v1');
      if (raw != null && raw.trim().isNotEmpty) {
        final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
        for (final e in m.entries) {
          final v = e.value;
          if (v is int) _folderMediaCountCache[e.key] = v;
          if (v is double) _folderMediaCountCache[e.key] = v.toInt();
          if (v is String) {
            final n = int.tryParse(v);
            if (n != null) _folderMediaCountCache[e.key] = n;
          }
        }
      }
    } catch (_) {}
    _folderMediaCountLoaded = true;
  }

  Future<void> _saveFolderMediaCountCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          'folder_media_count_cache_v1', jsonEncode(_folderMediaCountCache));
    } catch (_) {}
  }

  Future<void> _refresh({bool showGlobalLoading = true}) async {
    if (showGlobalLoading) {
      setState(() => _loading = true);
    }
    final cur = _stack.last;
    if (cur.kind == CtxKind.emby) {
      final accId = cur.embyAccountId!;
      final path = cur.embyPath;
      final cached = _getCachedEmbyList(accId, path);
      if (cached != null && mounted) {
        setState(() {
          _raw = List<Entry>.from(cached, growable: false);
          _controller.raw = _raw;
          _loading = false;
          _contentHasAppeared = true;
        });
        _scopeSearchCache.clear();
        _schedulePostLoadWork(_raw);
        unawaited(_refreshEmbyInBackground(accId, path));
        return;
      }
    }

    final list = switch (cur.kind) {
      CtxKind.root => await _loadVirtual(),
      CtxKind.local => await _loadLocalDir(cur.localDir!),
      CtxKind.webdav => await _loadWebDavDir(cur.wdAccountId!, cur.wdRel),
      CtxKind.emby => await _loadEmby(cur.embyAccountId!, cur.embyPath),
    };
    _updateFolderCountCacheFromList(cur, list);
    if (!mounted) return;
    setState(() {
      _raw = list;
      _controller.raw = list;
      _loading = false;
      _contentHasAppeared = true;
      if (_selectionMode) {
        final keys = list
            .map(_entrySelectionKeyRaw)
            .where((e) => e.trim().isNotEmpty)
            .toSet();
        _selectedEntryKeys.removeWhere((k) => !keys.contains(k));
        if (_selectedEntryKeys.isEmpty) {
          _selectionMode = false;
        }
      }
    });
    _scopeSearchCache.clear();
    _schedulePostLoadWork(list);
  }

  Future<void> _refreshEmbyInBackground(String accountId, String path) async {
    try {
      final latest = await _loadEmby(accountId, path);
      if (!mounted || _stack.isEmpty) return;
      final cur = _stack.last;
      if (cur.kind != CtxKind.emby ||
          cur.embyAccountId != accountId ||
          cur.embyPath != path) {
        return;
      }

      final sameLength = latest.length == _raw.length;
      final unchanged = sameLength &&
          Iterable<int>.generate(latest.length).every((i) {
            final a = latest[i];
            final b = _raw[i];
            return a.name == b.name &&
                a.typeKey == b.typeKey &&
                a.embyItemId == b.embyItemId &&
                a.embyCoverUrl == b.embyCoverUrl;
          });
      if (unchanged) return;

      _updateFolderCountCacheFromList(cur, latest);
      setState(() {
        _raw = latest;
        _controller.raw = latest;
      });
      _scopeSearchCache.clear();
      _schedulePostLoadWork(latest);
    } catch (_) {}
  }

  Future<void> _hydrateEmbySizesIfNeeded({int maxItems = 60}) async {
    if (_embySizeHydrating) return;
    if (_stack.isEmpty) return;
    final cur = _stack.last;
    if (cur.kind != CtxKind.emby) return;
    if (_active.sortKey != SortKey.size) return;

    final accId = (cur.embyAccountId ?? '').trim();
    if (accId.isEmpty) return;

    final targets = _raw
        .where((e) =>
            e.isEmby &&
            !e.isDir &&
            !e.isLoading &&
            (e.embyItemId ?? '').trim().isNotEmpty &&
            e.size == 0)
        .take(maxItems)
        .toList();
    if (targets.isEmpty) return;

    final accList = await EmbyStore.load();
    final acc = accList.firstWhere((a) => a.id == accId,
        orElse: () => EmbyAccount(
              id: '',
              name: '',
              serverUrl: '',
              username: '',
              userId: '',
              apiKey: '',
            ));
    if (acc.id.isEmpty) return;

    _embySizeHydrating = true;
    final client = EmbyClient(acc);

    const int batch = 6;
    final Map<String, int> updates = <String, int>{};

    try {
      for (int i = 0; i < targets.length; i += batch) {
        final end = (i + batch) < targets.length ? (i + batch) : targets.length;
        final slice = targets.sublist(i, end);
        final futures = <Future<void>>[];
        for (final e in slice) {
          final itemId = (e.embyItemId ?? '').trim();
          if (itemId.isEmpty) continue;
          final cacheKey = '$accId|$itemId';
          final cached = _embySizeCache[cacheKey];
          if (cached != null && cached > 0) {
            updates[itemId] = cached;
            continue;
          }
          futures.add(() async {
            try {
              final sz = await client.getItemSize(itemId).timeout(
                    const Duration(seconds: 6),
                    onTimeout: () => null,
                  );
              if (sz != null && sz > 0) {
                _embySizeCache[cacheKey] = sz;
                updates[itemId] = sz;
              }
            } catch (_) {}
          }());
        }
        if (futures.isNotEmpty) {
          await Future.wait(futures);
        }
      }
    } catch (_) {
    } finally {
      _embySizeHydrating = false;
    }

    if (!mounted) return;
    if (updates.isEmpty) return;

    setState(() {
      _raw = _raw.map((e) {
        if (!e.isEmby || e.isDir || e.isLoading) return e;
        if (e.embyAccountId != accId) return e;
        final itemId = (e.embyItemId ?? '').trim();
        final sz = updates[itemId];
        if (sz == null || sz <= 0) return e;
        if (e.size > 0) return e;
        return Entry(
          isDir: e.isDir,
          name: e.name,
          size: sz,
          modified: e.modified,
          typeKey: e.typeKey,
          origin: e.origin,
          localPath: e.localPath,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
          embyCoverUrl: e.embyCoverUrl,
        );
      }).toList();
      _controller.raw = _raw;
    });
  }

  List<Entry> _shown() {
    return _controller.shown(
      activeSettings: _active,
      tagKeyOf: _entrySelectionKeyRaw,
    );
  }

  List<String> _imgs(List<Entry> l) => l
      .where((e) =>
          !e.isDir &&
          !e.isWebDav &&
          e.localPath != null &&
          _isImg(e.localPath!))
      .map((e) => e.localPath!)
      .toList();
  List<String> _vids(List<Entry> l) => l
      .where((e) =>
          !e.isDir &&
          !e.isWebDav &&
          e.localPath != null &&
          _isVid(e.localPath!))
      .map((e) => e.localPath!)
      .toList();

  Future<void> _addFilesHere() async {
    final cur = _stack.last;
    if (cur.kind != CtxKind.local) return;
    final dir = cur.localDir;
    if (dir == null) return;

    final n = await _addFilesToDir(dir);
    if (!mounted) return;
    if (n <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未添加文件')));
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已添加 $n 个文件到：$dir')));
    await _refresh();
  }

  Future<void> _ctxEntryMenu(Entry e, Offset pos) async {
    final items = <_CtxItem<String>>[
      if (_tagEnabled) const _CtxItem('tag', '标记Tag', Icons.sell_outlined),
      if (_isVidName(e.name) || _isImgName(e.name))
        const _CtxItem('thumb', '检查封面原因', Icons.image_search),
    ];

    final a = await _ctxMenu<String>(context, pos, items);
    switch (a) {
      case 'thumb':
        if (!mounted) return;
        await ThumbnailInspector.inspectAndExplain(
          context,
          name: e.name,
          isWebDav: e.isWebDav,
          localPath: e.localPath,
          wdHref: e.wdHref,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
        );
        if (mounted && e.isWebDav) {
          final accId = e.wdAccountId;
          if (accId != null) {
            final acc = _wdAccMap[accId];
            final client =
                _wdClientMap[accId] ?? (acc == null ? null : WebDavClient(acc));
            final href = (e.wdHref != null && e.wdHref!.trim().isNotEmpty)
                ? e.wdHref!.trim()
                : (client != null && e.wdRelPath != null
                    ? client.resolveRel(e.wdRelPath!).toString()
                    : '');

            final key = '$accId|$href';
            _wdVideoThumbJobs.remove(key);
          }
          setState(() {});
        }
        break;

      case 'tag':
        final key = tagKeyForEntry(
          isWebDav: e.isWebDav,
          isEmby: e.isEmby,
          localPath: e.localPath,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
        );
        if (key.trim().isEmpty) return;
        final meta = TagTargetMeta(
          key: key,
          name: e.name,
          kind: _tagKindForEntry(e),
          isDir: e.isDir,
          isWebDav: e.isWebDav,
          isEmby: e.isEmby,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
          embyCoverUrl: e.embyCoverUrl,
          localPath: e.localPath,
        );
        if (!mounted) return;
        await TagUI.showTagPicker(context, target: meta);
        if (!mounted) return;
        setState(() {});
        break;
    }
  }

  Future<bool> _onBack() async {
    if (_selectionMode) {
      setState(_clearSelection);
      return false;
    }
    if (widget.exitOnInitialContextBack &&
        widget.initialNav != null &&
        widget.initialNav!.kind != CtxKind.root &&
        _stack.length == 2) {
      Navigator.pop(context, widget.collection);
      return false;
    }
    if (_stack.length > 1) {
      setState(() {
        _stack.removeLast();
        _q = '';
        _searchExpanded = false;
        _clearScopeSearchState();
        _clearSelection();
      });

      await _refresh();

      final targetDepth = _stack.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollOffsets.containsKey(targetDepth) &&
            _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollOffsets[targetDepth]!);
        }
      });

      return false;
    }
    Navigator.pop(context, widget.collection);
    return false;
  }

  Future<void> _pickView() async {
    final v = await _picker<ViewMode>(
      context,
      title: '视图模式',
      current: _active.viewMode,
      options: ViewMode.values,
      labelOf: _vmLabel,
      iconOf: _vmIcon,
    );
    if (v == null) return;
    _updateActiveLayerSettings((s) => s.viewMode = v);
  }

  Future<void> _pickSort() async {
    final k = await _picker<SortKey>(
      context,
      title: '排序方式',
      current: _active.sortKey,
      options: SortKey.values,
      labelOf: _skLabel,
      iconOf: _skIcon,
    );
    if (k == null) return;
    _updateActiveLayerSettings((s) => s.sortKey = k);
    _hydrateEmbySizesIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    final list = _shown();
    final imgs = _imgs(list);
    final vids = _vids(list);
    final hasQuery = _q.trim().isNotEmpty;
    final hasTagFilter =
        _tagEnabled && _selectedTagId != null && _selectedTagId!.isNotEmpty;
    final hasScopeInfo =
        hasQuery && _searchScope != FolderSearchScope.currentDirectory;
    final hasFilterState = hasQuery || hasTagFilter;
    final scopedLoading = _usingScopeSearch && _scopeSearching;
    final scopedError = _usingScopeSearch ? _scopeSearchError : null;
    final selectedVisible = _selectedEntriesFrom(list);
    final selectedCount = selectedVisible.length;

    final body = _loading
        ? _buildImmersiveLoadingBody()
        : (scopedLoading && list.isEmpty)
            ? _buildImmersiveLoadingBody(compact: true)
            : (scopedError != null && list.isEmpty)
                ? AppErrorState(
                    title: '搜索失败',
                    details: friendlyErrorMessage(scopedError),
                    onRetry: () => _scheduleScopeSearch(immediate: true),
                  )
                : list.isEmpty
                    ? AppEmptyState(
                        title: hasFilterState ? '没有匹配结果' : '没有内容',
                        subtitle:
                            hasFilterState ? '尝试调整筛选条件' : '试试切换排序、视图或下拉刷新',
                        icon: Icons.folder_off_outlined,
                        actionLabel: hasFilterState ? '清空筛选' : '刷新',
                        onAction: hasFilterState
                            ? () => setState(() {
                                  _q = '';
                                  _searchExpanded = false;
                                  _clearScopeSearchState();
                                  _selectedTagId = null;
                                })
                            : _refresh,
                      )
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: AnimatedOpacity(
                          opacity: _contentHasAppeared ? 1 : 0.92,
                          duration: const Duration(milliseconds: 140),
                          curve: Curves.easeOutCubic,
                          child: _buildByMode(list, imgs, vids),
                        ),
                      );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _onBack();
        },
        child: Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF7F6FF),
                  Color(0xFFEFF4FF),
                  Color(0xFFF6FBFF)
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildFolderHeaderGlass(hasQuery: hasQuery),
                  _buildFolderFilterBar(),
                  if (hasFilterState)
                    _buildFolderFilterSummary(
                      hasQuery: hasQuery,
                      hasScopeInfo: hasScopeInfo,
                      hasTagFilter: hasTagFilter,
                      scopedLoading: scopedLoading,
                    ),
                  Expanded(child: body),
                  if (_selectionMode)
                    _buildFolderSelectionBar(list, selectedCount),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// ✅ 核心改造：WebDAV文件预览组件【无改动，原有逻辑正常】
}
