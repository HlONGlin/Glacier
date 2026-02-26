import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby.dart';
import 'image.dart';
import 'ui_kit.dart';
import 'utils.dart';
import 'video.dart';

typedef EmbyFolderOpener = Future<void> Function(
  BuildContext context, {
  required String title,
  required String source,
});

typedef EmbySettingsOpener = Future<void> Function(BuildContext context);

enum _EmbyPaletteMode { exclusive, classic }

enum _EmbyHomeTab { home, favorites, search }

const String _kEmbyPalettePrefKey = 'emby_exclusive_palette_v1';
const String _kEmbyFolderDisplayGlobalPrefKey =
    'emby_exclusive_folder_display_global_v1';
const String _kEmbyFolderDisplayPerDirPrefix = 'embyui://';

const SystemUiOverlayStyle _kStatusStyleDark = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

const SystemUiOverlayStyle _kStatusStyleLight = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

class _EmbyPalette {
  final Color bg;
  final Color panel;
  final Color text;
  final Color sub;
  final Color coverPlaceholderBg;
  final Color coverPlaceholderIcon;
  final Color chipBg;
  final Color chipSelectedBg;
  final Color progress;
  final SystemUiOverlayStyle statusStyle;

  const _EmbyPalette({
    required this.bg,
    required this.panel,
    required this.text,
    required this.sub,
    required this.coverPlaceholderBg,
    required this.coverPlaceholderIcon,
    required this.chipBg,
    required this.chipSelectedBg,
    required this.progress,
    required this.statusStyle,
  });
}

const _EmbyPalette _kExclusivePalette = _EmbyPalette(
  bg: Color(0xFF0C111A),
  panel: Color(0xFF171D2A),
  text: Color(0xFFF2F5FF),
  sub: Color(0xFF97A0B6),
  coverPlaceholderBg: Color(0xFF222B3F),
  coverPlaceholderIcon: Color(0xFFB7C0D9),
  chipBg: Color(0xFF2A2D33),
  chipSelectedBg: Color(0xFF5D6067),
  progress: Colors.white,
  statusStyle: _kStatusStyleDark,
);

const _EmbyPalette _kClassicPalette = _EmbyPalette(
  bg: AppThemeColors.bg,
  panel: Colors.white,
  text: AppThemeColors.text,
  sub: AppThemeColors.subtext,
  coverPlaceholderBg: Color(0xFFE6EDF5),
  coverPlaceholderIcon: Color(0xFF7689A0),
  chipBg: Color(0xFFE3EAF2),
  chipSelectedBg: Color(0xFFCAD8E8),
  progress: AppThemeColors.seed,
  statusStyle: _kStatusStyleLight,
);

_EmbyPalette _paletteForMode(_EmbyPaletteMode mode) {
  switch (mode) {
    case _EmbyPaletteMode.classic:
      return _kClassicPalette;
    case _EmbyPaletteMode.exclusive:
      return _kExclusivePalette;
  }
}

String _paletteLabel(_EmbyPaletteMode mode) {
  switch (mode) {
    case _EmbyPaletteMode.exclusive:
      return '\u4e13\u5c5e\u6697\u8272';
    case _EmbyPaletteMode.classic:
      return '\u539f\u7248\u6e05\u900f';
  }
}

bool _embyTypeIsDir(String t) {
  final raw = t.trim().toLowerCase();
  if (raw.isEmpty) return false;
  return raw.contains('folder') ||
      raw.contains('album') ||
      raw.contains('collection') ||
      raw.contains('boxset') ||
      raw.contains('season') ||
      raw.contains('series') ||
      raw.contains('view') ||
      raw.contains('playlist');
}

bool _embyTypeIsImage(String t) {
  final raw = t.trim().toLowerCase();
  if (raw.isEmpty || _embyTypeIsDir(raw)) return false;
  return raw.contains('photo') ||
      raw.contains('image') ||
      raw.contains('picture');
}

bool _embyTypeIsMovie(String t) {
  final raw = t.trim().toLowerCase();
  if (raw.isEmpty || _embyTypeIsDir(raw) || _embyTypeIsImage(raw)) {
    return false;
  }
  return raw.contains('movie');
}

bool _embyItemIsDir(EmbyItem item) {
  if (_embyTypeIsImage(item.type)) return false;
  if (_embyTypeIsMovie(item.type)) return false;
  final mediaType = (item.mediaType ?? '').trim().toLowerCase();
  if (mediaType == 'video') return false;
  return item.isFolder || _embyTypeIsDir(item.type);
}

bool _looksLikeMovieFolder(EmbyItem item) {
  if (!(item.isFolder || _embyTypeIsDir(item.type))) return false;
  final type = item.type.trim().toLowerCase();
  if (type.contains('series') || type.contains('season')) return false;
  if (_embyTypeIsMovie(type)) return true;

  final mediaType = (item.mediaType ?? '').trim().toLowerCase();
  if (mediaType == 'video') return true;

  final name = item.name.trim().toLowerCase();
  if (name.contains('tmdbid=') ||
      name.contains('imdbid=') ||
      name.contains('tvdbid=') ||
      name.contains('doubanid=')) {
    return true;
  }

  final year = item.productionYear ?? 0;
  if (year >= 1900 && year <= 2100) {
    final hasSeasonHint =
        name.contains('season') || RegExp(r'\bs\d{1,2}\b').hasMatch(name);
    return !hasSeasonHint;
  }
  return false;
}

String _movieCoverUrlFor(
  EmbyClient client,
  EmbyItem item, {
  int maxWidth = 420,
}) {
  final itemId = item.id.trim();
  if (itemId.isEmpty) return '';

  final preferredWidth = maxWidth < 420 ? 420 : maxWidth;
  final primaryTag = (item.primaryTag ?? '').trim();
  if (primaryTag.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Primary',
      maxWidth: preferredWidth,
      quality: 86,
      tag: primaryTag,
    );
  }

  final thumbTag = (item.thumbTag ?? '').trim();
  if (thumbTag.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Thumb',
      maxWidth: preferredWidth,
      quality: 84,
      tag: thumbTag,
    );
  }

  if (item.backdropTags.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Backdrop',
      index: 0,
      maxWidth: preferredWidth < 760 ? 760 : preferredWidth,
      quality: 82,
      tag: item.backdropTags.first,
    );
  }

  return client.coverUrl(
    itemId,
    type: 'Primary',
    maxWidth: preferredWidth,
    quality: 84,
  );
}

String _coverUrlFor(EmbyClient client, EmbyItem item, {int maxWidth = 420}) {
  if (_embyTypeIsMovie(item.type)) {
    final movieCover = _movieCoverUrlFor(client, item, maxWidth: maxWidth);
    if (movieCover.trim().isNotEmpty) return movieCover;
  }
  return client.bestCoverUrl(item, maxWidth: maxWidth);
}

String _videoPathFor(_UiItem it) {
  return 'emby://${it.account.id}/item:${it.item.id}?name=${Uri.encodeComponent(it.title)}';
}

String _imageSourceKeyFor(_UiItem it) {
  return 'emby://${it.account.id}/item:${it.item.id}';
}

String _preferOriginalUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  try {
    final u = Uri.parse(raw);
    final qp = Map<String, String>.from(u.queryParameters);
    qp.removeWhere((k, _) {
      final lk = k.toLowerCase();
      return lk == 'maxwidth' || lk == 'maxheight' || lk == 'quality';
    });
    return qp.isEmpty
        ? u.replace(query: '').toString()
        : u.replace(queryParameters: qp).toString();
  } catch (_) {
    return raw;
  }
}

class EmbyExclusiveFavoritesPage extends StatefulWidget {
  final EmbyFolderOpener openFolder;
  final EmbySettingsOpener? openSettings;
  final Set<String>? accountIds;

  const EmbyExclusiveFavoritesPage({
    super.key,
    required this.openFolder,
    this.openSettings,
    this.accountIds,
  });

  @override
  State<EmbyExclusiveFavoritesPage> createState() =>
      _EmbyExclusiveFavoritesPageState();
}

class _UiItem {
  final EmbyAccount account;
  final EmbyItem item;
  final bool isDir;
  final bool isImage;
  final String coverUrl;

  const _UiItem({
    required this.account,
    required this.item,
    required this.isDir,
    required this.isImage,
    required this.coverUrl,
  });

  String get title =>
      item.name.trim().isEmpty ? '\u672a\u547d\u540d' : item.name.trim();
}

class _Section {
  final EmbyAccount account;
  final EmbyItem view;
  final List<_UiItem> items;
  const _Section(
      {required this.account, required this.view, required this.items});
}

class _EmbyExclusiveFavoritesPageState
    extends State<EmbyExclusiveFavoritesPage> {
  static const Duration _kHomeRequestTimeout = Duration(seconds: 6);
  static const Duration _kHomeSectionTimeout = Duration(seconds: 8);
  static const int _kHomeSectionViewLimit = 5;
  static const int _kHomeSectionWorkers = 3;
  static const int _kHomeSectionFetchLimit = 72;
  static const int _kSearchResultLimit = 80;

  bool _loading = true;
  bool _searching = false;
  bool _favoritesLoading = false;
  Object? _loadError;
  Object? _searchError;
  String _query = '';
  int _searchSeq = 0;
  Timer? _searchDebounce;

  List<EmbyAccount> _accounts = const <EmbyAccount>[];
  Map<String, EmbyClient> _clients = const <String, EmbyClient>{};
  List<_UiItem> _libraries = const <_UiItem>[];
  List<_UiItem> _resume = const <_UiItem>[];
  List<_UiItem> _favorites = const <_UiItem>[];
  List<_Section> _sections = const <_Section>[];
  List<_UiItem> _searchResults = const <_UiItem>[];
  String? _selectedAccountId;
  _EmbyPaletteMode _paletteMode = _EmbyPaletteMode.classic;
  _EmbyHomeTab _homeTab = _EmbyHomeTab.home;
  bool _sectionsLoading = false;
  int _reloadToken = 0;
  final Set<String> _loadedAccountIds = <String>{};
  final Map<String, int> _latestPreferredStrategy = <String, int>{};
  final Map<String, Set<int>> _latestBlockedStrategies = <String, Set<int>>{};
  final Map<String, String> _folderCoverUrlCache = <String, String>{};
  final Map<String, Future<String?>> _folderCoverInflight =
      <String, Future<String?>>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadPaletteMode());
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  _EmbyPalette get _palette => _paletteForMode(_paletteMode);

  Future<void> _loadPaletteMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = (prefs.getString(_kEmbyPalettePrefKey) ?? '').trim();
      var mode = _EmbyPaletteMode.classic;
      for (final x in _EmbyPaletteMode.values) {
        if (x.name == raw) {
          mode = x;
          break;
        }
      }
      if (!mounted) return;
      setState(() => _paletteMode = mode);
    } catch (_) {}
  }

  Future<void> _setPaletteMode(_EmbyPaletteMode mode) async {
    if (_paletteMode == mode) return;
    if (!mounted) return;
    setState(() => _paletteMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEmbyPalettePrefKey, mode.name);
    } catch (_) {}
  }

  _UiItem _toUiItem(EmbyAccount account, EmbyClient client, EmbyItem item,
      {int maxWidth = 420}) {
    final isDir = _embyItemIsDir(item);
    final isImage = !isDir && _embyTypeIsImage(item.type);
    return _UiItem(
      account: account,
      item: item,
      isDir: isDir,
      isImage: isImage,
      coverUrl: _coverUrlFor(client, item, maxWidth: maxWidth),
    );
  }

  Future<String?> _resolveFolderCoverFallback(
    _UiItem item, {
    int maxWidth = 520,
  }) async {
    if (!item.isDir) return null;
    final accId = item.account.id.trim();
    final folderId = item.item.id.trim();
    if (accId.isEmpty || folderId.isEmpty) return null;
    final key = '$accId:$folderId';

    final cached = (_folderCoverUrlCache[key] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    final inflight = _folderCoverInflight[key];
    if (inflight != null) return await inflight;

    final fut = (() async {
      final client = _clients[accId];
      if (client == null) return null;
      try {
        final auto = await client.pickAutoFolderCoverUrl(
          folderId: folderId,
          maxWidth: maxWidth,
          quality: 85,
          fallbackToVideo: true,
        );
        final url = (auto ?? '').trim();
        if (url.isNotEmpty) {
          _folderCoverUrlCache[key] = url;
          return url;
        }
      } catch (_) {}
      return null;
    })();

    _folderCoverInflight[key] = fut;
    try {
      return await fut;
    } finally {
      _folderCoverInflight.remove(key);
    }
  }

  List<_UiItem> _unique(List<_UiItem> src) {
    final seen = <String>{};
    final out = <_UiItem>[];
    for (final x in src) {
      final id = x.item.id.trim();
      if (id.isEmpty) continue;
      final key = '${x.account.id}:$id';
      if (seen.add(key)) out.add(x);
    }
    return out;
  }

  bool _isEpisodeItem(EmbyItem item) {
    final t = item.type.trim().toLowerCase();
    return t == 'episode' || t.contains('episode');
  }

  EmbyItem _seriesFromEpisode(EmbyItem episode) {
    final sid = (episode.seriesId ?? '').trim();
    final sname = (episode.seriesName ?? '').trim();
    return EmbyItem(
      id: sid,
      name: sname.isEmpty ? episode.name : sname,
      type: 'Series',
      isFolder: true,
      dateCreated: episode.dateCreated,
      dateModified: episode.dateModified,
    );
  }

  List<EmbyItem> _collapseLatestEpisodesToSeries(List<EmbyItem> src) {
    final out = <EmbyItem>[];
    final seenSeries = <String>{};
    final seenItems = <String>{};
    for (final item in src) {
      final id = item.id.trim();
      if (id.isEmpty) continue;

      if (_isEpisodeItem(item)) {
        final sid = (item.seriesId ?? '').trim();
        if (sid.isNotEmpty) {
          if (!seenSeries.add(sid)) continue;
          if (!seenItems.add(sid)) continue;
          out.add(_seriesFromEpisode(item));
          continue;
        }
      }

      if (!seenItems.add(id)) continue;
      out.add(item);
    }
    return out;
  }

  bool _isSeriesType(EmbyItem item) {
    final t = item.type.trim().toLowerCase();
    return t == 'series' || t.contains('series');
  }

  Future<List<EmbyItem>> _safeItemsRequest(
    Future<List<EmbyItem>> task, {
    Duration timeout = _kHomeRequestTimeout,
  }) async {
    try {
      return await task.timeout(timeout);
    } catch (_) {
      return const <EmbyItem>[];
    }
  }

  Future<List<EmbyItem>> _latestSectionChildren(
    EmbyClient c,
    String viewId,
  ) async {
    const includeTypes = 'Movie,Episode,Video,MusicVideo,Photo,Series,Season';
    final accountKey = c.account.id;
    final blocked =
        _latestBlockedStrategies.putIfAbsent(accountKey, () => <int>{});

    final strategies = <Future<List<EmbyItem>> Function()>[
      () => c
          .listLatestItems(
            parentId: viewId,
            includeItemTypes: includeTypes,
            limit: _kHomeSectionFetchLimit,
          )
          .timeout(_kHomeRequestTimeout),
      () => c
          .listChildren(
            parentId: viewId,
            recursive: true,
            sortBy: 'DateCreated',
            sortOrder: 'Descending',
            includeItemTypes: includeTypes,
            limit: _kHomeSectionFetchLimit,
          )
          .timeout(_kHomeRequestTimeout),
      () => c
          .listChildren(
            parentId: viewId,
            recursive: true,
            sortBy: 'DateModified',
            sortOrder: 'Descending',
            includeItemTypes: includeTypes,
            limit: _kHomeSectionFetchLimit,
          )
          .timeout(_kHomeRequestTimeout),
      () => c
          .listChildren(
            parentId: viewId,
            recursive: true,
            sortBy: 'DateModified',
            sortOrder: 'Descending',
            limit: _kHomeSectionFetchLimit,
          )
          .timeout(_kHomeRequestTimeout),
    ];

    Future<List<EmbyItem>?> tryAt(int idx) async {
      if (idx < 0 || idx >= strategies.length) return null;
      if (blocked.contains(idx)) return null;
      try {
        final out = await strategies[idx]();
        if (out.isNotEmpty) {
          _latestPreferredStrategy[accountKey] = idx;
        }
        return out;
      } catch (_) {
        blocked.add(idx);
        return null;
      }
    }

    final preferred = _latestPreferredStrategy[accountKey];
    if (preferred != null) {
      final out = await tryAt(preferred);
      if (out != null && out.isNotEmpty) return out;
    }

    for (var i = 0; i < strategies.length; i++) {
      if (i == preferred) continue;
      final out = await tryAt(i);
      if (out != null && out.isNotEmpty) return out;
    }
    return const <EmbyItem>[];
  }

  Future<_Section?> _loadSectionForView(
    EmbyAccount a,
    EmbyClient c,
    EmbyItem v,
  ) async {
    final viewId = v.id.trim();
    if (viewId.isEmpty) return null;

    final children = await _latestSectionChildren(c, viewId);
    if (children.isEmpty) return null;

    final latest = _collapseLatestEpisodesToSeries(children);
    final seriesIds = latest
        .where(_isSeriesType)
        .where((e) =>
            e.primaryTag == null &&
            e.thumbTag == null &&
            e.backdropTags.isEmpty)
        .map((e) => e.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(24)
        .toList(growable: false);

    var seriesMap = <String, EmbyItem>{};
    if (seriesIds.isNotEmpty) {
      try {
        final resolved =
            await c.listItemsByIds(seriesIds).timeout(_kHomeRequestTimeout);
        seriesMap = {
          for (final item in resolved)
            if (item.id.trim().isNotEmpty) item.id.trim(): item,
        };
      } catch (_) {}
    }

    final latestResolved = latest.map((e) {
      final id = e.id.trim();
      if (id.isEmpty) return e;
      if (!_isSeriesType(e)) return e;
      return seriesMap[id] ?? e;
    }).toList(growable: false);

    var items = latestResolved
        .where((e) {
          if (_isSeriesType(e)) return true;
          final isDir = _embyItemIsDir(e);
          if (isDir) return false;
          if (_embyTypeIsImage(e.type)) return true;
          final mediaType = (e.mediaType ?? '').trim().toLowerCase();
          if (mediaType.isEmpty) return true;
          return mediaType == 'video';
        })
        .take(30)
        .map((e) => _toUiItem(a, c, e, maxWidth: 420))
        .toList(growable: false);

    // Folder-only NAS libraries may not contain video/image media types.
    // Fallback to top-level folders so the section is still clickable.
    if (items.isEmpty) {
      items = latestResolved
          .where(_embyItemIsDir)
          .take(18)
          .map((e) => _toUiItem(a, c, e, maxWidth: 420))
          .toList(growable: false);
    }

    if (items.isEmpty) return null;
    return _Section(account: a, view: v, items: items);
  }

  Future<List<_Section>> _loadLatestSections(
    EmbyAccount a,
    EmbyClient c,
    List<EmbyItem> views,
  ) async {
    final candidates = views
        .where((v) => v.id.trim().isNotEmpty)
        .take(_kHomeSectionViewLimit)
        .toList(growable: false);
    if (candidates.isEmpty) return const <_Section>[];

    final out = <_Section>[];
    var cursor = 0;
    final workerCount = candidates.length < _kHomeSectionWorkers
        ? candidates.length
        : _kHomeSectionWorkers;

    Future<void> worker() async {
      while (true) {
        if (cursor >= candidates.length) return;
        final idx = cursor++;
        final sec = await _loadSectionForView(a, c, candidates[idx]);
        if (sec != null) out.add(sec);
      }
    }

    try {
      await Future.wait(
        List.generate(workerCount, (_) => worker()),
      ).timeout(_kHomeSectionTimeout);
    } catch (_) {}
    return out;
  }

  Future<({List<_UiItem> lib, List<_UiItem> resume, List<EmbyItem> views})>
      _loadAccountData(EmbyAccount a, EmbyClient c) async {
    final loaded = await Future.wait<List<EmbyItem>>([
      _safeItemsRequest(c.listViews()),
      _safeItemsRequest(c.listResumeItems(limit: 20)),
    ]);
    final views = loaded[0];
    final resume = loaded[1];

    final libOut = views.map((e) => _toUiItem(a, c, e, maxWidth: 520)).toList();
    final resumeOut =
        resume.map((e) => _toUiItem(a, c, e, maxWidth: 520)).toList();
    return (lib: libOut, resume: resumeOut, views: views);
  }

  List<_UiItem> _replaceItemsForAccount(
    List<_UiItem> src,
    String accountId,
    List<_UiItem> incoming,
  ) {
    final out =
        src.where((x) => x.account.id != accountId).toList(growable: true);
    out.addAll(incoming);
    return out;
  }

  List<_Section> _replaceSectionsForAccount(
    List<_Section> src,
    String accountId,
    List<_Section> incoming,
  ) {
    final out =
        src.where((x) => x.account.id != accountId).toList(growable: true);
    out.addAll(incoming);
    return out;
  }

  Future<void> _ensureAccountLoaded(
    String accountId, {
    required int token,
    bool force = false,
  }) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    if (!force && _loadedAccountIds.contains(id)) return;

    final account = _accountById(id);
    final client = _clients[id];
    if (account == null || client == null) return;

    if (!mounted || token != _reloadToken) return;
    setState(() {
      _loadError = null;
      _loading = true;
      _sectionsLoading = true;
      _favoritesLoading = true;
    });

    try {
      final accountDataFuture = _loadAccountData(account, client);
      final favRawFuture = _safeItemsRequest(
        client.listFavorites(),
        timeout: const Duration(seconds: 8),
      );

      final accountData = await accountDataFuture;
      final sections =
          await _loadLatestSections(account, client, accountData.views);
      final favRaw = await favRawFuture;

      final uniqLib = _unique(accountData.lib)
        ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      final uniqResume = _unique(accountData.resume)
        ..sort((a, b) => (b.item.dateModified ?? DateTime(1970))
            .compareTo(a.item.dateModified ?? DateTime(1970)));
      final uniqFav = _unique(
        favRaw
            .map((e) => _toUiItem(account, client, e, maxWidth: 420))
            .toList(),
      )..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      if (!mounted || token != _reloadToken) return;
      setState(() {
        _libraries = _replaceItemsForAccount(_libraries, id, uniqLib);
        _resume = _replaceItemsForAccount(_resume, id, uniqResume);
        _favorites = _replaceItemsForAccount(_favorites, id, uniqFav);
        _sections = _replaceSectionsForAccount(_sections, id, sections);
        _loadedAccountIds.add(id);
        _loading = false;
        _sectionsLoading = false;
        _favoritesLoading = false;
      });
    } catch (e) {
      if (!mounted || token != _reloadToken) return;
      setState(() {
        _loading = false;
        _sectionsLoading = false;
        _favoritesLoading = false;
        _loadError = e;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
    }
  }

  Future<void> _reload() async {
    final token = ++_reloadToken;
    setState(() {
      _loading = true;
      _loadError = null;
      _sectionsLoading = false;
      _favoritesLoading = false;
    });
    try {
      final loaded = await EmbyStore.load();
      final scopedIds = widget.accountIds
          ?.map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final accounts = loaded
          .where(
              (a) => a.userId.trim().isNotEmpty && a.apiKey.trim().isNotEmpty)
          .toList(growable: false);
      final clients = <String, EmbyClient>{
        for (final a in accounts) a.id: EmbyClient(a)
      };

      String preferredScopedId = '';
      if (scopedIds != null && scopedIds.isNotEmpty) {
        for (final id in scopedIds) {
          if (accounts.any((a) => a.id == id)) {
            preferredScopedId = id;
            break;
          }
        }
      }

      var nextSelected = (_selectedAccountId ?? '').trim();
      final validIds = accounts.map((e) => e.id).toSet();
      if (nextSelected.isEmpty || !validIds.contains(nextSelected)) {
        if (preferredScopedId.isNotEmpty) {
          nextSelected = preferredScopedId;
        } else {
          nextSelected = accounts.isEmpty ? '' : accounts.first.id;
        }
      }

      _latestPreferredStrategy
          .removeWhere((k, _) => !accounts.any((a) => a.id == k));
      _latestBlockedStrategies
          .removeWhere((k, _) => !accounts.any((a) => a.id == k));

      if (!mounted || token != _reloadToken) return;
      setState(() {
        _accounts = accounts;
        _clients = clients;
        _libraries = const <_UiItem>[];
        _resume = const <_UiItem>[];
        _favorites = const <_UiItem>[];
        _searchResults = const <_UiItem>[];
        _searchError = null;
        _sections = const <_Section>[];
        _loadedAccountIds.clear();
        _sectionsLoading = nextSelected.isNotEmpty;
        _favoritesLoading = nextSelected.isNotEmpty;
        _selectedAccountId = nextSelected.isEmpty ? null : nextSelected;
        _loadError = null;
      });

      if (nextSelected.isEmpty) {
        if (!mounted || token != _reloadToken) return;
        setState(() {
          _loading = false;
          _sectionsLoading = false;
          _favoritesLoading = false;
        });
        return;
      }

      await _ensureAccountLoaded(
        nextSelected,
        token: token,
        force: true,
      );
      if (_query.trim().isNotEmpty) _scheduleSearch(immediate: true);
    } catch (e) {
      if (!mounted || token != _reloadToken) return;
      setState(() {
        _loadError = e;
        _loading = false;
        _sectionsLoading = false;
        _favoritesLoading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
    }
  }

  EmbyAccount? _accountById(String id) {
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  String _accountName(String id) {
    final a = _accountById(id);
    if (a == null) return 'Emby';
    return a.name.trim().isEmpty ? 'Emby' : a.name.trim();
  }

  bool _matchesSelectedAccount(String accountId) {
    final selected = (_selectedAccountId ?? '').trim();
    if (selected.isEmpty) return true;
    return accountId == selected;
  }

  List<_UiItem> _scopeItems(List<_UiItem> src) {
    final selected = (_selectedAccountId ?? '').trim();
    if (selected.isEmpty) return src;
    return src.where((x) => x.account.id == selected).toList(growable: false);
  }

  List<_Section> _scopeSections(List<_Section> src) {
    final selected = (_selectedAccountId ?? '').trim();
    if (selected.isEmpty) return src;
    return src.where((x) => x.account.id == selected).toList(growable: false);
  }

  String _selectedAccountLabel() {
    final selected = (_selectedAccountId ?? '').trim();
    if (selected.isEmpty) return 'Emby';
    return _accountName(selected);
  }

  String _imageUrlFor(_UiItem it) {
    final preferred = _preferOriginalUrl(it.coverUrl).trim();
    if (preferred.isNotEmpty) return preferred;
    final client = _clients[it.account.id];
    if (client == null) return '';
    return client.originalImageUrl(it.item.id).trim();
  }

  Route _embyAccountsRouteWithUi() {
    return EmbyPage.routeNoAnim(
      openExclusiveUi: (ctx, {Set<String>? scopedAccountIds}) {
        final scoped = (scopedAccountIds != null &&
                scopedAccountIds.map((e) => e.trim()).any((e) => e.isNotEmpty))
            ? scopedAccountIds
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toSet()
            : widget.accountIds;
        return Navigator.push(
          ctx,
          MaterialPageRoute(
            builder: (_) => EmbyExclusiveFavoritesPage(
              openFolder: widget.openFolder,
              openSettings: widget.openSettings,
              accountIds: scoped,
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEmbyAccounts() async {
    if (!mounted) return;
    await Navigator.push(context, _embyAccountsRouteWithUi());
    if (!mounted) return;
    await _reload();
  }

  Future<void> _openSettingsPage() async {
    if (!mounted) return;
    final open = widget.openSettings;
    if (open != null) {
      await open(context);
      return;
    }
    await Navigator.push(context, _embyAccountsRouteWithUi());
  }

  Future<void> _onAccountMenuSelected(String value) async {
    if (value == '__add__') {
      await _openEmbyAccounts();
      return;
    }
    if (!value.startsWith('acc:')) return;
    final id = value.substring(4).trim();
    if (id.isEmpty) return;
    if (!mounted) return;
    final oldId = (_selectedAccountId ?? '').trim();
    if (oldId == id) return;
    setState(() {
      _selectedAccountId = id;
      _searchResults = const <_UiItem>[];
      _searchError = null;
    });
    await _ensureAccountLoaded(id, token: _reloadToken);
    if (!mounted) return;
    if (_query.trim().isNotEmpty) _scheduleSearch(immediate: true);
  }

  Future<void> _openFolderUi({
    required EmbyAccount account,
    required String folderId,
    required String title,
  }) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: account,
          title: title.trim().isEmpty ? '\u5a92\u4f53\u5e93' : title.trim(),
          folderId: folderId,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  Future<void> _openFavoritesUi({required EmbyAccount account}) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: account,
          title: '${_accountName(account.id)} \u6536\u85cf',
          folderId: '',
          favoritesMode: true,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  bool _isSeriesDir(_UiItem item) {
    if (!item.isDir) return false;
    final type = item.item.type.trim().toLowerCase();
    return type.contains('series');
  }

  bool _isMovieItem(_UiItem item) {
    if (item.isDir || item.isImage) return false;
    return _embyTypeIsMovie(item.item.type);
  }

  Future<void> _openSeriesUi(_UiItem item) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbySeriesDetailPage(
          account: item.account,
          seriesId: item.item.id.trim(),
          seedSeries: item.item,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  Future<void> _openMovieUi(_UiItem item) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyMovieDetailPage(
          account: item.account,
          movieId: item.item.id.trim(),
          seedMovie: item.item,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  EmbyItem? _pickPrimaryMovieFromItems(List<EmbyItem> src) {
    final videos = src.where((item) {
      if (_embyItemIsDir(item)) return false;
      if (_embyTypeIsImage(item.type)) return false;
      final mediaType = (item.mediaType ?? '').trim().toLowerCase();
      if (mediaType.isEmpty) return true;
      return mediaType == 'video';
    }).toList(growable: false);
    if (videos.isEmpty) return null;

    final ordered = videos.toList(growable: false)
      ..sort((a, b) {
        final aMovie = _embyTypeIsMovie(a.type) ? 1 : 0;
        final bMovie = _embyTypeIsMovie(b.type) ? 1 : 0;
        if (aMovie != bMovie) return bMovie.compareTo(aMovie);

        final sizeCmp = b.size.compareTo(a.size);
        if (sizeCmp != 0) return sizeCmp;

        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return ordered.first;
  }

  Future<EmbyItem?> _resolveMovieFromFolder(_UiItem folder) async {
    final folderId = folder.item.id.trim();
    if (folderId.isEmpty) return null;
    final client = _clients[folder.account.id];
    if (client == null) return null;

    Future<List<EmbyItem>> fetch(bool recursive, int limit) async {
      return client
          .listChildren(
            parentId: folderId,
            recursive: recursive,
            includeItemTypes: 'Movie,Video,Episode,MusicVideo',
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            limit: limit,
          )
          .timeout(const Duration(seconds: 8));
    }

    try {
      final direct = await fetch(false, 120);
      final hit = _pickPrimaryMovieFromItems(direct);
      if (hit != null) return hit;
    } catch (_) {}

    try {
      final recursive = await fetch(true, 260);
      return _pickPrimaryMovieFromItems(recursive);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openItem(_UiItem item, {List<_UiItem>? pool}) async {
    if (_isSeriesDir(item)) {
      await _openSeriesUi(item);
      return;
    }
    if (_isMovieItem(item)) {
      await _openMovieUi(item);
      return;
    }
    if (item.isDir && _looksLikeMovieFolder(item.item)) {
      final movie = await _resolveMovieFromFolder(item);
      if (movie != null && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _EmbyMovieDetailPage(
              account: item.account,
              movieId: movie.id.trim(),
              seedMovie: movie,
              paletteMode: _paletteMode,
            ),
          ),
        );
        return;
      }
    }
    if (item.isDir) {
      await _openFolderUi(
        account: item.account,
        folderId: item.item.id.trim(),
        title: item.title,
      );
      return;
    }

    if (item.isImage) {
      final images = (pool ?? <_UiItem>[item])
          .where((x) => x.account.id == item.account.id && x.isImage)
          .toList(growable: false);
      final urls = <String>[];
      final sourceKeys = <String>[];
      for (final x in images) {
        final url = _imageUrlFor(x).trim();
        if (url.isEmpty) continue;
        urls.add(url);
        sourceKeys.add(_imageSourceKeyFor(x));
      }
      if (urls.isEmpty) return;
      var idx = sourceKeys.indexOf(_imageSourceKeyFor(item));
      if (idx < 0) idx = 0;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths: urls,
            initialIndex: idx,
            sourceKeys: sourceKeys,
          ),
        ),
      );
      return;
    }

    final playable = (pool ?? <_UiItem>[item])
        .where((x) =>
            x.account.id == item.account.id &&
            !x.isDir &&
            !x.isImage &&
            x.item.id.trim().isNotEmpty)
        .toList(growable: false);
    final paths = playable.map(_videoPathFor).toList(growable: false);
    if (paths.isEmpty) return;
    var idx = playable.indexWhere((x) => x.item.id == item.item.id);
    if (idx < 0) idx = 0;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          videoPaths: paths,
          initialIndex: idx.clamp(0, paths.length - 1),
        ),
      ),
    );
  }

  void _scheduleSearch({bool immediate = false}) {
    _searchDebounce?.cancel();
    final q = _query.trim();
    if (q.isEmpty || _accounts.isEmpty) {
      setState(() {
        _searching = false;
        _searchError = null;
        _searchResults = const <_UiItem>[];
      });
      return;
    }
    final seq = ++_searchSeq;
    _searchDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 320),
      () async {
        if (!mounted || seq != _searchSeq) return;
        setState(() {
          _searching = true;
          _searchError = null;
        });
        try {
          final out = <_UiItem>[];
          final tasks = <Future<List<_UiItem>>>[];
          for (final a in _accounts) {
            if (!_matchesSelectedAccount(a.id)) continue;
            final c = _clients[a.id];
            if (c == null) continue;
            tasks.add(() async {
              try {
                final items = await c
                    .searchItems(query: q, limit: _kSearchResultLimit)
                    .timeout(_kHomeRequestTimeout);
                return items
                    .map((e) => _toUiItem(a, c, e, maxWidth: 360))
                    .toList(growable: false);
              } catch (_) {
                return const <_UiItem>[];
              }
            }());
          }
          if (tasks.isNotEmpty) {
            final chunks = await Future.wait(tasks);
            for (final c in chunks) {
              out.addAll(c);
            }
          }
          final unique = _unique(out)
            ..sort((a, b) =>
                a.title.toLowerCase().compareTo(b.title.toLowerCase()));
          if (!mounted || seq != _searchSeq) return;
          setState(() {
            _searching = false;
            _searchResults = unique;
          });
        } catch (e) {
          if (!mounted || seq != _searchSeq) return;
          setState(() {
            _searching = false;
            _searchError = e;
          });
        }
      },
    );
  }

  double _estimateCoverAspect(_UiItem item) {
    final ratio = item.item.primaryImageAspectRatio;
    if (ratio != null && ratio.isFinite && ratio >= 0.45 && ratio <= 2.4) {
      return ratio;
    }
    if (item.isImage) return 1.5;
    if (item.isDir) return 0.67;
    final type = item.item.type.trim().toLowerCase();
    if (type.contains('episode') ||
        type.contains('video') ||
        type.contains('trailer')) {
      return 1.78;
    }
    if (type.contains('photo') ||
        type.contains('image') ||
        type.contains('picture')) {
      return 1.5;
    }
    return 0.67;
  }

  int _aspectBucket(double ratio) {
    if (ratio < 0.9) return 0;
    if (ratio <= 1.25) return 1;
    return 2;
  }

  double _dominantHomeCoverAspect(List<_UiItem> items) {
    if (items.isEmpty) return 0.67;
    final values = <int, List<double>>{
      0: <double>[],
      1: <double>[],
      2: <double>[],
    };
    var imageCount = 0;
    for (final item in items) {
      final ratio = _estimateCoverAspect(item);
      values[_aspectBucket(ratio)]!.add(ratio);
      if (item.isImage) imageCount++;
    }
    final preferLandscape = imageCount * 2 >= items.length;

    var winner = preferLandscape ? 2 : 0;
    var winnerCount = values[winner]!.length;
    for (var bucket = 0; bucket < 3; bucket++) {
      final count = values[bucket]!.length;
      if (count > winnerCount) {
        winner = bucket;
        winnerCount = count;
        continue;
      }
      if (count == winnerCount && count > 0) {
        if (preferLandscape && bucket == 2) winner = bucket;
        if (!preferLandscape && bucket == 0) winner = bucket;
      }
    }

    final selected = values[winner]!;
    if (selected.isEmpty) return 0.67;
    var sum = 0.0;
    for (final v in selected) {
      sum += v;
    }
    final avg = sum / selected.length;
    if (winner == 0) return avg.clamp(0.56, 0.88).toDouble();
    if (winner == 1) return avg.clamp(0.9, 1.2).toDouble();
    return avg.clamp(1.3, 2.0).toDouble();
  }

  double _homeGridChildAspectRatio({
    required double maxWidth,
    required int columns,
    required double coverAspectRatio,
  }) {
    if (columns <= 0) return 0.95;
    final safeWidth = maxWidth <= 0 ? 1.0 : maxWidth;
    const crossSpacing = 10.0;
    final usableWidth =
        (safeWidth - crossSpacing * (columns - 1)).clamp(1.0, 100000.0);
    final tileWidth = usableWidth / columns;
    const gapCoverTitle = 6.0;
    const titleHeight = 20.0;
    final tileHeight =
        (tileWidth / coverAspectRatio) + gapCoverTitle + titleHeight;
    final ratio = tileWidth / tileHeight;
    return ratio.clamp(0.45, 1.45).toDouble();
  }

  double _shelfCoverHeight(double coverAspectRatio) {
    if (coverAspectRatio < 0.9) return 132;
    if (coverAspectRatio > 1.25) return 108;
    return 118;
  }

  Widget _cover(_UiItem item) {
    final p = _palette;
    final url = item.coverUrl.trim();
    final isMovie = _embyTypeIsMovie(item.item.type);
    final token = item.account.apiKey.trim();
    final headers =
        token.isEmpty ? null : <String, String>{'X-Emby-Token': token};
    final coverWidth = item.isImage ? 720 : (isMovie ? 760 : 520);
    final emptyIcon = item.isDir
        ? Icons.folder_open_rounded
        : (item.isImage ? Icons.image_outlined : Icons.video_file_outlined);

    Widget emptyPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(
          child: Icon(
            emptyIcon,
            color: p.coverPlaceholderIcon,
            size: 28,
          ),
        ),
      );
    }

    Widget brokenPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(
          child: Icon(Icons.broken_image_outlined, color: p.sub),
        ),
      );
    }

    Widget buildDirAutoFallback() {
      return FutureBuilder<String?>(
        future: _resolveFolderCoverFallback(item, maxWidth: coverWidth),
        builder: (_, snap) {
          final auto = (snap.data ?? '').trim();
          if (auto.isEmpty || auto == url) return emptyPlaceholder();
          return Image.network(
            auto,
            headers: headers,
            fit: BoxFit.cover,
            cacheWidth: coverWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => brokenPlaceholder(),
          );
        },
      );
    }

    Widget buildDirSeed(String seedUrl) {
      return Image.network(
        seedUrl,
        headers: headers,
        fit: BoxFit.cover,
        cacheWidth: coverWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => buildDirAutoFallback(),
      );
    }

    if (item.isDir) {
      if (url.isEmpty) return buildDirAutoFallback();
      return buildDirSeed(url);
    }

    if (url.isEmpty) {
      return emptyPlaceholder();
    }
    return Image.network(
      url,
      headers: headers,
      fit: BoxFit.cover,
      cacheWidth: coverWidth,
      filterQuality: isMovie ? FilterQuality.medium : FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => brokenPlaceholder(),
    );
  }

  Widget _card(
    _UiItem item, {
    List<_UiItem>? pool,
    double width = 175,
    double coverAspectRatio = 1.62,
    double? coverHeight,
  }) {
    final aspect = coverAspectRatio.clamp(0.56, 2.0).toDouble();
    final shelfMode = coverHeight != null && coverHeight > 0;
    final computedWidth = shelfMode
        ? (coverHeight * aspect).clamp(112.0, 248.0).toDouble()
        : width;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openItem(item, pool: pool),
      child: SizedBox(
        width: computedWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (shelfMode)
              SizedBox(
                width: computedWidth,
                height: coverHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _cover(item),
                ),
              )
            else
              AspectRatio(
                aspectRatio: aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _cover(item),
                ),
              ),
            const SizedBox(height: 6),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _palette.text, fontSize: 15)),
          ],
        ),
      ),
    );
  }

  Widget _shelf(List<_UiItem> items) {
    if (items.isEmpty) {
      return SizedBox(
        height: 170,
        child: Center(
          child: Text(
            '\u6682\u65e0\u5185\u5bb9',
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }
    final coverAspect = _dominantHomeCoverAspect(items);
    final coverHeight = _shelfCoverHeight(coverAspect);
    final shelfHeight = coverHeight + 34;
    return SizedBox(
      height: shelfHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => _card(
          items[i],
          pool: items,
          coverAspectRatio: coverAspect,
          coverHeight: coverHeight,
        ),
      ),
    );
  }

  void _onHomeTabChanged(_EmbyHomeTab tab) {
    if (_homeTab == tab) return;
    setState(() => _homeTab = tab);
    final selected = (_selectedAccountId ?? '').trim();
    if (selected.isNotEmpty && !_loadedAccountIds.contains(selected)) {
      unawaited(_ensureAccountLoaded(selected, token: _reloadToken));
    }
    if (tab == _EmbyHomeTab.search && _query.trim().isNotEmpty) {
      _scheduleSearch(immediate: true);
    }
  }

  void _onPrimaryTabSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 260) return;
    if (_homeTab == _EmbyHomeTab.search) return;

    if (velocity < 0 && _homeTab == _EmbyHomeTab.home) {
      _onHomeTabChanged(_EmbyHomeTab.favorites);
      return;
    }
    if (velocity > 0 && _homeTab == _EmbyHomeTab.favorites) {
      _onHomeTabChanged(_EmbyHomeTab.home);
    }
  }

  Widget _homeTabItem({
    required _EmbyHomeTab tab,
    required IconData icon,
    required String label,
  }) {
    final selected = _homeTab == tab;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _onHomeTabChanged(tab),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: selected ? 74 : 66,
              height: 34,
              decoration: BoxDecoration(
                color: selected ? _palette.chipSelectedBg : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: _palette.text, size: 25),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: _palette.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _homeTabBar() {
    return Row(
      children: [
        _homeTabItem(
          tab: _EmbyHomeTab.home,
          icon: Icons.home_outlined,
          label: '\u89c6\u9891',
        ),
        _homeTabItem(
          tab: _EmbyHomeTab.favorites,
          icon: Icons.favorite_border_rounded,
          label: '\u6536\u85cf\u5939',
        ),
        _homeTabItem(
          tab: _EmbyHomeTab.search,
          icon: Icons.search_rounded,
          label: '\u641c\u7d22',
        ),
      ],
    );
  }

  Widget _buildSearchSection() {
    final query = _query.trim();
    if (query.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            '\u8f93\u5165\u5173\u952e\u8bcd\u5f00\u59cb\u641c\u7d22',
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }
    if (_searching) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: CircularProgressIndicator(color: _palette.progress),
        ),
      );
    }
    if (_searchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            friendlyErrorMessage(_searchError!),
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            '\u6ca1\u6709\u5339\u914d\u7ed3\u679c',
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }

    final coverAspect = _dominantHomeCoverAspect(_searchResults);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const spacing = 10.0;
        const targetWidth = 132.0;
        final raw = ((width + spacing) / (targetWidth + spacing)).floor();
        final minColumns = width < 340 ? 2 : 3;
        const maxColumns = 6;
        final columns = raw.clamp(minColumns, maxColumns).toInt();
        final childAspect = _homeGridChildAspectRatio(
          maxWidth: width,
          columns: columns,
          coverAspectRatio: coverAspect,
        );
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _searchResults.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            childAspectRatio: childAspect,
          ),
          itemBuilder: (_, i) => _card(
            _searchResults[i],
            pool: _searchResults,
            width: double.infinity,
            coverAspectRatio: coverAspect,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = () {
      if (_loading) {
        return Center(
          child: CircularProgressIndicator(color: _palette.progress),
        );
      }
      if (_loadError != null) {
        return Center(
          child: Text(
            friendlyErrorMessage(_loadError!),
            style: TextStyle(color: _palette.sub),
          ),
        );
      }
      if (_accounts.isEmpty) {
        return Center(
          child: Text(
            '\u5c1a\u672a\u8fde\u63a5 Emby',
            style: TextStyle(color: _palette.sub),
          ),
        );
      }

      final scopedLibraries = _scopeItems(_libraries);
      final scopedResume = _scopeItems(_resume);
      final scopedFavorites = _scopeItems(_favorites);
      final scopedSections = _scopeSections(_sections);

      final groupedFav = <String, List<_UiItem>>{};
      for (final f in scopedFavorites) {
        groupedFav.putIfAbsent(f.account.id, () => <_UiItem>[]).add(f);
      }

      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 26),
          children: [
            Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: '\u5207\u6362 Emby',
                  offset: const Offset(0, 40),
                  color: _palette.panel,
                  onSelected: _onAccountMenuSelected,
                  itemBuilder: (_) => [
                    for (final a in _accounts)
                      PopupMenuItem<String>(
                        value: 'acc:${a.id}',
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                a.name.trim().isEmpty ? 'Emby' : a.name.trim(),
                                style: TextStyle(color: _palette.text),
                              ),
                            ),
                            if ((_selectedAccountId ?? '').trim() == a.id)
                              Icon(Icons.check, color: _palette.text, size: 16),
                          ],
                        ),
                      ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: '__add__',
                      child: Row(
                        children: [
                          Icon(Icons.add, color: _palette.text, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            '\u65b0\u589e Emby',
                            style: TextStyle(color: _palette.text),
                          ),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: _palette.panel,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          color: _palette.text,
                          size: 22,
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.expand_more, color: _palette.sub, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _selectedAccountLabel(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _palette.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                PopupMenuButton<_EmbyPaletteMode>(
                  tooltip: '\u4e3b\u9898\u914d\u8272',
                  color: _palette.panel,
                  icon: Icon(Icons.palette_outlined, color: _palette.text),
                  onSelected: (mode) => unawaited(_setPaletteMode(mode)),
                  itemBuilder: (_) => [
                    for (final mode in _EmbyPaletteMode.values)
                      PopupMenuItem<_EmbyPaletteMode>(
                        value: mode,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _paletteLabel(mode),
                                style: TextStyle(color: _palette.text),
                              ),
                            ),
                            if (_paletteMode == mode)
                              Icon(Icons.check, color: _palette.text, size: 16),
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  onPressed: _openSettingsPage,
                  icon: Icon(Icons.settings_outlined, color: _palette.text),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_homeTab == _EmbyHomeTab.search) ...[
              TextField(
                style: TextStyle(color: _palette.text),
                onChanged: (v) {
                  setState(() => _query = v);
                  _scheduleSearch();
                },
                decoration: InputDecoration(
                  filled: true,
                  fillColor: _palette.panel,
                  hintText: '\u641c\u7d22 Emby \u5a92\u4f53',
                  hintStyle: TextStyle(color: _palette.sub),
                  prefixIcon: Icon(Icons.search, color: _palette.sub),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildSearchSection(),
            ],
            if (_homeTab == _EmbyHomeTab.home) ...[
              Text(
                '\u5a92\u4f53\u5e93',
                style: TextStyle(
                  color: _palette.text,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _shelf(scopedLibraries),
              const SizedBox(height: 10),
              Text(
                '\u7ee7\u7eed\u89c2\u770b',
                style: TextStyle(
                  color: _palette.text,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _shelf(scopedResume),
              const SizedBox(height: 10),
              if (_sectionsLoading && scopedSections.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _palette.progress,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '\u6b63\u5728\u52a0\u8f7d\u5206\u533a\u2026',
                        style: TextStyle(color: _palette.sub, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              for (final row in scopedSections) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.view.name.trim().isEmpty
                            ? '\u5a92\u4f53'
                            : row.view.name.trim(),
                        style: TextStyle(
                          color: _palette.text,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _openFolderUi(
                        account: row.account,
                        folderId: row.view.id,
                        title: row.view.name.trim().isEmpty
                            ? '\u5a92\u4f53'
                            : row.view.name.trim(),
                      ),
                      child: Text(
                        '\u66f4\u591a',
                        style: TextStyle(color: _palette.sub),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _shelf(row.items),
                const SizedBox(height: 10),
              ],
              if (_sectionsLoading && scopedSections.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Center(
                    child: Text(
                      '\u5206\u533a\u7ee7\u7eed\u52a0\u8f7d\u4e2d…',
                      style: TextStyle(color: _palette.sub, fontSize: 12),
                    ),
                  ),
                ),
            ],
            if (_homeTab == _EmbyHomeTab.favorites) ...[
              if (_favoritesLoading && groupedFav.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: CircularProgressIndicator(color: _palette.progress),
                  ),
                ),
              if (!_favoritesLoading && groupedFav.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(
                      '\u6682\u65e0\u6536\u85cf',
                      style: TextStyle(color: _palette.sub),
                    ),
                  ),
                ),
              for (final e in groupedFav.entries) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _accountName(e.key),
                        style: TextStyle(
                          color: _palette.text,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final acc = _accountById(e.key);
                        if (acc != null) _openFavoritesUi(account: acc);
                      },
                      child: Text(
                        '\u66f4\u591a',
                        style: TextStyle(color: _palette.sub),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _shelf(e.value.take(20).toList(growable: false)),
                const SizedBox(height: 10),
              ],
              if (_favoritesLoading && groupedFav.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Center(
                    child: Text(
                      '\u6536\u85cf\u7ee7\u7eed\u52a0\u8f7d\u4e2d\u2026',
                      style: TextStyle(color: _palette.sub, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _palette.statusStyle,
      child: Scaffold(
        backgroundColor: _palette.bg,
        body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: _onPrimaryTabSwipe,
            child: body,
          ),
        ),
        bottomNavigationBar: Builder(
          builder: (context) {
            final bottomInset = MediaQuery.paddingOf(context).bottom;
            final navBottomPadding = bottomInset > 0
                ? (bottomInset * 0.6).clamp(6.0, 16.0).toDouble()
                : 6.0;
            return Container(
              width: double.infinity,
              color: _palette.panel,
              padding: EdgeInsets.fromLTRB(
                8,
                4,
                8,
                navBottomPadding,
              ),
              child: _homeTabBar(),
            );
          },
        ),
      ),
    );
  }
}

class _EmbyExclusiveFolderPage extends StatefulWidget {
  final EmbyAccount account;
  final String title;
  final String folderId;
  final bool favoritesMode;
  final _EmbyPaletteMode paletteMode;

  const _EmbyExclusiveFolderPage({
    required this.account,
    required this.title,
    required this.folderId,
    this.favoritesMode = false,
    required this.paletteMode,
  });

  @override
  State<_EmbyExclusiveFolderPage> createState() =>
      _EmbyExclusiveFolderPageState();
}

enum _FolderTopTab { videos, images, folders }

enum _FolderSortKind { updatedAt, addedAt, title, playDuration, playedAt }

enum _AspectBucket { poster, square, landscape }

class _EmbyExclusiveFolderPageState extends State<_EmbyExclusiveFolderPage> {
  late final EmbyClient _client = EmbyClient(widget.account);
  static const int _kMaxPerDirectoryDisplaySettingsEntries = 500;

  bool _loading = true;
  Object? _loadError;
  List<_UiItem> _items = const <_UiItem>[];
  List<_UiItem> _recursiveVideos = const <_UiItem>[];
  List<_UiItem> _recursiveImages = const <_UiItem>[];
  _FolderTopTab _topTab = _FolderTopTab.videos;
  _FolderSortKind _sort = _FolderSortKind.title;
  bool _sortAsc = true;
  int _coverHydrationToken = 0;
  bool _perDirectoryDisplaySettingsEnabled = false;
  int _moviePrewarmRunToken = 0;
  final Map<String, _UiItem> _movieFolderPrimaryCache = <String, _UiItem>{};
  final Map<String, Future<_UiItem?>> _movieFolderPrimaryInflight =
      <String, Future<_UiItem?>>{};
  final Map<String, String> _movieFolderCoverUrlCache = <String, String>{};
  final Map<String, String> _folderCoverUrlCache = <String, String>{};
  final Map<String, Future<String?>> _folderCoverInflight =
      <String, Future<String?>>{};
  final Set<String> _movieFolderPrimaryMisses = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  _EmbyPalette get _palette => _paletteForMode(widget.paletteMode);

  Future<void> _bootstrap() async {
    await _reload();
  }

  String _displaySettingsPathForFolder() {
    if (widget.favoritesMode || widget.folderId.trim().isEmpty) {
      return 'favorites';
    }
    return 'view:${widget.folderId.trim()}';
  }

  String _displaySettingsKeyForCurrentFolder() {
    final accountId = widget.account.id.trim();
    if (accountId.isEmpty) return '';
    return '$_kEmbyFolderDisplayPerDirPrefix$accountId/${_displaySettingsPathForFolder()}';
  }

  int _intOr(int fallback, dynamic v) {
    if (v is int) return v;
    if (v is String) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
    return fallback;
  }

  int _displayStateTs(dynamic raw) {
    if (raw is! Map) return 0;
    final map = raw.cast<dynamic, dynamic>();
    return _intOr(0, map['ts']);
  }

  Map<String, dynamic> _encodeDisplayState({bool withTimestamp = false}) {
    final out = <String, dynamic>{
      'v': _topTab.index,
      's': _sort.index,
      'a': _sortAsc,
    };
    if (withTimestamp) {
      out['ts'] = DateTime.now().millisecondsSinceEpoch;
    }
    return out;
  }

  void _applyDisplayStateJson(dynamic raw) {
    if (raw is! Map) return;
    final map = raw.cast<dynamic, dynamic>();
    final tabIdx = _intOr(_topTab.index, map['v'])
        .clamp(0, _FolderTopTab.values.length - 1)
        .toInt();
    final sortIdx = _intOr(_sort.index, map['s'])
        .clamp(0, _FolderSortKind.values.length - 1)
        .toInt();
    final asc = map['a'] is bool ? map['a'] as bool : _sortAsc;

    _topTab = _FolderTopTab.values[tabIdx];
    _sort = _FolderSortKind.values[sortIdx];
    _sortAsc = asc;
  }

  Future<void> _loadDisplaySettingsForCurrentFolder() async {
    bool enabled = false;
    dynamic perDirState;
    try {
      enabled =
          await AppSettings.getFavoritePerDirectoryDisplaySettingsEnabled();
      if (enabled) {
        final all =
            await AppSettings.getFavoritePerDirectoryDisplaySettingsState();
        final key = _displaySettingsKeyForCurrentFolder();
        if (key.isNotEmpty) {
          perDirState = all[key];
        }
      }
    } catch (_) {
      enabled = false;
    }

    dynamic globalState;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = (sp.getString(_kEmbyFolderDisplayGlobalPrefKey) ?? '').trim();
      if (raw.isNotEmpty) {
        globalState = jsonDecode(raw);
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _perDirectoryDisplaySettingsEnabled = enabled;
      _applyDisplayStateJson(perDirState ?? globalState);
    });
  }

  Future<void> _persistDisplaySettingsForCurrentFolder() async {
    if (_perDirectoryDisplaySettingsEnabled) {
      final key = _displaySettingsKeyForCurrentFolder();
      if (key.isEmpty) return;
      try {
        final all =
            await AppSettings.getFavoritePerDirectoryDisplaySettingsState();
        all[key] = _encodeDisplayState(withTimestamp: true);

        final embyUiKeys = all.keys
            .where((k) => k.startsWith(_kEmbyFolderDisplayPerDirPrefix))
            .toList(growable: false)
          ..sort((a, b) =>
              _displayStateTs(all[b]).compareTo(_displayStateTs(all[a])));
        if (embyUiKeys.length > _kMaxPerDirectoryDisplaySettingsEntries) {
          for (final k
              in embyUiKeys.skip(_kMaxPerDirectoryDisplaySettingsEntries)) {
            all.remove(k);
          }
        }

        await AppSettings.setFavoritePerDirectoryDisplaySettingsState(all);
      } catch (_) {}
      return;
    }

    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kEmbyFolderDisplayGlobalPrefKey,
        jsonEncode(_encodeDisplayState()),
      );
    } catch (_) {}
  }

  void _setTopTab(_FolderTopTab tab) {
    if (_topTab == tab) return;
    setState(() => _topTab = tab);
    unawaited(_persistDisplaySettingsForCurrentFolder());
  }

  void _onSortSelected(_FolderSortKind nextSort) {
    setState(() {
      if (_sort == nextSort) {
        _sortAsc = !_sortAsc;
      } else {
        _sort = nextSort;
        _sortAsc = nextSort == _FolderSortKind.title;
      }
    });
    unawaited(_persistDisplaySettingsForCurrentFolder());
  }

  _UiItem _toUiItem(EmbyItem item, {int maxWidth = 420}) {
    final isDir = _embyItemIsDir(item);
    final isImage = !isDir && _embyTypeIsImage(item.type);
    final isMovieDir = isDir && _looksLikeMovieFolderItem(item);
    final rawCover = _coverUrlFor(_client, item, maxWidth: maxWidth);
    var cover =
        isDir && !isMovieDir ? _safeSeedFolderCover(rawCover) : rawCover;
    if (isMovieDir) {
      final id = item.id.trim();
      final cached = (_movieFolderCoverUrlCache[id] ?? '').trim();
      if (cached.isNotEmpty) {
        cover = cached;
      }
    } else if (isDir) {
      final id = item.id.trim();
      final cached = (_folderCoverUrlCache[id] ?? '').trim();
      if (cached.isNotEmpty) {
        cover = cached;
      }
    }
    return _UiItem(
      account: widget.account,
      item: item,
      isDir: isDir,
      isImage: isImage,
      coverUrl: cover,
    );
  }

  String _safeSeedFolderCover(String url) {
    final u = url.trim();
    if (u.isEmpty) return '';
    // Keep non-tag URL as optimistic seed: many Emby folders can still return
    // inherited/auto-generated Primary images without explicit tag.
    return u;
  }

  Future<String?> _resolveFolderCoverFallback(
    _UiItem item, {
    int maxWidth = 560,
  }) async {
    if (!item.isDir) return null;
    final folderId = item.item.id.trim();
    if (folderId.isEmpty) return null;

    final cached = (_folderCoverUrlCache[folderId] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    final inflight = _folderCoverInflight[folderId];
    if (inflight != null) return await inflight;

    final fut = (() async {
      try {
        final auto = await _client.pickAutoFolderCoverUrl(
          folderId: folderId,
          maxWidth: maxWidth,
          quality: 85,
          fallbackToVideo: true,
        );
        final url = (auto ?? '').trim();
        if (url.isNotEmpty) {
          _folderCoverUrlCache[folderId] = url;
          return url;
        }
      } catch (_) {}
      return null;
    })();

    _folderCoverInflight[folderId] = fut;
    try {
      return await fut;
    } finally {
      _folderCoverInflight.remove(folderId);
    }
  }

  String _topTabLabel(_FolderTopTab tab) {
    switch (tab) {
      case _FolderTopTab.videos:
        return '\u89c6\u9891';
      case _FolderTopTab.images:
        return '\u56fe\u7247';
      case _FolderTopTab.folders:
        return '\u6587\u4ef6\u5939';
    }
  }

  String _sortLabel(_FolderSortKind sort) {
    switch (sort) {
      case _FolderSortKind.updatedAt:
        return '\u66f4\u65b0\u65e5\u671f';
      case _FolderSortKind.addedAt:
        return '\u52a0\u5165\u65e5\u671f';
      case _FolderSortKind.title:
        return '\u6807\u9898';
      case _FolderSortKind.playDuration:
        return '\u64ad\u653e\u65f6\u957f';
      case _FolderSortKind.playedAt:
        return '\u64ad\u653e\u65e5\u671f';
    }
  }

  bool get _hasImages => _recursiveImages.isNotEmpty;

  bool _isSeriesFolder(_UiItem item) {
    if (!item.isDir) return false;
    final type = item.item.type.trim().toLowerCase();
    return type.contains('series') || type.contains('season');
  }

  bool _looksLikeMovieFolderItem(EmbyItem item) {
    return _looksLikeMovieFolder(item);
  }

  bool _isMovieFolder(_UiItem item) {
    if (!item.isDir) return false;
    if (_isSeriesFolder(item)) return false;
    return _looksLikeMovieFolderItem(item.item);
  }

  bool _isSeriesDir(_UiItem item) {
    if (!item.isDir) return false;
    final type = item.item.type.trim().toLowerCase();
    return type.contains('series');
  }

  bool _isMovieItem(_UiItem item) {
    if (item.isDir || item.isImage) return false;
    return _embyTypeIsMovie(item.item.type);
  }

  List<_UiItem> _baseItemsForTab() {
    switch (_topTab) {
      case _FolderTopTab.videos:
        return _recursiveVideos;
      case _FolderTopTab.images:
        return _recursiveImages;
      case _FolderTopTab.folders:
        // \u6587\u4ef6\u5939\u9875\u540c\u65f6\u663e\u793a\u76ee\u5f55\u548c\u5f53\u524d\u5c42\u7ea7\u7684\u76f4\u8fde\u6587\u4ef6\uff08\u4e0d\u9012\u5f52\uff09\u3002
        return _items
            .where((x) => !_isSeriesFolder(x) && !_isMovieFolder(x))
            .toList(growable: false);
    }
  }

  bool _hasCover(_UiItem item) => item.coverUrl.trim().isNotEmpty;

  double? _primaryAspectOf(_UiItem item) {
    final ratio = item.item.primaryImageAspectRatio;
    if (ratio == null || !ratio.isFinite) return null;
    if (ratio < 0.45 || ratio > 2.4) return null;
    return ratio;
  }

  double _fallbackAspectOf(_UiItem item) {
    if (item.isImage) return 1.5;
    if (item.isDir) return 0.67;
    final type = item.item.type.trim().toLowerCase();
    if (type.contains('movie') ||
        type.contains('series') ||
        type.contains('season') ||
        type.contains('boxset') ||
        type.contains('collection') ||
        type.contains('folder') ||
        type.contains('album') ||
        type.contains('playlist')) {
      return 0.67;
    }
    if (type.contains('photo') ||
        type.contains('image') ||
        type.contains('picture')) {
      return 1.5;
    }
    if (type.contains('episode') ||
        type.contains('video') ||
        type.contains('trailer')) {
      return 1.78;
    }
    return 1.25;
  }

  double _estimateAspectOf(_UiItem item) {
    return _primaryAspectOf(item) ?? _fallbackAspectOf(item);
  }

  _AspectBucket _bucketOf(double ratio) {
    if (ratio < 0.9) return _AspectBucket.poster;
    if (ratio <= 1.25) return _AspectBucket.square;
    return _AspectBucket.landscape;
  }

  int _bucketPriority(_AspectBucket bucket) {
    switch (_topTab) {
      case _FolderTopTab.images:
        switch (bucket) {
          case _AspectBucket.landscape:
            return 3;
          case _AspectBucket.square:
            return 2;
          case _AspectBucket.poster:
            return 1;
        }
      case _FolderTopTab.videos:
        switch (bucket) {
          case _AspectBucket.poster:
            return 3;
          case _AspectBucket.landscape:
            return 2;
          case _AspectBucket.square:
            return 1;
        }
      case _FolderTopTab.folders:
        switch (bucket) {
          case _AspectBucket.poster:
            return 3;
          case _AspectBucket.square:
            return 2;
          case _AspectBucket.landscape:
            return 1;
        }
    }
  }

  double _dominantCoverAspect(List<_UiItem> items) {
    if (items.isEmpty) return 0.67;
    final values = <_AspectBucket, List<double>>{
      _AspectBucket.poster: <double>[],
      _AspectBucket.square: <double>[],
      _AspectBucket.landscape: <double>[],
    };

    for (final item in items) {
      final ratio = _estimateAspectOf(item);
      values[_bucketOf(ratio)]!.add(ratio);
    }

    var winner = _AspectBucket.poster;
    var winnerCount = -1;
    for (final bucket in _AspectBucket.values) {
      final count = values[bucket]!.length;
      if (count > winnerCount) {
        winner = bucket;
        winnerCount = count;
        continue;
      }
      if (count == winnerCount &&
          count > 0 &&
          _bucketPriority(bucket) > _bucketPriority(winner)) {
        winner = bucket;
      }
    }

    final selected = values[winner]!;
    if (selected.isEmpty) return 0.67;
    var sum = 0.0;
    for (final v in selected) {
      sum += v;
    }
    final avg = sum / selected.length;
    switch (winner) {
      case _AspectBucket.poster:
        return avg.clamp(0.56, 0.88).toDouble();
      case _AspectBucket.square:
        return avg.clamp(0.9, 1.2).toDouble();
      case _AspectBucket.landscape:
        return avg.clamp(1.3, 2.0).toDouble();
    }
  }

  double _gridChildAspectRatio({
    required double maxWidth,
    required int columns,
    required double coverAspectRatio,
  }) {
    if (columns <= 0) return 0.74;
    final safeWidth = maxWidth <= 0 ? 1.0 : maxWidth;
    const crossSpacing = 10.0;
    final tileWidth = (safeWidth - crossSpacing * (columns - 1)) / columns;
    const tilePaddingY = 14.0;
    const gapCoverTitle = 7.0;
    const gapTitleKind = 3.0;
    const titleHeight = 32.0;
    const kindHeight = 14.0;
    final tileHeight = (tileWidth / coverAspectRatio) +
        tilePaddingY +
        gapCoverTitle +
        gapTitleKind +
        titleHeight +
        kindHeight;
    final ratio = tileWidth / tileHeight;
    return ratio.clamp(0.42, 1.45).toDouble();
  }

  int _adaptiveGridColumns({
    required double width,
    required double coverAspectRatio,
    required bool isTablet,
  }) {
    final phoneColumns = coverAspectRatio >= 1.12 ? 2 : 3;
    if (!isTablet) return phoneColumns;

    const spacing = 10.0;
    final targetWidth = coverAspectRatio >= 1.12
        ? 220.0
        : (coverAspectRatio <= 0.95 ? 170.0 : 185.0);
    final raw = ((width + spacing) / (targetWidth + spacing)).floor();
    final minColumns = phoneColumns + 1;
    const maxColumns = 8;
    return raw.clamp(minColumns, maxColumns).toInt();
  }

  int _sortFieldCompare(_UiItem a, _UiItem b) {
    switch (_sort) {
      case _FolderSortKind.updatedAt:
        return (a.item.dateModified?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.dateModified?.millisecondsSinceEpoch ?? 0);
      case _FolderSortKind.addedAt:
        return (a.item.dateCreated?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.dateCreated?.millisecondsSinceEpoch ?? 0);
      case _FolderSortKind.playDuration:
        // 褰撳墠 EmbyItem 杩樻湭瑙ｆ瀽 RunTimeTicks锛屽厛鐢?size 杩戜技鎺掑簭銆?
        return a.item.size.compareTo(b.item.size);
      case _FolderSortKind.playedAt:
        return (a.item.dateModified?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.dateModified?.millisecondsSinceEpoch ?? 0);
      case _FolderSortKind.title:
        return _displayTitle(a)
            .toLowerCase()
            .compareTo(_displayTitle(b).toLowerCase());
    }
  }

  List<_UiItem> _displayItems() {
    final out = _baseItemsForTab().toList(growable: true);
    out.sort((a, b) {
      if (_topTab == _FolderTopTab.folders) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        if (a.isDir && b.isDir) {
          final aHas = _hasCover(a);
          final bHas = _hasCover(b);
          if (aHas != bHas) return aHas ? -1 : 1;
        }
      }
      var cmp = _sortFieldCompare(a, b);
      if (cmp == 0) {
        cmp = _displayTitle(a)
            .toLowerCase()
            .compareTo(_displayTitle(b).toLowerCase());
      }
      if (!_sortAsc) cmp = -cmp;
      return cmp;
    });
    return out;
  }

  List<_UiItem> _playableItems(List<_UiItem> src) {
    return src
        .where((x) => _isVideoItem(x) && x.item.id.trim().isNotEmpty)
        .toList(growable: false);
  }

  bool _isVideoItem(_UiItem item) {
    if (item.isDir || item.isImage) return false;
    final mediaType = (item.item.mediaType ?? '').trim().toLowerCase();
    if (mediaType.isEmpty) return true;
    return mediaType == 'video';
  }

  ({List<_UiItem> videos, List<_UiItem> images}) _splitMedia(
    List<_UiItem> source,
  ) {
    final videos = <_UiItem>[];
    final images = <_UiItem>[];
    for (final item in source) {
      if (item.isDir) {
        if (_isSeriesFolder(item) || _isMovieFolder(item)) {
          videos.add(item);
        }
        continue;
      }
      if (item.isImage) {
        images.add(item);
      } else if (_isVideoItem(item)) {
        videos.add(item);
      }
    }
    return (videos: videos, images: images);
  }

  bool _hasFolderTabItems(List<_UiItem> source) {
    for (final item in source) {
      if (!_isSeriesFolder(item) && !_isMovieFolder(item)) return true;
    }
    return false;
  }

  _FolderTopTab _chooseTopTab({
    required _FolderTopTab current,
    required List<_UiItem> directItems,
    required List<_UiItem> videos,
    required List<_UiItem> images,
  }) {
    final hasVideos = videos.isNotEmpty;
    final hasImages = images.isNotEmpty;
    final hasFolders = _hasFolderTabItems(directItems);

    switch (current) {
      case _FolderTopTab.videos:
        if (hasVideos) return _FolderTopTab.videos;
        if (hasImages) return _FolderTopTab.images;
        if (hasFolders) return _FolderTopTab.folders;
        return _FolderTopTab.videos;
      case _FolderTopTab.images:
        if (hasImages) return _FolderTopTab.images;
        if (hasVideos) return _FolderTopTab.videos;
        if (hasFolders) return _FolderTopTab.folders;
        return _FolderTopTab.images;
      case _FolderTopTab.folders:
        if (hasFolders) return _FolderTopTab.folders;
        if (hasVideos) return _FolderTopTab.videos;
        if (hasImages) return _FolderTopTab.images;
        return _FolderTopTab.folders;
    }
  }

  Future<({List<_UiItem> videos, List<_UiItem> images})> _collectRecursiveMedia(
      List<_UiItem> rootItems) async {
    const maxFoldersToScan = 72;
    const maxMediaItems = 1200;
    const scanBudget = Duration(seconds: 3);
    final allMedia = <_UiItem>[];
    final seenItems = <String>{};
    final seenFolders = <String>{};
    final folderQueue = <String>[];
    var cursor = 0;
    final startedAt = DateTime.now();

    bool outOfBudget() {
      if (allMedia.length >= maxMediaItems) return true;
      if (seenFolders.length >= maxFoldersToScan) return true;
      return DateTime.now().difference(startedAt) > scanBudget;
    }

    void push(_UiItem ui) {
      final id = ui.item.id.trim();
      if (id.isEmpty) return;
      final itemKey = '${ui.account.id}:$id';
      if (!seenItems.add(itemKey)) return;
      if (ui.isDir) {
        if (_isSeriesFolder(ui) || _isMovieFolder(ui)) {
          allMedia.add(ui);
          return;
        }
        if (seenFolders.length >= maxFoldersToScan) return;
        if (seenFolders.add(id)) folderQueue.add(id);
        return;
      }
      if (allMedia.length >= maxMediaItems) return;
      allMedia.add(ui);
    }

    for (final ui in rootItems) {
      push(ui);
    }

    if (folderQueue.isEmpty) {
      return _splitMedia(allMedia);
    }

    const maxWorkers = 2;
    final workerCount =
        folderQueue.length < maxWorkers ? folderQueue.length : maxWorkers;

    Future<void> worker() async {
      while (true) {
        if (outOfBudget()) return;
        if (cursor >= folderQueue.length) return;
        final folderId = folderQueue[cursor++];
        List<EmbyItem> children = const <EmbyItem>[];
        try {
          children = await _client
              .listChildren(parentId: folderId)
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          continue;
        }
        for (final child in children) {
          if (outOfBudget()) return;
          push(_toUiItem(child, maxWidth: 520));
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return _splitMedia(allMedia);
  }

  _UiItem _withCover(_UiItem src, String coverUrl) {
    return _UiItem(
      account: src.account,
      item: src.item,
      isDir: src.isDir,
      isImage: src.isImage,
      coverUrl: coverUrl,
    );
  }

  List<_UiItem> _applyHydratedCovers(
    List<_UiItem> src,
    Map<String, String> coverById,
  ) {
    if (src.isEmpty || coverById.isEmpty) return src;
    var changed = false;
    final out = <_UiItem>[];
    for (final item in src) {
      final id = item.item.id.trim();
      if (id.isEmpty) {
        out.add(item);
        continue;
      }
      final next = (coverById[id] ?? '').trim();
      if (next.isEmpty || next == item.coverUrl.trim()) {
        out.add(item);
        continue;
      }
      out.add(_withCover(item, next));
      changed = true;
    }
    return changed ? out : src;
  }

  List<String> _collectMovieFolderIds(
    Iterable<_UiItem> source,
    Set<String> seen,
  ) {
    final out = <String>[];
    for (final item in source) {
      if (!_isMovieFolder(item)) continue;
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      if ((_movieFolderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;
      if (_movieFolderPrimaryMisses.contains(id)) continue;
      out.add(id);
    }
    return out;
  }

  Future<void> _prewarmMovieCoverIds(
    List<String> targetIds, {
    required int token,
    required int runId,
    int maxWorkers = 2,
    bool gentle = false,
  }) async {
    if (targetIds.isEmpty || !mounted || token != _coverHydrationToken) return;

    var cursor = 0;
    final workerCount =
        targetIds.length < maxWorkers ? targetIds.length : maxWorkers;

    Future<void> worker() async {
      while (true) {
        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          return;
        }
        if (cursor >= targetIds.length) return;
        final id = targetIds[cursor++];
        if ((_movieFolderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;

        final primary = await _resolveMovieFolderPrimary(id);
        if (primary == null) continue;
        final url = _coverUrlFor(_client, primary.item, maxWidth: 520).trim();
        if (url.isEmpty) continue;

        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          return;
        }
        setState(() {
          _movieFolderCoverUrlCache[id] = url;
          final one = <String, String>{id: url};
          _items = _applyHydratedCovers(_items, one);
          _recursiveVideos = _applyHydratedCovers(_recursiveVideos, one);
        });

        if (gentle) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<List<_UiItem>> _movieFolderPlayables(String folderId,
      {required bool recursive}) async {
    try {
      final items = await _client
          .listChildren(
            parentId: folderId,
            recursive: recursive,
            includeItemTypes: 'Movie,Video,Episode,MusicVideo',
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            limit: recursive ? 260 : 120,
          )
          .timeout(const Duration(seconds: 8));
      return items
          .map((e) => _toUiItem(e, maxWidth: 520))
          .where((x) => _isVideoItem(x) && x.item.id.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <_UiItem>[];
    }
  }

  _UiItem _pickPrimaryMoviePlayable(List<_UiItem> src) {
    final out = src.toList(growable: false)
      ..sort((a, b) {
        final aMovie = _embyTypeIsMovie(a.item.type) ? 1 : 0;
        final bMovie = _embyTypeIsMovie(b.item.type) ? 1 : 0;
        if (aMovie != bMovie) return bMovie.compareTo(aMovie);

        final sizeCmp = b.item.size.compareTo(a.item.size);
        if (sizeCmp != 0) return sizeCmp;

        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    return out.first;
  }

  Future<_UiItem?> _resolveMovieFolderPrimary(String folderId) async {
    final id = folderId.trim();
    if (id.isEmpty) return null;
    if (_movieFolderPrimaryMisses.contains(id)) return null;

    final cached = _movieFolderPrimaryCache[id];
    if (cached != null && cached.item.id.trim().isNotEmpty) {
      return cached;
    }

    final inflight = _movieFolderPrimaryInflight[id];
    if (inflight != null) return await inflight;

    final fut = (() async {
      try {
        final self =
            await _client.getItemById(id).timeout(const Duration(seconds: 5));
        if (self != null &&
            !_embyItemIsDir(self) &&
            !_embyTypeIsImage(self.type)) {
          final primarySelf = _toUiItem(self, maxWidth: 520);
          _movieFolderPrimaryCache[id] = primarySelf;
          _movieFolderPrimaryMisses.remove(id);
          final selfCover = _coverUrlFor(_client, self, maxWidth: 520).trim();
          if (selfCover.isNotEmpty) {
            _movieFolderCoverUrlCache[id] = selfCover;
          }
          return primarySelf;
        }
      } catch (_) {}

      var playable = await _movieFolderPlayables(id, recursive: false);
      if (playable.isEmpty) {
        playable = await _movieFolderPlayables(id, recursive: true);
      }
      if (playable.isEmpty) {
        _movieFolderPrimaryMisses.add(id);
        return null;
      }

      final primary = _pickPrimaryMoviePlayable(playable);
      _movieFolderPrimaryCache[id] = primary;
      _movieFolderPrimaryMisses.remove(id);
      final cover = _coverUrlFor(_client, primary.item, maxWidth: 520).trim();
      if (cover.isNotEmpty) {
        _movieFolderCoverUrlCache[id] = cover;
      }
      return primary;
    })();

    _movieFolderPrimaryInflight[id] = fut;
    try {
      return await fut;
    } finally {
      _movieFolderPrimaryInflight.remove(id);
    }
  }

  Future<void> _prewarmVisibleMovieCovers({required int token}) async {
    if (!mounted || token != _coverHydrationToken) return;
    final runId = ++_moviePrewarmRunToken;
    final ordered = _displayItems();
    final seen = <String>{};
    final visiblePool = _collectMovieFolderIds(ordered.take(24), seen);
    final visibleFirst = visiblePool.take(12).toList(growable: false);
    final remaining = <String>[
      ...visiblePool.skip(12),
      ..._collectMovieFolderIds(ordered.skip(24), seen),
    ];

    await _prewarmMovieCoverIds(
      visibleFirst,
      token: token,
      runId: runId,
      maxWorkers: 2,
      gentle: false,
    );
    if (!mounted || token != _coverHydrationToken) return;
    if (runId != _moviePrewarmRunToken) return;

    await _prewarmMovieCoverIds(
      remaining,
      token: token,
      runId: runId,
      maxWorkers: 1,
      gentle: true,
    );
  }

  Future<void> _openMovieFolder(_UiItem item) async {
    final folderId = item.item.id.trim();
    if (folderId.isEmpty) return;

    final primary = await _resolveMovieFolderPrimary(folderId);
    if (primary != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _EmbyMovieDetailPage(
            account: widget.account,
            movieId: primary.item.id.trim(),
            seedMovie: primary.item,
            paletteMode: widget.paletteMode,
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: widget.account,
          title: _displayTitle(item),
          folderId: folderId,
          paletteMode: widget.paletteMode,
        ),
      ),
    );
  }

  Future<void> _reload() async {
    await _loadDisplaySettingsForCurrentFolder();
    _moviePrewarmRunToken++;
    _movieFolderPrimaryMisses.clear();
    final token = ++_coverHydrationToken;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      List<EmbyItem> raw = const <EmbyItem>[];
      if (widget.favoritesMode) {
        raw = await _client.listFavorites();
      } else if (widget.folderId.trim().isNotEmpty) {
        raw = await _client.listChildren(parentId: widget.folderId.trim());
      }

      final mapped =
          raw.map((e) => _toUiItem(e, maxWidth: 520)).toList(growable: false);
      final immediate = _splitMedia(mapped);
      final previousTopTab = _topTab;
      final nextTopTab = _chooseTopTab(
        current: _topTab,
        directItems: mapped,
        videos: immediate.videos,
        images: immediate.images,
      );
      if (!mounted) return;
      setState(() {
        _items = mapped;
        _recursiveVideos = immediate.videos;
        _recursiveImages = immediate.images;
        _topTab = nextTopTab;
        _loading = false;
      });
      if (previousTopTab != nextTopTab) {
        unawaited(_persistDisplaySettingsForCurrentFolder());
      }
      unawaited(_prewarmVisibleMovieCovers(token: token));
      unawaited(() async {
        try {
          final recursive = await _collectRecursiveMedia(mapped);
          if (!mounted || token != _coverHydrationToken) return;
          final previousTab = _topTab;
          final tab = _chooseTopTab(
            current: _topTab,
            directItems: mapped,
            videos: recursive.videos,
            images: recursive.images,
          );
          setState(() {
            _recursiveVideos = recursive.videos;
            _recursiveImages = recursive.images;
            _topTab = tab;
          });
          if (previousTab != tab) {
            unawaited(_persistDisplaySettingsForCurrentFolder());
          }
          unawaited(_prewarmVisibleMovieCovers(token: token));
        } catch (_) {}
      }());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  Future<void> _openItem(_UiItem item, {List<_UiItem>? pool}) async {
    final activePool = pool ?? _displayItems();

    if (_isSeriesDir(item)) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _EmbySeriesDetailPage(
            account: widget.account,
            seriesId: item.item.id.trim(),
            seedSeries: item.item,
            paletteMode: widget.paletteMode,
          ),
        ),
      );
      return;
    }

    if (_isMovieItem(item)) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _EmbyMovieDetailPage(
            account: widget.account,
            movieId: item.item.id.trim(),
            seedMovie: item.item,
            paletteMode: widget.paletteMode,
          ),
        ),
      );
      return;
    }

    if (_isMovieFolder(item)) {
      await _openMovieFolder(item);
      return;
    }

    if (item.isDir) {
      final folderId = item.item.id.trim();
      if (folderId.isEmpty) {
        if (!mounted) return;
        showAppToast(context, '该目录缺少 ID，无法打开', error: true);
        return;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _EmbyExclusiveFolderPage(
            account: widget.account,
            title: _displayTitle(item),
            folderId: folderId,
            paletteMode: widget.paletteMode,
          ),
        ),
      );
      return;
    }

    if (item.isImage) {
      final imageItems =
          activePool.where((x) => x.isImage).toList(growable: false);
      final urls = <String>[];
      var initialIndex = 0;
      for (final x in imageItems) {
        final url = _preferOriginalUrl(x.coverUrl).trim();
        if (url.isEmpty) continue;
        if (x.item.id == item.item.id) {
          initialIndex = urls.length;
        }
        urls.add(url);
      }
      if (urls.isEmpty) return;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths: urls,
            initialIndex: initialIndex.clamp(0, urls.length - 1),
          ),
        ),
      );
      return;
    }

    final playable = _playableItems(activePool);
    final paths = playable.map(_videoPathFor).toList(growable: false);
    if (paths.isEmpty) return;
    var idx = playable.indexWhere((x) => x.item.id == item.item.id);
    if (idx < 0) idx = 0;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          videoPaths: paths,
          initialIndex: idx.clamp(0, paths.length - 1),
        ),
      ),
    );
  }

  Widget _topTabButton(_FolderTopTab tab) {
    final p = _palette;
    final selected = _topTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _setTopTab(tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.chipSelectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _topTabLabel(tab),
          style: TextStyle(
            color: p.text,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _sortMenuButton() {
    final p = _palette;
    return PopupMenuButton<_FolderSortKind>(
      tooltip: '\u6392\u5e8f',
      onSelected: _onSortSelected,
      color: p.chipBg,
      itemBuilder: (_) => [
        for (final v in _FolderSortKind.values)
          PopupMenuItem<_FolderSortKind>(
            value: v,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _sortLabel(v),
                    style: TextStyle(color: p.text),
                  ),
                ),
                if (_sort == v)
                  Icon(
                    _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                    color: p.text,
                    size: 16,
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: p.chipBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, color: p.text, size: 16),
            const SizedBox(width: 6),
            Text(
              _sortLabel(_sort),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              color: p.text,
              size: 15,
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerControls(int count) {
    final p = _palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: p.chipBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _topTabButton(_FolderTopTab.videos),
              if (_hasImages) _topTabButton(_FolderTopTab.images),
              _topTabButton(_FolderTopTab.folders),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _sortMenuButton(),
            const SizedBox(width: 8),
            const Spacer(),
            Text(
              '\u5171 $count \u9879',
              style: TextStyle(
                color: p.sub,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _cover(_UiItem item) {
    final p = _palette;
    final url = item.coverUrl.trim();
    final isMovie = _isMovieItem(item) || _isMovieFolder(item);
    final token = widget.account.apiKey.trim();
    final headers =
        token.isEmpty ? null : <String, String>{'X-Emby-Token': token};
    final coverWidth = item.isImage ? 860 : (isMovie ? 620 : 560);
    final icon = _isSeriesFolder(item)
        ? Icons.live_tv_outlined
        : (isMovie
            ? Icons.movie_outlined
            : (item.isDir
                ? Icons.folder_open_rounded
                : (item.isImage
                    ? Icons.image_outlined
                    : Icons.video_file_outlined)));

    Widget emptyPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(child: Icon(icon, color: p.sub)),
      );
    }

    Widget brokenPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(child: Icon(Icons.broken_image_outlined, color: p.sub)),
      );
    }

    Widget buildDirAutoFallback() {
      return FutureBuilder<String?>(
        future: _resolveFolderCoverFallback(item, maxWidth: coverWidth),
        builder: (_, snap) {
          final auto = (snap.data ?? '').trim();
          if (auto.isEmpty || auto == url) return emptyPlaceholder();
          return Image.network(
            auto,
            headers: headers,
            fit: BoxFit.cover,
            cacheWidth: coverWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => brokenPlaceholder(),
          );
        },
      );
    }

    Widget buildDirSeed(String seedUrl) {
      return Image.network(
        seedUrl,
        headers: headers,
        fit: BoxFit.cover,
        cacheWidth: coverWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => buildDirAutoFallback(),
      );
    }

    if (item.isDir) {
      if (url.isEmpty) return buildDirAutoFallback();
      return buildDirSeed(url);
    }

    if (url.isEmpty) {
      return emptyPlaceholder();
    }
    return Image.network(
      url,
      headers: headers,
      fit: BoxFit.cover,
      cacheWidth: coverWidth,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => brokenPlaceholder(),
    );
  }

  String _itemKindLabel(_UiItem item) {
    if (_isSeriesFolder(item)) return '\u5267\u96c6';
    if (_isMovieFolder(item)) return '\u7535\u5f71';
    if (item.isDir) return '\u6587\u4ef6\u5939';
    if (item.isImage) return '\u56fe\u7247';
    return '\u89c6\u9891';
  }

  String _displayTitle(_UiItem item) {
    final raw = item.title.trim();
    if (!_isMovieFolder(item)) return raw;
    final stripped = raw.replaceAll(
      RegExp(
        r'\s*\[(?:tmdbid|imdbid|tvdbid|doubanid)[^\]]*\]',
        caseSensitive: false,
      ),
      '',
    );
    final compact = stripped.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return compact.isEmpty ? raw : compact;
  }

  @override
  Widget build(BuildContext context) {
    final body = () {
      if (_loading) {
        return Center(
            child: CircularProgressIndicator(color: _palette.progress));
      }
      if (_loadError != null) {
        return Center(
            child: Text(friendlyErrorMessage(_loadError!),
                style: TextStyle(color: _palette.sub)));
      }

      final shown = _displayItems();
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          children: [
            _headerControls(shown.length),
            const SizedBox(height: 12),
            if (shown.isEmpty)
              SizedBox(
                height: 220,
                child: Center(
                  child: Text('\u76ee\u5f55\u4e3a\u7a7a',
                      style: TextStyle(color: _palette.sub)),
                ),
              ),
            if (shown.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final coverAspect = _dominantCoverAspect(shown);
                  final isTablet =
                      MediaQuery.sizeOf(context).shortestSide >= 600;
                  final columns = _adaptiveGridColumns(
                    width: width,
                    coverAspectRatio: coverAspect,
                    isTablet: isTablet,
                  );
                  final childAspect = _gridChildAspectRatio(
                    maxWidth: width,
                    columns: columns,
                    coverAspectRatio: coverAspect,
                  );
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: shown.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 12,
                      childAspectRatio: childAspect,
                    ),
                    itemBuilder: (_, i) {
                      final item = shown[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openItem(item, pool: shown),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(7),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: coverAspect,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: _cover(item),
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                _displayTitle(item),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _palette.text,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.16,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _itemKindLabel(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _palette.sub,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      );
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _palette.statusStyle,
      child: Scaffold(
        backgroundColor: _palette.bg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: _palette.panel,
          foregroundColor: _palette.text,
          iconTheme: IconThemeData(color: _palette.text),
          leading: IconButton(
            tooltip: '\u8fd4\u56de',
            onPressed: () => Navigator.maybePop(context),
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: _palette.text),
          ),
          titleSpacing: 0,
          title: Text(
            widget.title.trim().isEmpty ? '\u5a92\u4f53\u5e93' : widget.title,
            style: TextStyle(color: _palette.text),
          ),
          actions: [
            IconButton(
              onPressed: _reload,
              icon: Icon(Icons.refresh_rounded, color: _palette.text),
            ),
          ],
        ),
        body: SafeArea(child: body),
      ),
    );
  }
}

class _EmbySeriesDetailPage extends StatefulWidget {
  final EmbyAccount account;
  final String seriesId;
  final EmbyItem seedSeries;
  final _EmbyPaletteMode paletteMode;

  const _EmbySeriesDetailPage({
    required this.account,
    required this.seriesId,
    required this.seedSeries,
    required this.paletteMode,
  });

  @override
  State<_EmbySeriesDetailPage> createState() => _EmbySeriesDetailPageState();
}

class _EmbySeriesDetailPageState extends State<_EmbySeriesDetailPage> {
  late final EmbyClient _client = EmbyClient(widget.account);
  bool _loading = true;
  Object? _loadError;
  EmbyItem? _series;
  List<_UiItem> _seasons = const <_UiItem>[];
  List<_UiItem> _episodes = const <_UiItem>[];
  List<_UiItem> _continueEpisodes = const <_UiItem>[];

  _EmbyPalette get _palette => _paletteForMode(widget.paletteMode);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  bool _isSeriesDir(_UiItem item) {
    if (!item.isDir) return false;
    return item.item.type.trim().toLowerCase().contains('series');
  }

  bool _isSeasonType(EmbyItem item) {
    final t = item.type.trim().toLowerCase();
    return t == 'season' || t.contains('season');
  }

  _UiItem _toUiItem(EmbyItem item, {int maxWidth = 520}) {
    final isDir = _embyItemIsDir(item);
    final isImage = !isDir && _embyTypeIsImage(item.type);
    return _UiItem(
      account: widget.account,
      item: item,
      isDir: isDir,
      isImage: isImage,
      coverUrl: _coverUrlFor(_client, item, maxWidth: maxWidth),
    );
  }

  List<_UiItem> _uniqueById(List<_UiItem> src) {
    final out = <_UiItem>[];
    final seen = <String>{};
    for (final item in src) {
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add(item);
    }
    return out;
  }

  Future<List<EmbyItem>> _safeChildren({
    required String parentId,
    required bool recursive,
    required String sortBy,
    required String sortOrder,
    required String includeItemTypes,
    required int limit,
  }) async {
    try {
      return await _client
          .listChildren(
            parentId: parentId,
            recursive: recursive,
            includeItemTypes: includeItemTypes,
            sortBy: sortBy,
            sortOrder: sortOrder,
            limit: limit,
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return const <EmbyItem>[];
    }
  }

  Future<List<EmbyItem>> _loadContinueEpisodes(String seriesId) async {
    final byPlayed = await _safeChildren(
      parentId: seriesId,
      recursive: true,
      includeItemTypes: 'Episode',
      sortBy: 'DatePlayed',
      sortOrder: 'Descending',
      limit: 40,
    );
    if (byPlayed.isNotEmpty) return byPlayed;
    return _safeChildren(
      parentId: seriesId,
      recursive: true,
      includeItemTypes: 'Episode',
      sortBy: 'DateModified',
      sortOrder: 'Descending',
      limit: 40,
    );
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final sid = widget.seriesId.trim();
      final loadedSeries = await _client.getItemById(sid);
      final series = loadedSeries ?? widget.seedSeries;
      final rootSeriesId =
          (series.seriesId ?? widget.seedSeries.seriesId ?? '').trim();
      final seasonsParentId =
          _isSeasonType(series) && rootSeriesId.isNotEmpty ? rootSeriesId : sid;

      final loaded = await Future.wait<List<EmbyItem>>([
        _safeChildren(
          parentId: seasonsParentId,
          recursive: false,
          includeItemTypes: 'Season',
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          limit: 300,
        ),
        _safeChildren(
          parentId: sid,
          recursive: true,
          includeItemTypes: 'Episode',
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          limit: 2000,
        ),
        _loadContinueEpisodes(sid),
      ]);
      final seasonsRaw = loaded[0];
      final episodesRaw = loaded[1];
      final continueRaw = loaded[2];

      final seasons = _uniqueById(
        seasonsRaw
            .where(_isSeasonType)
            .map((e) => _toUiItem(e, maxWidth: 360))
            .toList(growable: false),
      );
      final episodes = _uniqueById(
        episodesRaw
            .map((e) => _toUiItem(e, maxWidth: 640))
            .where((e) => !e.isDir && !e.isImage)
            .toList(growable: false),
      );
      var continueEpisodes = _uniqueById(
        continueRaw
            .map((e) => _toUiItem(e, maxWidth: 640))
            .where((e) => !e.isDir && !e.isImage)
            .toList(growable: false),
      );
      if (continueEpisodes.isEmpty) {
        continueEpisodes = episodes.reversed.take(20).toList(growable: false);
      }

      if (!mounted) return;
      setState(() {
        _series = series;
        _seasons = seasons;
        _episodes = episodes;
        _continueEpisodes = continueEpisodes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  String _backdropUrl(EmbyItem series) {
    if (series.backdropTags.isNotEmpty) {
      return _client.coverUrl(
        series.id,
        type: 'Backdrop',
        index: 0,
        maxWidth: 1400,
        quality: 90,
        tag: series.backdropTags.first,
      );
    }
    if (series.primaryTag != null) {
      return _client.coverUrl(
        series.id,
        type: 'Primary',
        maxWidth: 1200,
        quality: 90,
        tag: series.primaryTag,
      );
    }
    return _client.coverUrl(
      series.id,
      type: 'Primary',
      maxWidth: 1200,
      quality: 90,
    );
  }

  String _episodeThumbUrl(_UiItem ep) {
    final tag = ep.item.thumbTag;
    if (tag != null && tag.trim().isNotEmpty) {
      return _client.coverUrl(
        ep.item.id,
        type: 'Thumb',
        maxWidth: 640,
        quality: 85,
        tag: tag,
      );
    }
    return ep.coverUrl;
  }

  List<_UiItem> _episodePlaylist() {
    final out = _episodes.where((e) => !_isSeriesDir(e)).toList(growable: true);
    out.sort((a, b) {
      final ad = a.item.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.item.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0);
      var cmp = ad.compareTo(bd);
      if (cmp == 0) {
        cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
      return cmp;
    });
    return out;
  }

  Map<String, int> _episodeNumberById(List<_UiItem> playlist) {
    final out = <String, int>{};
    for (var i = 0; i < playlist.length; i++) {
      final id = playlist[i].item.id.trim();
      if (id.isEmpty) continue;
      out[id] = i + 1;
    }
    return out;
  }

  Future<void> _playEpisode(_UiItem current, {List<_UiItem>? pool}) async {
    final items = (pool ?? _episodePlaylist())
        .where((e) => !e.isDir && !e.isImage && e.item.id.trim().isNotEmpty)
        .toList(growable: false);
    final paths = items.map(_videoPathFor).toList(growable: false);
    if (paths.isEmpty) return;
    var idx = items.indexWhere((e) => e.item.id == current.item.id);
    if (idx < 0) idx = 0;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          videoPaths: paths,
          initialIndex: idx.clamp(0, paths.length - 1),
        ),
      ),
    );
  }

  Future<void> _playPrimary() async {
    final playlist = _episodePlaylist();
    if (playlist.isEmpty) return;
    await _playEpisode(playlist.first, pool: playlist);
  }

  Future<void> _openSeason(_UiItem season) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbySeriesDetailPage(
          account: widget.account,
          seriesId: season.item.id.trim(),
          seedSeries: season.item,
          paletteMode: widget.paletteMode,
        ),
      ),
    );
  }

  Future<void> _openAllEpisodes() async {
    final id = widget.seriesId.trim();
    if (id.isEmpty || !mounted) return;
    final series = _series ?? widget.seedSeries;
    final title = series.name.trim().isEmpty
        ? '\u5168\u90e8\u5267\u96c6'
        : series.name.trim();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: widget.account,
          title: title,
          folderId: id,
          paletteMode: widget.paletteMode,
        ),
      ),
    );
  }

  String _metaLine(EmbyItem series) {
    final parts = <String>[];
    final rating = series.communityRating;
    if (rating != null && rating > 0) {
      parts.add('豆${rating.toStringAsFixed(1)}');
    }
    final start = series.productionYear;
    if (start != null && start > 0) {
      final end = series.endDate == null ? '现在' : '${series.endDate!.year}';
      parts.add('$start - $end');
    }
    final seasonCount = _seasons.length;
    if (seasonCount > 0) {
      parts.add('共$seasonCount季');
    }
    return parts.join('    ');
  }

  Widget _hero(EmbyItem series) {
    final p = _palette;
    final backdrop = _backdropUrl(series).trim();
    return SizedBox(
      height: 286,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            Image.network(
              backdrop,
              fit: BoxFit.cover,
              cacheWidth: 1400,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: p.coverPlaceholderBg),
            )
          else
            ColoredBox(color: p.coverPlaceholderBg),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.68),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.favorite_border_rounded,
                        color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 18,
            child: Text(
              series.name.trim().isEmpty ? '未命名剧集' : series.name.trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 14, color: Colors.black54)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeShelf(List<_UiItem> items) {
    final p = _palette;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('暂无内容', style: TextStyle(color: p.sub)),
      );
    }
    final shelf = items.take(20).toList(growable: false);
    final playlist = _episodePlaylist();
    final numberById = _episodeNumberById(playlist);
    return SizedBox(
      height: 138,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: shelf.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final ep = shelf[i];
          final no = numberById[ep.item.id.trim()];
          final title = no == null ? ep.title : '$no. ${ep.title}';
          final thumb = _episodeThumbUrl(ep).trim();
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _playEpisode(ep, pool: playlist),
            child: SizedBox(
              width: 182,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: thumb.isEmpty
                          ? ColoredBox(
                              color: p.coverPlaceholderBg,
                              child: Center(
                                child: Icon(Icons.movie_outlined, color: p.sub),
                              ),
                            )
                          : Image.network(
                              thumb,
                              fit: BoxFit.cover,
                              cacheWidth: 640,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                color: p.coverPlaceholderBg,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: p.sub),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _seasonShelf(List<_UiItem> items) {
    final p = _palette;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('暂无分季信息', style: TextStyle(color: p.sub)),
      );
    }
    return SizedBox(
      height: 216,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final season = items[i];
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openSeason(season),
            child: SizedBox(
              width: 112,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 0.67,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: season.coverUrl.trim().isEmpty
                          ? ColoredBox(
                              color: p.coverPlaceholderBg,
                              child: Center(
                                child: Icon(Icons.video_collection_outlined,
                                    color: p.sub),
                              ),
                            )
                          : Image.network(
                              season.coverUrl,
                              fit: BoxFit.cover,
                              cacheWidth: 420,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                color: p.coverPlaceholderBg,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: p.sub),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    season.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette;
    final series = _series ?? widget.seedSeries;
    final genres = series.genres.take(4).join(', ');
    final description = (series.overview ?? '').trim();
    final meta = _metaLine(series);

    final body = () {
      if (_loading) {
        return Center(child: CircularProgressIndicator(color: p.progress));
      }
      if (_loadError != null) {
        return Center(
          child: Text(
            friendlyErrorMessage(_loadError!),
            style: TextStyle(color: p.sub),
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _hero(series),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      genres,
                      style: TextStyle(
                        color: p.sub,
                        fontSize: 13,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _playPrimary,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('播放'),
                          style: FilledButton.styleFrom(
                            backgroundColor: p.chipSelectedBg,
                            foregroundColor: p.text,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            textStyle: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 66,
                        child: FilledButton(
                          onPressed: _openAllEpisodes,
                          style: FilledButton.styleFrom(
                            backgroundColor: p.chipSelectedBg,
                            foregroundColor: p.text,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          child: const Icon(Icons.format_list_bulleted_rounded),
                        ),
                      ),
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      description,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Text(
                    '继续观看',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _episodeShelf(_continueEpisodes),
                  const SizedBox(height: 16),
                  Text(
                    '季',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _seasonShelf(_seasons),
                ],
              ),
            ),
          ],
        ),
      );
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: p.statusStyle,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}

class _EmbyMovieDetailPage extends StatefulWidget {
  final EmbyAccount account;
  final String movieId;
  final EmbyItem seedMovie;
  final _EmbyPaletteMode paletteMode;

  const _EmbyMovieDetailPage({
    required this.account,
    required this.movieId,
    required this.seedMovie,
    required this.paletteMode,
  });

  @override
  State<_EmbyMovieDetailPage> createState() => _EmbyMovieDetailPageState();
}

class _EmbyMovieDetailPageState extends State<_EmbyMovieDetailPage> {
  late final EmbyClient _client = EmbyClient(widget.account);
  bool _loading = true;
  Object? _loadError;
  EmbyItem? _movie;

  _EmbyPalette get _palette => _paletteForMode(widget.paletteMode);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final id = widget.movieId.trim();
      final loadedMovie = await _client.getItemById(id);
      if (!mounted) return;
      setState(() {
        _movie = loadedMovie ?? widget.seedMovie;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  _UiItem _toUiItem(EmbyItem item, {int maxWidth = 640}) {
    final isDir = _embyItemIsDir(item);
    final isImage = !isDir && _embyTypeIsImage(item.type);
    return _UiItem(
      account: widget.account,
      item: item,
      isDir: isDir,
      isImage: isImage,
      coverUrl: _coverUrlFor(_client, item, maxWidth: maxWidth),
    );
  }

  String _backdropUrl(EmbyItem movie) {
    if (movie.backdropTags.isNotEmpty) {
      return _client.coverUrl(
        movie.id,
        type: 'Backdrop',
        index: 0,
        maxWidth: 1400,
        quality: 90,
        tag: movie.backdropTags.first,
      );
    }
    if (movie.primaryTag != null) {
      return _client.coverUrl(
        movie.id,
        type: 'Primary',
        maxWidth: 1200,
        quality: 90,
        tag: movie.primaryTag,
      );
    }
    return _client.coverUrl(
      movie.id,
      type: 'Primary',
      maxWidth: 1200,
      quality: 90,
    );
  }

  String _durationLabel(int? runTimeTicks) {
    final ticks = runTimeTicks ?? 0;
    if (ticks <= 0) return '';
    const ticksPerMinute = 600000000;
    final totalMinutes = ticks ~/ ticksPerMinute;
    if (totalMinutes <= 0) return '';
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${totalMinutes}m';
    if (minutes <= 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  String _metaLine(EmbyItem movie) {
    final parts = <String>[];
    final rating = movie.communityRating;
    if (rating != null && rating > 0) {
      parts.add('\u8bc4\u5206 ${rating.toStringAsFixed(1)}');
    }
    final year = movie.productionYear;
    if (year != null && year > 0) {
      parts.add('$year');
    }
    final duration = _durationLabel(movie.runTimeTicks);
    if (duration.isNotEmpty) {
      parts.add(duration);
    }
    return parts.join('    ');
  }

  Future<void> _playMovie() async {
    final movie = _movie ?? widget.seedMovie;
    final path = _videoPathFor(_toUiItem(movie));
    if (path.trim().isEmpty) return;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          videoPaths: <String>[path],
          initialIndex: 0,
        ),
      ),
    );
  }

  Widget _hero(EmbyItem movie) {
    final p = _palette;
    final backdrop = _backdropUrl(movie).trim();
    return SizedBox(
      height: 286,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            Image.network(
              backdrop,
              fit: BoxFit.cover,
              cacheWidth: 1400,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: p.coverPlaceholderBg),
            )
          else
            ColoredBox(color: p.coverPlaceholderBg),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.68),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '\u8fd4\u56de',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 18,
            child: Text(
              movie.name.trim().isEmpty
                  ? '\u672a\u547d\u540d\u7535\u5f71'
                  : movie.name.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 14, color: Colors.black54)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette;
    final movie = _movie ?? widget.seedMovie;
    final meta = _metaLine(movie);
    final genres = movie.genres.take(4).join(', ');
    final overview = (movie.overview ?? '').trim();

    final body = () {
      if (_loading) {
        return Center(child: CircularProgressIndicator(color: p.progress));
      }
      if (_loadError != null) {
        return Center(
          child: Text(
            friendlyErrorMessage(_loadError!),
            style: TextStyle(color: p.sub),
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _hero(movie),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      genres,
                      style: TextStyle(
                        color: p.sub,
                        fontSize: 13,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _playMovie,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('\u64ad\u653e'),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.chipSelectedBg,
                        foregroundColor: p.text,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        textStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      overview,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: p.statusStyle,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}
