import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'image.dart';
import 'video.dart';
import 'webdav.dart';
import 'emby.dart';
import 'emby_exclusive_ui.dart';
import 'thumbnail_inspector.dart';
import 'models/favorite_models.dart';
import 'pages/folder_detail_controller.dart' as folder_detail_controller;
import 'pages/folder_detail_models.dart';
import 'pages_media_helpers.dart';
import 'pages_navigation_helpers.dart';
import 'pages_tag_navigation_helpers.dart';
import 'pages_tag_source_helpers.dart';
import 'stores/favorite_store.dart';
import 'tag_models.dart';

// 👇👇👇 重点修改这两行 👇👇👇
import 'utils.dart'; // 必须直接引入，去掉 "as utils"
import 'tag.dart';
import 'source_refs.dart';
// 👆👆👆 重点修改这两行 👆👆👆

part 'pages/settings_page.dart';
part 'pages/history_page.dart';
part 'pages/favorites_page.dart';
part 'pages/folder_cover_cache.dart';
part 'pages/folder_previews.dart';
part 'pages/folder_scope_search.dart';
part 'pages/folder_entry_helpers.dart';
part 'pages/folder_navigation_helpers.dart';
part 'pages/folder_load_helpers.dart';
part 'pages/folder_detail_rendering.dart';
part 'pages/folder_detail_toolbar.dart';
part 'pages/folder_detail_emby.dart';
part 'pages/folder_detail_cover_resolution.dart';
part 'pages/folder_detail_open_actions.dart';
part 'pages/shared_navigation_helpers.dart';
part 'pages/emby_only_favorites_page.dart';
part 'pages/dialog_helpers.dart';
// ===== app_pages.dart (auto-grouped) =====

// --- from pages.dart ---

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

bool _isImg(String path) => isPageImagePath(path);
bool _isVid(String path) => isPageVideoPath(path);

String _vmLabel(ViewMode v) => pageViewModeLabel(v);
String _skLabel(SortKey k) => pageSortKeyLabel(k);
IconData _vmIcon(ViewMode v) => pageViewModeIcon(v);
IconData _skIcon(SortKey k) => pageSortKeyIcon(k);
bool _isImgName(String name) => isPageImageName(name);
bool _isVidName(String name) => isPageVideoName(name);

int compareNaturalText(String a, String b) =>
    folder_detail_controller.compareNaturalText(a, b);

typedef _EmbyRef = EmbyPathSourceRef;
typedef _WebDavRef = WebDavSourceRef;

// 放在 const _imgExts = <String>{...} 这行代码的后面即可
extension CharExt on String {
  bool get isDigit => length == 1 && codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
}

/// =========================
/// FolderDetailPage
/// depth==0: virtual root (flatten sources first level)
/// depth>=1: real folder (use layer2 settings)
/// =========================
class FolderDetailPage extends StatefulWidget {
  final FavoriteCollection collection;

  /// 可选：用于从“历史记录/外部入口”直接打开到某个目录上下文。
  ///
  /// 设计原因：
  /// - 用户希望“点击图片后，把上级目录记入历史”，因此历史点击需要能还原到对应目录。
  /// - 为了最小改动，这里复用现有 FolderDetailPage 的导航栈，而不是新建一套页面。
  final NavCtx? initialNav;
  final bool exitOnInitialContextBack;
  const FolderDetailPage(
      {super.key,
      required this.collection,
      this.initialNav,
      this.exitOnInitialContextBack = false});
  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  late final folder_detail_controller.FolderDetailController _controller;
  final Map<String, Future<_CoverInfo?>> _dirCoverJobs =
      <String, Future<_CoverInfo?>>{};

  // ✅ Folder cover result cache (memory + SharedPreferences + TTL)
  _FolderCoverCache? _folderCoverCache;

  // 🔥 1. 新增：滚动控制器和位置记录
  final ScrollController _scrollController = ScrollController();
  final Map<int, double> _scrollOffsets = {};

  final List<NavCtx> _stack = const [NavCtx.root()].toList();
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

  bool get _usingScopeSearch =>
      _searchScope != FolderSearchScope.currentDirectory &&
      _q.trim().isNotEmpty;

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
      // ignore: unawaited_futures
      _persistSearchScopeSettings();
      _scheduleScopeSearch(immediate: true);
      return;
    }

    setState(() => _searchScope = picked);
    // ignore: unawaited_futures
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

  // ===== WebDAV 账号/Client 缓存（由 WebDavManager 统一驱动，避免 static 生命周期漏洞）=====
  final Map<String, WebDavAccount> _wdAccMap = <String, WebDavAccount>{};
  final Map<String, WebDavClient> _wdClientMap = <String, WebDavClient>{};
  bool _wdAccLoaded = false;

  // Scheme A: generate video thumbnails by downloading only a prefix into temp cache
  final bool _wdAutoVideoThumb = true;
  // WebDAV 远程缩略图前缀下载阈值：过大容易抢占带宽/连接，影响起播。
  // 2MB-4MB 通常足够覆盖大多数文件头部信息；遇到 moov 在尾部会由 probeMoovInTail 决定是否全量下载。
  final int _wdVideoThumbMaxBytes = 4 * 1024 * 1024; // 4MB
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
    } catch (_) {
      // ignore
    }
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
    // Turning OFF per-directory mode should fall back to one unified layer2.
    // Use current directory settings so the on-screen result does not jump.
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
      // In unified mode, folder display writes to collection.layer2.
      // In per-directory mode, active already points to a directory entry map.
      if (_stack.length > 1 && !_favoritePerDirectoryDisplaySettingsEnabled) {
        widget.collection.layer2 = active.copy();
      }
    });
    // ignore: unawaited_futures
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
    // ignore: unawaited_futures
    _loadSearchScopeSettings();
    // WebDAV 账号变化通知：清理缓存并重载
    WebDavManager.instance.addListener(_onWebDavAccountsChanged);
    // ignore: unawaited_futures
    _ensureWebDavAccountsLoaded();
    // ignore: unawaited_futures
    _loadFolderMediaCountCache();
    // ignore: unawaited_futures
    _ensureSearchCollectionsLoaded();

    // ✅ 历史/外部入口：支持直接进入指定目录上下文（尤其是 Emby 多级目录）。
    // 设计原因：
    // - HistoryPage 会把目录上下文写入 AppHistory；
    // - 点击“历史目录”时需要能还原到对应层级，否则会退化为根目录/全部内容，
    //   体验上就像“把整个目录都登记进历史”。
    final initNav = widget.initialNav;
    if (initNav != null && initNav.kind != CtxKind.root) {
      _stack.add(initNav);
    }

    // ignore: unawaited_futures
    _reloadDynamicSettings();
    _refresh();

    // Folder cover cache init (async)
    // ignore: unawaited_futures
    _initFolderCoverCache();
    // TagStore：用于标签筛选（隐藏式筛选面板）
    // ignore: unawaited_futures
    TagStore.I.ensureLoaded().then((_) => mounted ? setState(() {}) : null);
    TagStore.I.addListener(_onTagStoreChanged);
  }

  Future<void> _initFolderCoverCache() async {
    try {
      final c = await _FolderCoverCache.init(ttl: const Duration(hours: 12));
      if (!mounted) return;
      setState(() => _folderCoverCache = c);
    } catch (_) {
      // ignore
    }
  }

  void _onWebDavAccountsChanged() {
    // 账号增删改后：清空失效 Client/缩略图任务缓存，避免使用旧 Token
    _wdAccLoaded = false;
    _wdAccMap.clear();
    _wdClientMap.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchCache.clear();
    _clearScopeSearchState();
    if (mounted) {
      // ignore: unawaited_futures
      _refresh();
    }
  }

  void _onTagStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    WebDavManager.instance.removeListener(_onWebDavAccountsChanged);
    TagStore.I.removeListener(_onTagStoreChanged);
    _dirCoverJobs.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchDebounce?.cancel();
    _scrollController.dispose(); // 🔥 2. 新增：销毁控制器
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
    } catch (_) {
      // ignore
    }
    _folderMediaCountLoaded = true;
  }

  Future<void> _saveFolderMediaCountCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          'folder_media_count_cache_v1', jsonEncode(_folderMediaCountCache));
    } catch (_) {
      // ignore
    }
  }

  Future<void> _refresh({bool showGlobalLoading = true}) async {
    if (showGlobalLoading) {
      setState(() => _loading = true);
    }
    final cur = _stack.last;
    final list = switch (cur.kind) {
      CtxKind.root => await _loadVirtual(),
      CtxKind.local => await _loadLocalDir(cur.localDir!),
      CtxKind.webdav => await _loadWebDavDir(cur.wdAccountId!, cur.wdRel),
      CtxKind.emby => await _loadEmby(cur.embyAccountId!, cur.embyPath),
    };
    // Update media count cache for current folder (used for skeleton prefill)
    _updateFolderCountCacheFromList(cur, list);
    if (!mounted) return;
    setState(() {
      _raw = list;
      _controller.raw = list;
      _loading = false;
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

    // ✅ Emby：当用户正在使用“按大小排序”时，按需补全 size=0 的条目，
    // 让排序真正对 Emby 文件数据生效。
    // ignore: unawaited_futures
    _hydrateEmbySizesIfNeeded();
  }

  Future<void> _hydrateEmbySizesIfNeeded({int maxItems = 60}) async {
    if (_embySizeHydrating) return;
    if (_stack.isEmpty) return;
    final cur = _stack.last;
    if (cur.kind != CtxKind.emby) return;
    if (_active.sortKey != SortKey.size) return;

    final accId = (cur.embyAccountId ?? '').trim();
    if (accId.isEmpty) return;

    // 只处理“需要补全”的条目；避免对目录、占位 skeleton 造成干扰。
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

    // 分批并发（轻量）：避免一次性开太多 HTTP 连接。
    const int batch = 6;
    final Map<String, int> updates = <String, int>{}; // key: itemId

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
            } catch (_) {
              // 单条失败不影响整体。
            }
          }());
        }
        if (futures.isNotEmpty) {
          await Future.wait(futures);
        }
      }
    } catch (_) {
      // 静默失败：不影响主流程/浏览。
    } finally {
      _embySizeHydrating = false;
    }

    if (!mounted) return;
    if (updates.isEmpty) return;

    // 把补全结果写回 _raw（保持其它字段不变）。
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
          setState(() {}); // ✅ 刷新当前列表项
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
        setState(() {}); // 让 TagChipsBar / 列表过滤即时刷新
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

      // 刷新数据（UI 会经历 loading 态）
      await _refresh();

      // 🔥 6. 核心：等 UI 渲染完毕后，恢复上一级的位置
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

    // ✅ 当用户切换到“按大小排序”且当前为 Emby 目录时，按需补全 size=0。
    // ignore: unawaited_futures
    _hydrateEmbySizesIfNeeded();
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
        ? const AppLoadingState()
        : (scopedLoading && list.isEmpty)
            ? const AppLoadingState()
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
                        child: _buildByMode(list, imgs, vids),
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

/// =========================
/// Cover preview (local: root media else child media)
/// WebDAV sources: 已支持加载预览图
/// =========================
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined));
}

class _ProportionalPreviewBox extends StatelessWidget {
  final Widget child;
  const _ProportionalPreviewBox({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: child,
      ),
    );
  }
}
