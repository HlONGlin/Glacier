part of '../pages.dart';

/// =========================
/// FavoritesPage (Collections)
/// =========================
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  bool showGlobalLoading = false;

  bool _loading = true;
  Object? _loadError;
  bool _reloading = false;
  List<FavoriteCollection> _list = [];
  String _favoritesQuery = '';
  bool _favoritesSearchExpanded = false;
  bool _favoritesGrid = true;
  bool _autoEnteredLast = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    if (showGlobalLoading) {
      setState(() => _loading = true);
    }
    try {
      final list = await FavoriteStore.load();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
      return;
    } finally {
      _reloading = false;
    }

    if (!_autoEnteredLast) {
      _autoEnteredLast = true;
      _tryAutoEnterLastFavorite();
    }
  }

  Future<void> _openEmbyOnlyFavorites({
    bool refreshOnReturn = true,
    Set<String>? scopedAccountIds,
  }) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmbyExclusiveFavoritesPage(
          accountIds: scopedAccountIds,
          openFolder: (ctx, {required title, required source}) {
            return _openTagSourceAsFolder(ctx, title: title, source: source);
          },
          openSettings: (ctx) {
            return Navigator.push(
              ctx,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            );
          },
        ),
      ),
    );
    if (!refreshOnReturn || !mounted) return;
    await _reload();
  }

  Future<void> _tryAutoEnterLastFavorite() async {
    try {
      final enabled = await AppSettings.getAutoEnterLastFavorite();
      if (!enabled) return;

      final lastId = await AppSettings.getLastFavoriteId();
      if (lastId == null) return;

      final idx = _list.indexWhere((e) => e.id == lastId);
      if (idx < 0) return;

      if (!mounted) return;
      final c = _list[idx];
      final updated = await Navigator.push<FavoriteCollection>(
        context,
        MaterialPageRoute(
            builder: (_) => FolderDetailPage(collection: c.copy())),
      );
      if (updated == null) return;
      final uIdx = _list.indexWhere((e) => e.id == updated.id);
      if (uIdx >= 0) {
        setState(() => _list[uIdx] = updated);
        await _save();
      }
    } catch (_) {}
  }

  Future<void> _save() => FavoriteStore.save(_list);

  List<FavoriteCollection> _filteredCollections() {
    final query = _favoritesQuery.trim().toLowerCase();
    final out = _list.where((c) {
      if (query.isEmpty) return true;
      return c.name.toLowerCase().contains(query);
    }).toList();

    out.sort((a, b) {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<void> _openCollection(FavoriteCollection c) async {
    await AppSettings.setLastFavoriteId(c.id);

    final onlyEmbySource =
        c.sources.isNotEmpty && c.sources.every(_isEmbySource);
    final embyAccIds = c.sources
        .where(_isEmbySource)
        .map(_parseEmbySource)
        .whereType<_EmbyRef>()
        .map((r) => r.accountId.trim())
        .where((id) => id.isNotEmpty && id.toLowerCase() != 'all')
        .toSet();
    if (onlyEmbySource) {
      try {
        final enabled = await AppSettings.getEmbyExclusiveFavoritesUiEnabled();
        if (enabled) {
          if (!mounted) return;
          await _openEmbyOnlyFavorites(
            scopedAccountIds: embyAccIds.isEmpty ? null : embyAccIds,
          );
          return;
        }
      } catch (_) {}
    }

    if (!mounted) return;
    final updated = await Navigator.push<FavoriteCollection>(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailPage(collection: c.copy())),
    );
    if (updated == null) return;
    final idx = _list.indexWhere((e) => e.id == updated.id);
    if (idx >= 0) {
      setState(() => _list[idx] = updated);
      await _save();
    }
  }

  Future<void> _newCollection() async {
    final name = await _textInput(context,
        title: '新建收藏夹', hint: '输入收藏夹名称', initial: '新收藏夹');
    if (name == null) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _list.add(
        FavoriteCollection(
          id: id,
          name: name.trim().isEmpty ? '新收藏夹' : name.trim(),
          sources: [],
          coverPath: null,
          layer1: LayerSettings(
              viewMode: ViewMode.gallery, sortKey: SortKey.name, asc: true),
          layer2: LayerSettings(
              viewMode: ViewMode.list, sortKey: SortKey.name, asc: true),
        ),
      );
    });
    await _save();
  }

  Future<void> _rename(FavoriteCollection c) async {
    final name =
        await _textInput(context, title: '重命名', hint: '输入新名称', initial: c.name);
    if (name == null) return;
    final v = name.trim();
    if (v.isEmpty) return;
    setState(() => c.name = v);
    await _save();
  }

  Future<void> _delete(FavoriteCollection c) async {
    final ok = await _confirm(context,
        title: '删除收藏夹', message: '确定删除「${c.name}」吗？\n（仅删除配置，不会删除磁盘文件）');
    if (!ok) return;
    setState(() => _list.removeWhere((e) => e.id == c.id));
    await _save();
  }

  Future<void> _changeCover(FavoriteCollection c) async {
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: '选择封面（图片或视频）',
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions:
          [..._imgExts, ..._vidExts].map((e) => e.substring(1)).toList(),
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    setState(() => c.coverPath = p.normalize(path));
    await _save();
  }

  Future<void> _clearCover(FavoriteCollection c) async {
    setState(() => c.coverPath = null);
    await _save();
  }

  Future<void> _edit(FavoriteCollection c) async {
    final updated = await _editSourcesDialog(context, c);
    if (updated == null) return;
    final idx = _list.indexWhere((e) => e.id == c.id);
    if (idx < 0) return;
    setState(() => _list[idx] = updated);
    await _save();
  }

  Future<void> _ctx(FavoriteCollection c, Offset pos) async {
    final a = await _ctxMenu<String>(context, pos, const [
      _CtxItem('edit', '编辑（管理来源）', Icons.edit_outlined),
      _CtxItem('rename', '重命名', Icons.drive_file_rename_outline),
      _CtxItem('cover', '更换封面', Icons.image_outlined),
      _CtxItem('clear', '清除自定义封面', Icons.layers_clear_outlined),
      _CtxItem('delete', '删除', Icons.delete_outline),
    ]);

    switch (a) {
      case 'edit':
        await _edit(c);
        break;
      case 'rename':
        await _rename(c);
        break;
      case 'cover':
        await _changeCover(c);
        break;
      case 'clear':
        await _clearCover(c);
        break;
      case 'delete':
        await _delete(c);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filteredCollections();
    final hasFilterState = _favoritesQuery.trim().isNotEmpty;

    final activeTokens = <String>[
      if (_favoritesQuery.trim().isNotEmpty) '搜索: ${_favoritesQuery.trim()}',
    ];

    final body = _loading
        ? const AppLoadingState()
        : _loadError != null
            ? AppErrorState(
                title: '加载收藏夹失败',
                details: friendlyErrorMessage(_loadError!),
                onRetry: _reload,
              )
            : _list.isEmpty
                ? AppEmptyState(
                    title: '还没有收藏夹',
                    subtitle: '点击新建，创建你的第一个收藏夹',
                    icon: Icons.folder_open_outlined,
                    actionLabel: '新建收藏夹',
                    onAction: _newCollection,
                  )
                : shown.isEmpty
                    ? AppEmptyState(
                        title: '没有匹配结果',
                        subtitle: '尝试修改或清空搜索关键词',
                        icon: Icons.filter_alt_off_outlined,
                        actionLabel: '清空搜索',
                        onAction: () => setState(() {
                          _favoritesQuery = '';
                          _favoritesSearchExpanded = false;
                        }),
                      )
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: AppViewport(
                          child: _favoritesGrid
                              ? GridView.builder(
                                  padding: const EdgeInsets.all(12),
                                  cacheExtent: 3000,
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 360,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 1.35,
                                  ),
                                  itemCount: shown.length,
                                  itemBuilder: (_, i) {
                                    final c = shown[i];
                                    return _CollectionCard(
                                      key: ValueKey(c.id),
                                      c: c,
                                      onOpen: () => _openCollection(c),
                                      onSecondary: (pos) => _ctx(c, pos),
                                    );
                                  },
                                )
                              : ListView.separated(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 8, 12, 16),
                                  itemCount: shown.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (_, i) {
                                    final c = shown[i];
                                    return _CollectionListTile(
                                      c: c,
                                      onOpen: () => _openCollection(c),
                                      onSecondary: (pos) => _ctx(c, pos),
                                    );
                                  },
                                ),
                        ),
                      );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF7F6FF), Color(0xFFEFF4FF), Color(0xFFF6FBFF)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                  child: Glass(
                    radius: 16,
                    blur: 16,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '收藏夹控制台',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: _favoritesSearchExpanded ||
                                      _favoritesQuery.trim().isNotEmpty
                                  ? '收起搜索'
                                  : '展开搜索',
                              onPressed: () => setState(() {
                                final showing = _favoritesSearchExpanded ||
                                    _favoritesQuery.trim().isNotEmpty;
                                if (showing) {
                                  _favoritesQuery = '';
                                  _favoritesSearchExpanded = false;
                                } else {
                                  _favoritesSearchExpanded = true;
                                }
                              }),
                              icon: Icon(
                                _favoritesSearchExpanded ||
                                        _favoritesQuery.trim().isNotEmpty
                                    ? Icons.close
                                    : Icons.search,
                              ),
                            ),
                            TopActionMenu<String>(
                              tooltip: '更多',
                              items: const [
                                TopActionMenuItem(
                                    value: 'history',
                                    icon: Icons.history,
                                    label: '历史记录'),
                                TopActionMenuItem(
                                    value: 'settings',
                                    icon: Icons.settings_outlined,
                                    label: '设置'),
                                TopActionMenuItem(
                                    value: 'tags',
                                    icon: Icons.sell_outlined,
                                    label: '标签管理'),
                                TopActionMenuItem(
                                    value: 'webdav',
                                    icon: Icons.cloud_outlined,
                                    label: 'WebDAV'),
                                TopActionMenuItem(
                                    value: 'emby',
                                    icon: Icons.video_library_outlined,
                                    label: 'Emby'),
                                TopActionMenuItem(
                                    value: 'refresh',
                                    icon: Icons.refresh,
                                    label: '刷新'),
                              ],
                              onSelected: (v) async {
                                switch (v) {
                                  case 'history':
                                    await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const HistoryPage()));
                                    break;
                                  case 'settings':
                                    await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const SettingsPage()));
                                    break;
                                  case 'tags':
                                    if (!mounted) return;
                                    await showAdaptivePanel<void>(
                                      context: context,
                                      barrierLabel: 'tag_manager',
                                      child: TagManagerPage(
                                        onOpenItem: (item) =>
                                            openTagTarget(context, item),
                                        onLocateItem: (item) =>
                                            locateTagTarget(context, item),
                                      ),
                                    );
                                    break;
                                  case 'webdav':
                                    if (!mounted) return;
                                    await Navigator.push(
                                        context, WebDavPage.routeNoAnim());
                                    break;
                                  case 'emby':
                                    if (!mounted) return;
                                    await _openEmbyPageWithUi(context);
                                    break;
                                  case 'refresh':
                                    await _reload();
                                    break;
                                }
                              },
                            ),
                          ],
                        ),
                        if (_favoritesSearchExpanded ||
                            _favoritesQuery.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          TextField(
                            onChanged: (v) =>
                                setState(() => _favoritesQuery = v),
                            decoration: InputDecoration(
                              hintText: '搜索收藏夹',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _favoritesQuery.trim().isEmpty
                                  ? IconButton(
                                      tooltip: '收起',
                                      icon: const Icon(Icons.expand_less),
                                      onPressed: () => setState(() =>
                                          _favoritesSearchExpanded = false),
                                    )
                                  : IconButton(
                                      tooltip: '清空',
                                      icon: const Icon(Icons.close),
                                      onPressed: () =>
                                          setState(() => _favoritesQuery = ''),
                                    ),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              isDense: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                FilterBar(
                  children: [
                    ControlChip(
                      icon: _favoritesGrid
                          ? Icons.grid_view_outlined
                          : Icons.view_list_outlined,
                      label: _favoritesGrid ? '卡片' : '列表',
                      selected: true,
                      onTap: () =>
                          setState(() => _favoritesGrid = !_favoritesGrid),
                    ),
                  ],
                ),
                if (hasFilterState)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Glass(
                      radius: 12,
                      blur: 12,
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '已生效: ${activeTokens.join('  ·  ')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _favoritesQuery = '';
                              _favoritesSearchExpanded = false;
                            }),
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _newCollection,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建收藏夹'),
        ),
      ),
    );
  }
}

Widget _collectionCover(FavoriteCollection c) {
  final custom = c.coverPath;
  if (custom != null && custom.trim().isNotEmpty && File(custom).existsSync()) {
    return _isImg(custom)
        ? Image.file(File(custom),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _CoverPlaceholder())
        : (_isVid(custom)
            ? VideoThumbImage(videoPath: custom)
            : const _CoverPlaceholder());
  }
  return _MultiSourcePreview(c.sources);
}

String _collectionSubtitle(FavoriteCollection c) {
  if (c.sources.isEmpty) {
    return '未添加来源（长按或右上角菜单可编辑）';
  }
  return '来源总数: ${c.sources.length}';
}

class _CollectionCard extends StatelessWidget {
  final FavoriteCollection c;
  final VoidCallback onOpen;
  final void Function(Offset globalPos) onSecondary;

  const _CollectionCard(
      {super.key,
      required this.c,
      required this.onOpen,
      required this.onSecondary});

  @override
  Widget build(BuildContext context) {
    final subtitle = _collectionSubtitle(c);

    return InkWell(
      onTap: onOpen,
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        onSecondary(pos);
      },
      borderRadius: BorderRadius.circular(16),
      child: Glass(
        radius: 18,
        blur: 18,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Expanded(child: _collectionCover(c)),
            ListTile(
              dense: true,
              title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Builder(
                builder: (btnCtx) => IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () {
                    final box = btnCtx.findRenderObject() as RenderBox?;
                    final pos = box == null
                        ? Offset.zero
                        : box.localToGlobal(Offset.zero);
                    onSecondary(pos);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionListTile extends StatelessWidget {
  final FavoriteCollection c;
  final VoidCallback onOpen;
  final void Function(Offset globalPos) onSecondary;

  const _CollectionListTile({
    required this.c,
    required this.onOpen,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = _collectionSubtitle(c);
    return InkWell(
      onTap: onOpen,
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        onSecondary(pos);
      },
      borderRadius: BorderRadius.circular(14),
      child: Glass(
        radius: 14,
        blur: 14,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 72,
                height: 72,
                child: _collectionCover(c),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Builder(
              builder: (btnCtx) => IconButton(
                icon: const Icon(Icons.more_horiz),
                onPressed: () {
                  final box = btnCtx.findRenderObject() as RenderBox?;
                  final pos = box == null
                      ? Offset.zero
                      : box.localToGlobal(Offset.zero);
                  onSecondary(pos);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
