part of '../pages.dart';

class _EmbyCollectionProjection {
  final FavoriteCollection base;
  final List<String> embySources;
  final List<EmbyPathSourceRef> refs;

  const _EmbyCollectionProjection({
    required this.base,
    required this.embySources,
    required this.refs,
  });

  Set<String> get accountIds => refs.map((e) => e.accountId).toSet();
}

class _EmbyOnlyFavoritesPage extends StatefulWidget {
  const _EmbyOnlyFavoritesPage();

  @override
  State<_EmbyOnlyFavoritesPage> createState() => _EmbyOnlyFavoritesPageState();
}

class _EmbyOnlyFavoritesPageState extends State<_EmbyOnlyFavoritesPage> {
  static const Color _bg = Color(0xFF0C111A);
  static const Color _panel = Color(0xFF171D2A);
  static const Color _text = Color(0xFFF2F5FF);
  static const Color _sub = Color(0xFF97A0B6);
  static const SystemUiOverlayStyle _statusStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  );

  bool _loading = true;
  Object? _loadError;
  String _query = '';
  int _tab = 0;

  List<FavoriteCollection> _allCollections = const [];
  List<_EmbyCollectionProjection> _items = const [];
  Map<String, EmbyAccount> _accountMap = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  List<_EmbyCollectionProjection> _buildProjection(
      List<FavoriteCollection> collections) {
    final out = <_EmbyCollectionProjection>[];
    for (final c in collections) {
      final embySources =
          c.sources.where((s) => isPageEmbySource(s)).toList(growable: false);
      if (embySources.isEmpty) continue;
      final refs = embySources
          .map(parsePageEmbySource)
          .whereType<EmbyPathSourceRef>()
          .toList(growable: false);
      if (refs.isEmpty) continue;
      out.add(_EmbyCollectionProjection(
          base: c, embySources: embySources, refs: refs));
    }
    out.sort((a, b) =>
        a.base.name.toLowerCase().compareTo(b.base.name.toLowerCase()));
    return out;
  }

  Future<NavCtx?> _initialEmbyNavForProjection(
      _EmbyCollectionProjection projection) async {
    for (final ref in projection.refs) {
      final accountId = ref.accountId.trim();
      if (accountId.isEmpty) continue;

      final rawPath = ref.path.trim();
      if (rawPath.isNotEmpty && rawPath != 'favorites') {
        return NavCtx.emby(
          embyAccountId: accountId,
          embyPath: rawPath,
          title: projection.base.name,
        );
      }

      final account = _accountMap[accountId];
      if (account == null) continue;

      try {
        final views = await EmbyClient(account).listViews();
        final first = views.firstWhere(
          (item) => item.id.trim().isNotEmpty,
          orElse: () => EmbyItem(id: '', name: '', type: ''),
        );
        final viewId = first.id.trim();
        if (viewId.isEmpty) continue;
        return NavCtx.emby(
          embyAccountId: accountId,
          embyPath: 'view:$viewId',
          title: first.name.trim().isEmpty ? projection.base.name : first.name,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final collections = await FavoriteStore.load();
      final embyAccs = await EmbyStore.load();
      final map = <String, EmbyAccount>{for (final a in embyAccs) a.id: a};
      if (!mounted) return;
      setState(() {
        _allCollections = collections;
        _accountMap = map;
        _items = _buildProjection(collections);
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
    }
  }

  List<_EmbyCollectionProjection> _filtered() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items.where((it) {
      if (it.base.name.toLowerCase().contains(q)) return true;
      for (final id in it.accountIds) {
        final n = (_accountMap[id]?.name ?? id).toLowerCase();
        if (n.contains(q)) return true;
      }
      return false;
    }).toList(growable: false);
  }

  Future<void> _openProjection(_EmbyCollectionProjection p) async {
    await AppSettings.setLastFavoriteId(p.base.id);
    final embyOnly = p.base.copy()..sources = List<String>.from(p.embySources);
    final initialNav = await _initialEmbyNavForProjection(p);
    if (!mounted) return;
    final updated = await Navigator.push<FavoriteCollection>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderDetailPage(
          collection: embyOnly,
          initialNav: initialNav,
        ),
      ),
    );
    if (updated == null) return;
    final idx = _allCollections.indexWhere((e) => e.id == p.base.id);
    if (idx < 0) return;
    final merged = _allCollections[idx].copy();
    merged.layer1 = updated.layer1.copy();
    merged.layer2 = updated.layer2.copy();
    merged.sources = [
      ...merged.sources.where((s) => !isPageEmbySource(s)),
      ...updated.sources.where((s) => isPageEmbySource(s)),
    ];
    _allCollections[idx] = merged;
    await FavoriteStore.save(_allCollections);
    await _reload();
  }

  String _headerTitle() {
    if (_accountMap.isEmpty) return 'Emby';
    if (_accountMap.length == 1) return _accountMap.values.first.name;
    return 'Emby';
  }

  Map<String, List<_EmbyCollectionProjection>> _groupByAccount(
      List<_EmbyCollectionProjection> list) {
    final out = <String, List<_EmbyCollectionProjection>>{};
    for (final it in list) {
      final names = it.accountIds
          .map((id) => (_accountMap[id]?.name ?? id).trim())
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final key = names.isEmpty ? '媒体' : names.first;
      out.putIfAbsent(key, () => <_EmbyCollectionProjection>[]).add(it);
    }
    return out;
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF252D3D),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _sub,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _headerBar() {
    return Row(
      children: [
        IconButton(
          onPressed: () {},
          icon:
              const Icon(Icons.account_circle_outlined, color: _text, size: 30),
        ),
        Expanded(
          child: Text(
            _headerTitle(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: () => _openEmbyPageWithUi(context),
          icon: const Icon(Icons.settings_outlined, color: _text),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, {VoidCallback? onMore}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: _text,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (onMore != null)
          TextButton(
            onPressed: onMore,
            child: const Text('更多', style: TextStyle(color: _sub)),
          ),
      ],
    );
  }

  Widget _cover(List<String> sources) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox.expand(child: _MultiSourcePreview(sources)),
    );
  }

  Widget _shelfCard(_EmbyCollectionProjection p, {double width = 175}) {
    final accountNames =
        p.accountIds.map((id) => _accountMap[id]?.name ?? id).toList();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openProjection(p),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.62,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _cover(p.embySources),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              p.base.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _text, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip('来源 ${p.embySources.length}'),
                if (accountNames.isNotEmpty) _chip(accountNames.first),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stateView({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onAction,
    String actionLabel = '重试',
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _sub, size: 42),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _text, fontSize: 18)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _sub, fontSize: 13)),
            if (onAction != null) ...[
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF313C56)),
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _homeTab(List<_EmbyCollectionProjection> shown) {
    final grouped = _groupByAccount(shown);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 26),
        children: [
          _headerBar(),
          const SizedBox(height: 10),
          _sectionTitle('媒体库'),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            child: shown.isEmpty
                ? const Center(
                    child: Text('暂无媒体库',
                        style: TextStyle(color: _sub, fontSize: 13)))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _shelfCard(shown[i]),
                  ),
          ),
          const SizedBox(height: 8),
          _sectionTitle('继续观看'),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text('暂无可继续观看内容',
                  style: TextStyle(color: _sub, fontSize: 13)),
            )
          else
            Row(
              children: [
                Expanded(
                    child: _shelfCard(shown.first, width: double.infinity)),
                if (shown.length > 1) ...[
                  const SizedBox(width: 10),
                  Expanded(child: _shelfCard(shown[1], width: double.infinity)),
                ],
              ],
            ),
          const SizedBox(height: 14),
          for (final entry in grouped.entries) ...[
            _sectionTitle(entry.key),
            const SizedBox(height: 8),
            SizedBox(
              height: 170,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entry.value.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _shelfCard(entry.value[i]),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _searchTab(List<_EmbyCollectionProjection> shown) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              _headerBar(),
              const SizedBox(height: 10),
              TextField(
                style: const TextStyle(color: _text),
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: _panel,
                  hintText: '搜索收藏夹或 Emby 账号',
                  hintStyle: const TextStyle(color: _sub),
                  prefixIcon: const Icon(Icons.search, color: _sub),
                  suffixIcon: _query.trim().isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => setState(() => _query = ''),
                          icon: const Icon(Icons.close, color: _sub),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? _stateView(
                  icon: Icons.search_off_outlined,
                  title: '没有匹配结果',
                  subtitle: '试试其他关键词',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final it = shown[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openProjection(it),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 96,
                                height: 60,
                                child: _MultiSourcePreview(it.embySources),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                it.base.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    const TextStyle(color: _text, fontSize: 15),
                              ),
                            ),
                            const Icon(Icons.chevron_right, color: _sub),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _favoritesTab(List<_EmbyCollectionProjection> shown) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: _headerBar(),
        ),
        Expanded(
          child: shown.isEmpty
              ? _stateView(
                  icon: Icons.star_border_rounded,
                  title: '没有 Emby 收藏',
                  subtitle: '去收藏夹里添加 Emby 来源后再回来',
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  itemCount: shown.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.95,
                  ),
                  itemBuilder: (_, i) {
                    final it = shown[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openProjection(it),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _cover(it.embySources)),
                            const SizedBox(height: 8),
                            Text(
                              it.base.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(color: _text, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filtered();
    final body = () {
      if (_loading) {
        return const Center(
            child: CircularProgressIndicator(color: Colors.white));
      }
      if (_loadError != null) {
        return _stateView(
          icon: Icons.cloud_off_outlined,
          title: '加载 Emby 收藏夹失败',
          subtitle: friendlyErrorMessage(_loadError!),
          onAction: _reload,
        );
      }
      if (_items.isEmpty) {
        return _stateView(
          icon: Icons.video_library_outlined,
          title: '暂无 Emby 收藏夹',
          subtitle: '请先在收藏夹里添加 Emby 来源',
          onAction: () => _openEmbyPageWithUi(context),
          actionLabel: '去 Emby 设置',
        );
      }
      switch (_tab) {
        case 1:
          return _searchTab(shown);
        case 2:
          return _favoritesTab(shown);
        default:
          return _homeTab(shown);
      }
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _statusStyle,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(child: body),
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            color: _panel,
            border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
          ),
          child: SafeArea(
            top: false,
            child: BottomNavigationBar(
              backgroundColor: _panel,
              type: BottomNavigationBarType.fixed,
              currentIndex: _tab,
              selectedItemColor: _text,
              unselectedItemColor: _sub,
              selectedFontSize: 13,
              unselectedFontSize: 13,
              onTap: (i) => setState(() => _tab = i),
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined), label: '主页'),
                BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.star_outline_rounded), label: '收藏'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
