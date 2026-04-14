part of '../pages.dart';

class _HistoryInteractiveCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  const _HistoryInteractiveCard({
    required this.child,
    required this.onTap,
    required this.borderRadius,
  });

  @override
  State<_HistoryInteractiveCard> createState() =>
      _HistoryInteractiveCardState();
}

class _HistoryInteractiveCardState extends State<_HistoryInteractiveCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.988 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: InkWell(
        borderRadius: widget.borderRadius,
        onTap: widget.onTap,
        onHighlightChanged: _setPressed,
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.03),
        child: widget.child,
      ),
    );
  }
}

/// =========================
/// HistoryPage (新：播放历史)
/// =========================
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _loading = true;
  bool _reloading = false;
  Object? _loadError;
  List<Map<String, dynamic>> _list = <Map<String, dynamic>>[];

  late final Future<Map<String, EmbyAccount>> _embyAccMapFuture;

  @override
  void initState() {
    super.initState();
    _embyAccMapFuture = _loadEmbyAccountsMap();
    _reload();
  }

  Future<Map<String, EmbyAccount>> _loadEmbyAccountsMap() async {
    final list = await EmbyStore.load();
    return {for (final a in list) a.id: a};
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    try {
      final list = await AppHistory.load();
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
    } finally {
      _reloading = false;
    }
  }

  String _fmtTime(int ms) {
    try {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    } catch (_) {
      return '';
    }
  }

  String _fmtPos(int? posMs) {
    if (posMs == null || posMs <= 0) return '';
    final s = (posMs / 1000).floor();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    if (h > 0) return '$h小时$m分$ss秒';
    if (m > 0) return '$m分$ss秒';
    return '$ss秒';
  }

  bool _isWebDavPath(String path) => isWebDavSource(path);
  bool _isEmbyPath(String path) => isEmbySource(path);

  Widget _fadeInImage(Widget child, {Object? keySeed}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: KeyedSubtree(
        key: ValueKey(keySeed ?? child.runtimeType),
        child: child,
      ),
    );
  }

  Widget _animatedFileImage(
    File file, {
    required Widget errorFallback,
    BoxFit fit = BoxFit.cover,
  }) {
    return Image.file(
      file,
      fit: fit,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, wasSyncLoaded) {
        return AnimatedOpacity(
          opacity: frame == null && !wasSyncLoaded ? 0 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: child,
        );
      },
      errorBuilder: (_, __, ___) => errorFallback,
    );
  }

  Widget _animatedNetworkImage(String url, {required Widget errorFallback}) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 160),
      fadeOutDuration: const Duration(milliseconds: 80),
      placeholder: (_, __) => errorFallback,
      errorWidget: (_, __, ___) => errorFallback,
    );
  }

  Widget _historyCover(String kind, String path, String? coverPath) {
    final radius = BorderRadius.circular(10);

    if (kind == 'fav' || kind == 'folder') {
      final cp = (coverPath ?? '').trim();
      if (cp.isNotEmpty) {
        if (isPageImagePath(cp)) {
          return _fadeInImage(
            ClipRRect(
              borderRadius: radius,
              child: _animatedFileImage(
                File(cp),
                fit: BoxFit.cover,
                errorFallback: const _FolderPreviewBox(),
              ),
            ),
            keySeed: cp,
          );
        }
        if (isPageVideoPath(cp)) {
          return ClipRRect(
              borderRadius: radius, child: VideoThumbImage(videoPath: cp));
        }
      }
      return const _FolderPreviewBox();
    }

    if (_isEmbyPath(path)) {
      final m = RegExp(r'^emby://([^/]+)/item:([^/?#]+)').firstMatch(path);
      final accId = m?.group(1) ?? '';
      final itemId = m?.group(2) ?? '';

      if (accId.isNotEmpty && itemId.isNotEmpty) {
        return FutureBuilder<Map<String, EmbyAccount>>(
          future: _embyAccMapFuture,
          builder: (c, snap) {
            final m = snap.data;
            final a = m == null ? null : m[accId];
            if (a == null) return const _CoverPlaceholder();
            final client = EmbyClient(a);
            final url = client.coverUrl(itemId,
                type: 'Primary', maxWidth: 320, quality: 85);
            return _fadeInImage(
              ClipRRect(
                borderRadius: radius,
                child: _animatedNetworkImage(
                  url,
                  errorFallback: const _CoverPlaceholder(),
                ),
              ),
              keySeed: url,
            );
          },
        );
      }
      return const _CoverPlaceholder();
    }

    if (_isWebDavPath(path)) {
      final m = RegExp(r'^webdav://([^/]+)/(.+)$').firstMatch(path);
      final accId = m?.group(1) ?? '';
      final rel = m?.group(2) ?? '';

      if (accId.isEmpty || rel.isEmpty) return const _CoverPlaceholder();

      return FutureBuilder<File?>(
        future: () async {
          try {
            final mgr = WebDavManager.instance;
            if (!mgr.isLoaded) {
              await mgr.reload(notify: false);
            }
            final acc = mgr.getAccount(accId);
            if (acc == null) return null;

            final client = WebDavClient(acc);
            final parent = p.dirname(rel);
            final name = p.basename(rel);
            final list = await client.list(parent == '.' ? '' : parent);
            final it = list.firstWhere((x) => x.name == name,
                orElse: () => WebDavItem(
                    name: name,
                    href: '',
                    relPath: rel,
                    isDir: false,
                    size: 0,
                    modified: DateTime.now()));
            final href = it.href.trim().isEmpty
                ? client.resolveRel(rel).toString()
                : it.href;

            if (href.trim().isEmpty) return null;

            final prefix = await client.ensureCachedForThumb(href, name,
                maxBytes: 4 * 1024 * 1024);
            if (!await prefix.exists()) return null;
            final thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
                prefix.path, Duration.zero);
            return thumb;
          } catch (_) {
            return null;
          }
        }(),
        builder: (c, snap) {
          final f = snap.data;
          if (f != null) {
            return _fadeInImage(
              ClipRRect(
                borderRadius: radius,
                child: _animatedFileImage(
                  f,
                  fit: BoxFit.cover,
                  errorFallback: const _CoverPlaceholder(),
                ),
              ),
              keySeed: f.path,
            );
          }
          return const _CoverPlaceholder();
        },
      );
    }

    final isImg = isPageImagePath(path);
    if (isImg) {
      return _fadeInImage(
        ClipRRect(
          borderRadius: radius,
          child: _animatedFileImage(
            File(path),
            fit: BoxFit.cover,
            errorFallback: const _CoverPlaceholder(),
          ),
        ),
        keySeed: path,
      );
    }
    if (isPageVideoPath(path)) {
      return ClipRRect(
          borderRadius: radius, child: VideoThumbImage(videoPath: path));
    }
    return const _CoverPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: Scaffold(
        appBar: GlassAppBar(
          title: const Text('历史记录'),
          actions: [
            IconButton(
                onPressed: _reloading ? null : _reload,
                icon: const Icon(Icons.refresh),
                tooltip: '刷新'),
          ],
        ),
        body: _loading
            ? const AppLoadingState()
            : _loadError != null
                ? AppErrorState(
                    title: '加载历史失败',
                    details: friendlyErrorMessage(_loadError!),
                    onRetry: _reload,
                  )
                : _list.isEmpty
                    ? const AppEmptyState(
                        title: '暂无历史记录',
                        subtitle: '播放媒体后会自动出现在这里',
                        icon: Icons.history_toggle_off,
                      )
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: AppViewport(
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            itemCount: _list.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final e = _list[i];
                              final kind =
                                  (e['kind'] ?? 'media').toString().trim();
                              final title =
                                  (e['title'] ?? '').toString().trim();
                              final path = (e['path'] ?? '').toString().trim();
                              final cover =
                                  (e['cover'] ?? '').toString().trim();
                              final favId =
                                  (e['favId'] ?? '').toString().trim();
                              final t =
                                  int.tryParse((e['t'] ?? '').toString()) ?? 0;
                              final pos =
                                  int.tryParse((e['pos'] ?? '').toString());
                              final posText = _fmtPos(pos);

                              return Card(
                                elevation: 0,
                                child: _HistoryInteractiveCard(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () {
                                    if (path.isEmpty) return;
                                    if (kind == 'fav') {
                                      _openFavoriteFromHistory(favId);
                                      return;
                                    }
                                    if (kind == 'folder') {
                                      _openFolderFromHistory(e);
                                      return;
                                    }

                                    if (!_isWebDavPath(path) &&
                                        !_isEmbyPath(path) &&
                                        isPageImagePath(path)) {
                                      Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => ImageViewerPage(
                                                  imagePaths: [path],
                                                  initialIndex: 0)));
                                      return;
                                    }

                                    Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => VideoPlayerPage(
                                                videoPaths: [path],
                                                initialIndex: 0)));
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                            width: 120,
                                            height: 68,
                                            child: _historyCover(
                                                kind, path, cover)),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                title.isEmpty ? '未命名文件' : title,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.w600),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                [
                                                  if (t > 0) _fmtTime(t),
                                                  if (kind != 'fav' &&
                                                      posText.isNotEmpty)
                                                    '进度：$posText',
                                                  if (kind == 'fav') '收藏夹',
                                                  if (kind == 'folder') '目录',
                                                ]
                                                    .where((s) =>
                                                        s.trim().isNotEmpty)
                                                    .join(' · '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .hintColor),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '删除',
                                          icon: const Icon(Icons.close),
                                          onPressed: () async {
                                            await AppHistory.removeAt(i);
                                            await _reload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
      ),
    );
  }

  Future<void> _openFavoriteFromHistory(String favId) async {
    if (favId.trim().isEmpty) return;
    try {
      final list = await FavoriteStore.load();
      final c = list.firstWhere(
        (x) => x.id == favId,
        orElse: () => FavoriteCollection(
            id: '',
            name: '',
            sources: const [],
            layer1: LayerSettings(),
            layer2: LayerSettings()),
      );
      if (!mounted) return;
      if (c.id.isEmpty) {
        showAppToast(context, '收藏夹不存在/已删除', error: true);
        return;
      }
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => FolderDetailPage(collection: c.copy())));
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '打开收藏夹失败', error: true);
    }
  }

  Future<void> _openFolderFromHistory(Map<String, dynamic> e) async {
    try {
      final kind = (e['ctxKind'] ?? '').toString().trim();
      if (kind.isEmpty) return;

      final title = (e['title'] ?? '').toString().trim();

      late final NavCtx nav;
      late final String source;

      if (kind == 'local') {
        final dir = (e['localDir'] ?? '').toString().trim();
        if (dir.isEmpty) return;
        nav = NavCtx.local(dir, title: title.isEmpty ? null : title);
        source = dir;
      } else if (kind == 'webdav') {
        final accId = (e['wdAccountId'] ?? '').toString().trim();
        final rel = (e['wdRel'] ?? '').toString().trim();
        if (accId.isEmpty) return;
        final rel2 = rel.isEmpty ? '' : (rel.endsWith('/') ? rel : '$rel/');
        nav = NavCtx.webdav(
            wdAccountId: accId,
            wdRel: rel2,
            title: title.isEmpty ? null : title);
        source = buildPageWebDavSource(accId, rel2, isDir: true);
      } else if (kind == 'emby') {
        final accId = (e['embyAccountId'] ?? '').toString().trim();
        final pth = (e['embyPath'] ?? '').toString().trim();
        if (accId.isEmpty) return;
        nav = NavCtx.emby(
          embyAccountId: accId,
          embyPath: pth.isEmpty ? 'favorites' : pth,
          title: title.isEmpty ? null : title,
        );
        source = buildEmbySource(accId, pth.isEmpty ? 'favorites' : pth);
      } else {
        return;
      }

      final col = FavoriteCollection(
        id: '__history_folder__',
        name: title.isEmpty ? '目录' : title,
        sources: [source],
        layer1: LayerSettings(),
        layer2: LayerSettings(viewMode: ViewMode.list),
      );

      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  FolderDetailPage(collection: col, initialNav: nav)));
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '打开目录失败', error: true);
    }
  }
}
