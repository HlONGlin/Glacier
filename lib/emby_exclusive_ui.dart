import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby.dart';
import 'emby_native_logic.dart';
import 'emby_read_scheme.dart';
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
const ScrollPhysics _kEmbyScrollPhysics =
    BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

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

bool _embyTypeIsImage(String t) {
  return embyNativeTypeIsImage(t);
}

bool _embyTypeIsMovie(String t) {
  return embyNativeTypeIsMovie(t);
}

bool _embyTypeIsEpisode(String t) {
  return embyNativeTypeIsEpisode(t);
}

bool _isLikelyMovieVideo(
  EmbyItem item, {
  bool preferMovieVideos = false,
  bool preferSeriesVideos = false,
}) {
  if (preferSeriesVideos) return false;
  if (preferMovieVideos) return embyNativeItemIsMovie(item);
  return embyNativeItemIsMovie(item);
}

bool _embyItemIsDir(EmbyItem item) {
  return embyNativeItemIsFolder(item);
}

bool _looksLikeMovieFolder(EmbyItem item) {
  return embyNativeFolderIsMovieCollection(item);
}

final RegExp _kMovieMetaTagBracketPattern = RegExp(
  r'\s*\[(?:tmdbid|imdbid|tvdbid|doubanid)[^\]]*\]',
  caseSensitive: false,
);
final RegExp _kMultiSpacePattern = RegExp(r'\s{2,}');

bool _isAsciiDigitCodeUnit(int c) => c >= 0x30 && c <= 0x39;

int _naturalTitleCompare(String a, String b) {
  final sa = a.trim().toLowerCase();
  final sb = b.trim().toLowerCase();
  if (sa == sb) return 0;

  var ia = 0;
  var ib = 0;
  while (ia < sa.length && ib < sb.length) {
    final ca = sa.codeUnitAt(ia);
    final cb = sb.codeUnitAt(ib);
    final da = _isAsciiDigitCodeUnit(ca);
    final db = _isAsciiDigitCodeUnit(cb);

    if (da && db) {
      final startA = ia;
      final startB = ib;
      while (ia < sa.length && _isAsciiDigitCodeUnit(sa.codeUnitAt(ia))) {
        ia++;
      }
      while (ib < sb.length && _isAsciiDigitCodeUnit(sb.codeUnitAt(ib))) {
        ib++;
      }

      var nzA = startA;
      var nzB = startB;
      while (nzA < ia - 1 && sa.codeUnitAt(nzA) == 0x30) {
        nzA++;
      }
      while (nzB < ib - 1 && sb.codeUnitAt(nzB) == 0x30) {
        nzB++;
      }

      final lenA = ia - nzA;
      final lenB = ib - nzB;
      if (lenA != lenB) return lenA.compareTo(lenB);

      for (var i = 0; i < lenA; i++) {
        final cmp = sa.codeUnitAt(nzA + i).compareTo(sb.codeUnitAt(nzB + i));
        if (cmp != 0) return cmp;
      }

      final leadingA = nzA - startA;
      final leadingB = nzB - startB;
      if (leadingA != leadingB) return leadingA.compareTo(leadingB);
      continue;
    }

    if (ca != cb) return ca.compareTo(cb);
    ia++;
    ib++;
  }
  return sa.length.compareTo(sb.length);
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

class _FolderPageSeed {
  final List<_UiItem> directItems;
  final List<_UiItem> recursiveVideos;
  final List<_UiItem> recursiveImages;
  final EmbyLibraryKindSignal kindHint;

  const _FolderPageSeed({
    this.directItems = const <_UiItem>[],
    this.recursiveVideos = const <_UiItem>[],
    this.recursiveImages = const <_UiItem>[],
    this.kindHint = EmbyLibraryKindSignal.unknown,
  });

  bool get hasAnyData =>
      directItems.isNotEmpty ||
      recursiveVideos.isNotEmpty ||
      recursiveImages.isNotEmpty;
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
  Map<String, EmbyReadCoordinator> _readers =
      const <String, EmbyReadCoordinator>{};
  List<_UiItem> _libraries = const <_UiItem>[];
  List<_UiItem> _resume = const <_UiItem>[];
  List<_UiItem> _nextUp = const <_UiItem>[];
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

  // ignore: unused_element
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
    return embyNativeItemIsEpisode(item);
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
      datePlayed: episode.datePlayed,
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
    return embyNativeTypeIsSeries(item.type);
  }

  Future<List<_UiItem>> _deriveHomeNextUp(
    EmbyAccount account,
    EmbyClient client,
    List<_UiItem> resumeItems,
  ) async {
    final episodeSeeds = resumeItems
        .where((x) {
          final sid = (x.item.seriesId ?? '').trim();
          return sid.isNotEmpty && _isEpisodeItem(x.item);
        })
        .take(8)
        .toList(growable: false);
    if (episodeSeeds.isEmpty) return const <_UiItem>[];

    final out = <_UiItem>[];
    final seenSeries = <String>{};
    final seenEpisodeIds = <String>{};

    for (final seed in episodeSeeds) {
      final seriesId = (seed.item.seriesId ?? '').trim();
      if (seriesId.isEmpty || !seenSeries.add(seriesId)) continue;
      try {
        final episodes = await client
            .listChildren(
              parentId: seriesId,
              recursive: true,
              includeItemTypes: 'Episode',
              sortBy: 'SortName',
              sortOrder: 'Ascending',
              limit: 400,
            )
            .timeout(_kHomeRequestTimeout);
        if (episodes.isEmpty) continue;
        final currentId = seed.item.id.trim();
        final currentIndex =
            episodes.indexWhere((e) => e.id.trim() == currentId);
        if (currentIndex < 0 || currentIndex >= episodes.length - 1) continue;
        final next = episodes[currentIndex + 1];
        final nextId = next.id.trim();
        if (nextId.isEmpty || !seenEpisodeIds.add(nextId)) continue;
        out.add(_toUiItem(account, client, next, maxWidth: 640));
      } catch (_) {}
    }
    return out;
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

    final collectionType = (v.collectionType ?? '').trim().toLowerCase();
    final keepEpisodeLatest =
        collectionType == 'tvshows' || collectionType == 'series';
    final latest = keepEpisodeLatest
        ? children
        : _collapseLatestEpisodesToSeries(children);
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

  Future<
      ({
        List<_UiItem> lib,
        List<_UiItem> resume,
        List<_UiItem> favorites,
        List<EmbyItem> views
      })> _loadAccountData(
    EmbyAccount a,
    EmbyClient c,
    EmbyReadCoordinator reader, {
    bool forceRefresh = false,
  }) async {
    final loaded = await reader.loadHomeCore(forceRefresh: forceRefresh);
    final views = loaded.views;
    final resume = loaded.resume;
    final favorites = loaded.favorites;

    final libOut = views
        .map((e) => _toUiItem(a, c, e, maxWidth: 520))
        .toList(growable: false);
    final resumeOut = resume
        .map((e) => _toUiItem(a, c, e, maxWidth: 520))
        .toList(growable: false);
    final favoritesOut = favorites
        .map((e) => _toUiItem(a, c, e, maxWidth: 420))
        .toList(growable: false);
    return (
      lib: libOut,
      resume: resumeOut,
      favorites: favoritesOut,
      views: views,
    );
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
    final reader = _readers[id];
    if (account == null || client == null || reader == null) return;

    if (!mounted || token != _reloadToken) return;
    setState(() {
      _loadError = null;
      _loading = true;
      _sectionsLoading = true;
      _favoritesLoading = true;
    });

    try {
      final accountData = await _loadAccountData(
        account,
        client,
        reader,
        forceRefresh: force,
      );
      final uniqLib = _unique(accountData.lib)
        ..sort((a, b) => _naturalTitleCompare(a.title, b.title));
      final uniqResume = _unique(accountData.resume)
        ..sort((a, b) => (b.item.dateModified ?? DateTime(1970))
            .compareTo(a.item.dateModified ?? DateTime(1970)));
      final uniqFav = _unique(accountData.favorites)
        ..sort((a, b) => _naturalTitleCompare(a.title, b.title));
      final sectionsFuture =
          _loadLatestSections(account, client, accountData.views);
      final nextUpFuture = _deriveHomeNextUp(account, client, uniqResume);
      final sections = await sectionsFuture;
      final nextUp = await nextUpFuture;

      if (!mounted || token != _reloadToken) return;
      setState(() {
        _libraries = _replaceItemsForAccount(_libraries, id, uniqLib);
        _resume = _replaceItemsForAccount(_resume, id, uniqResume);
        _nextUp = _replaceItemsForAccount(_nextUp, id, nextUp);
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
      final readers = <String, EmbyReadCoordinator>{
        for (final a in accounts)
          a.id: EmbyReadCoordinator(
            client: clients[a.id]!,
            accountId: a.id,
          ),
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
        _readers = readers;
        _libraries = const <_UiItem>[];
        _resume = const <_UiItem>[];
        _nextUp = const <_UiItem>[];
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
    _FolderPageSeed? seed,
    bool favoritesMode = false,
  }) async {
    final preparedSeed = seed ??
        await _prepareFolderSeed(
          account: account,
          folderId: folderId,
          favoritesMode: favoritesMode,
        );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: account,
          title: title.trim().isEmpty ? '\u5a92\u4f53\u5e93' : title.trim(),
          folderId: folderId,
          favoritesMode: favoritesMode,
          initialSeed: preparedSeed,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  Future<void> _openFavoritesUi({required EmbyAccount account}) async {
    final seed = _FolderPageSeed(
      directItems: _favorites
          .where((x) => x.account.id == account.id)
          .toList(growable: false),
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: account,
          title: '${_accountName(account.id)} \u6536\u85cf',
          folderId: '',
          favoritesMode: true,
          initialSeed: seed,
          paletteMode: _paletteMode,
        ),
      ),
    );
  }

  Future<_FolderPageSeed?> _prepareFolderSeed({
    required EmbyAccount account,
    required String folderId,
    bool favoritesMode = false,
  }) async {
    final reader = _readers[account.id];
    final client = _clients[account.id];
    if (reader == null || client == null) return null;
    try {
      final plan = await reader.readFolder(
        folderId: folderId.trim(),
        favoritesMode: favoritesMode,
      );
      final snap = plan.immediate;
      final directItems = snap.directItems
          .map((e) => _toUiItem(account, client, e, maxWidth: 520))
          .toList(growable: false);
      final directIndex = <String, _UiItem>{
        for (final item in directItems)
          if (item.item.id.trim().isNotEmpty) item.item.id.trim(): item,
      };
      List<_UiItem> mapWithSeed(Iterable<EmbyItem> src) {
        final out = <_UiItem>[];
        for (final item in src) {
          final cached = directIndex[item.id.trim()];
          out.add(cached ?? _toUiItem(account, client, item, maxWidth: 520));
        }
        return out;
      }

      return _FolderPageSeed(
        directItems: directItems,
        recursiveVideos: mapWithSeed(snap.directMedia.videos),
        recursiveImages: mapWithSeed(snap.directMedia.images),
        kindHint: snap.libraryKind,
      );
    } catch (_) {
      return null;
    }
  }

  bool _isSeriesDir(_UiItem item) {
    if (!item.isDir) return false;
    return embyNativeTypeIsSeries(item.item.type);
  }

  bool _isMovieItem(_UiItem item) {
    return _isLikelyMovieVideo(item.item);
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

  Future<void> _openItem(_UiItem item, {List<_UiItem>? pool}) async {
    if (_isSeriesDir(item)) {
      await _openSeriesUi(item);
      return;
    }
    if (_isMovieItem(item)) {
      await _openMovieUi(item);
      return;
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
            ..sort((a, b) => _naturalTitleCompare(a.title, b.title));
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

    Widget buildDirSeed(String seedUrl) {
      return Image.network(
        seedUrl,
        headers: headers,
        fit: BoxFit.cover,
        cacheWidth: coverWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => emptyPlaceholder(),
      );
    }

    if (item.isDir) {
      if (url.isEmpty) return emptyPlaceholder();
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _cover(item),
                      _itemBadgeOverlay(item),
                      _progressOverlay(item.item),
                    ],
                  ),
                ),
              )
            else
              AspectRatio(
                aspectRatio: aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _cover(item),
                      _itemBadgeOverlay(item),
                      _progressOverlay(item.item),
                    ],
                  ),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, color: _palette.sub),
              const SizedBox(height: 6),
              Text(
                '\u6682\u65e0\u5185\u5bb9',
                style: TextStyle(color: _palette.sub),
              ),
            ],
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
        physics: const BouncingScrollPhysics(),
        cacheExtent: 960,
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
          label: '首页',
        ),
        _homeTabItem(
          tab: _EmbyHomeTab.favorites,
          icon: Icons.favorite_border_rounded,
          label: '收藏',
        ),
        _homeTabItem(
          tab: _EmbyHomeTab.search,
          icon: Icons.search_rounded,
          label: '\u641c\u7d22',
        ),
      ],
    );
  }

  String _homeTypeLabel(_UiItem it) {
    if (it.isImage) return '\u56fe\u7247';
    if (it.isDir) {
      if (embyNativeTypeIsSeries(it.item.type)) return '\u5267\u96c6';
      return '\u6587\u4ef6\u5939';
    }
    if (_embyTypeIsMovie(it.item.type)) return '\u7535\u5f71';
    if (_embyTypeIsEpisode(it.item.type)) return '\u5267\u96c6';
    return '\u89c6\u9891';
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

  bool _isResumableItem(EmbyItem item) {
    final played = item.playedPercentage ?? 0;
    if (item.playbackPositionTicks > 0 && played < 95) return true;
    return item.playbackPositionTicks > 0 && !item.isPlayed;
  }

  double _progressRatio(EmbyItem item) {
    final played = item.playedPercentage;
    if (played != null && played.isFinite && played > 0) {
      return (played / 100).clamp(0.0, 1.0);
    }
    final ticks = item.playbackPositionTicks;
    final runtime = item.runTimeTicks ?? 0;
    if (ticks > 0 && runtime > 0) {
      return (ticks / runtime).clamp(0.0, 1.0);
    }
    return 0;
  }

  Widget _progressOverlay(EmbyItem item) {
    final ratio = _progressRatio(item);
    if (ratio <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 4,
        color: Colors.black.withValues(alpha: 0.34),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio,
          child: Container(color: _palette.progress),
        ),
      ),
    );
  }

  Widget _itemBadgeOverlay(_UiItem item) {
    final unplayed = item.item.unplayedItemCount;
    final resumable = _isResumableItem(item.item);
    final label = unplayed > 0
        ? '未看 $unplayed'
        : resumable
            ? '继续播放'
            : '';
    if (label.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 8,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _homeMetaLine(_UiItem it) {
    final item = it.item;
    final parts = <String>[];
    final year = item.productionYear;
    if (year != null && year > 0) parts.add('$year');
    final rating = item.communityRating;
    if (rating != null && rating > 0) {
      parts.add('\u8bc4\u5206 ${rating.toStringAsFixed(1)}');
    }
    final duration = _durationLabel(item.runTimeTicks);
    if (duration.isNotEmpty) parts.add(duration);
    final last = item.datePlayed ?? item.dateModified;
    if (last != null) {
      final y = last.year.toString().padLeft(4, '0');
      final m = last.month.toString().padLeft(2, '0');
      final d = last.day.toString().padLeft(2, '0');
      parts.add('$y-$m-$d');
    }
    return parts.join('  \u00b7  ');
  }

  String _homeHeroImageUrl(_UiItem it) {
    final c = _clients[it.account.id];
    if (c == null) return it.coverUrl.trim();
    final id = it.item.id.trim();
    if (id.isEmpty) return it.coverUrl.trim();

    if (it.item.backdropTags.isNotEmpty) {
      final tag = it.item.backdropTags.first;
      if (tag.trim().isNotEmpty) {
        return c.coverUrl(
          id,
          type: 'Backdrop',
          index: 0,
          maxWidth: 1400,
          quality: 88,
          tag: tag,
        );
      }
    }

    final cover = it.coverUrl.trim();
    if (cover.isNotEmpty) return cover;
    return c.bestCoverUrl(it.item, maxWidth: 760).trim();
  }

  Widget _homeSectionBlock({
    required String title,
    required Widget child,
    VoidCallback? onMore,
    String moreLabel = '\u66f4\u591a',
  }) {
    final p = _palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (onMore != null)
                TextButton(
                  onPressed: onMore,
                  child: Text(moreLabel, style: TextStyle(color: p.sub)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Future<void> _openItemDetails(_UiItem it) async {
    if (_isSeriesDir(it)) {
      await _openSeriesUi(it);
      return;
    }
    if (_isMovieItem(it)) {
      await _openMovieUi(it);
      return;
    }
    await _openItem(it);
  }

  Widget _homeHero(_UiItem it, {required List<_UiItem> pool}) {
    final p = _palette;
    final img = _homeHeroImageUrl(it).trim();
    final token = it.account.apiKey.trim();
    final headers =
        token.isEmpty ? null : <String, String>{'X-Emby-Token': token};
    final typeLabel = _homeTypeLabel(it);
    final meta = _homeMetaLine(it);

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 236,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (img.isNotEmpty)
              Image.network(
                img,
                headers: headers,
                fit: BoxFit.cover,
                cacheWidth: 1400,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
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
                    Colors.black.withValues(alpha: 0.12),
                    Colors.black.withValues(alpha: 0.78),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.40),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '\u7ee7\u7eed\u89c2\u770b  \u00b7  $typeLabel',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    it.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.08,
                      shadows: [Shadow(blurRadius: 18, color: Colors.black54)],
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _openItem(it, pool: pool),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(
                            _isResumableItem(it.item) ? '继续播放' : '播放',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                p.chipSelectedBg.withValues(alpha: 0.92),
                            foregroundColor: p.text,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            textStyle: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 96,
                        child: FilledButton.icon(
                          onPressed: () => _openItemDetails(it),
                          icon:
                              const Icon(Icons.info_outline_rounded, size: 20),
                          label: const Text('\u8be6\u60c5'),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.32),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            textStyle: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned.fill(
              bottom: 78,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _openItemDetails(it),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _homeFeatureImageUrl(_UiItem it) {
    final client = _clients[it.account.id];
    if (client == null) return it.coverUrl.trim();
    final id = it.item.id.trim();
    if (id.isEmpty) return it.coverUrl.trim();
    final thumbTag = (it.item.thumbTag ?? '').trim();
    if (thumbTag.isNotEmpty) {
      return client.coverUrl(
        id,
        type: 'Thumb',
        maxWidth: 720,
        quality: 85,
        tag: thumbTag,
      );
    }
    if (it.item.backdropTags.isNotEmpty) {
      return client.coverUrl(
        id,
        type: 'Backdrop',
        index: 0,
        maxWidth: 960,
        quality: 85,
        tag: it.item.backdropTags.first,
      );
    }
    return _homeHeroImageUrl(it);
  }

  String _homeFeaturePrimaryTitle(_UiItem it) {
    final seriesName = (it.item.seriesName ?? '').trim();
    if (seriesName.isNotEmpty && _isEpisodeItem(it.item)) return seriesName;
    return it.title;
  }

  String _episodeCode(EmbyItem item) {
    final season = item.parentIndexNumber;
    final episode = item.indexNumber;
    if ((season ?? 0) > 0 && (episode ?? 0) > 0) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    }
    if ((episode ?? 0) > 0) return '第 $episode 集';
    return '';
  }

  String _homeFeatureSecondaryTitle(_UiItem it) {
    if (_isEpisodeItem(it.item)) {
      final code = _episodeCode(it.item);
      final episodeTitle = it.title.trim();
      if (episodeTitle.isNotEmpty && code.isNotEmpty) {
        return '$code · $episodeTitle';
      }
      if (episodeTitle.isNotEmpty) return episodeTitle;
      if (code.isNotEmpty) {
        return code;
      }
    }
    return _homeMetaLine(it);
  }

  Widget _homeFeatureRail(List<_UiItem> items, {String? badge}) {
    if (items.isEmpty) {
      return SizedBox(
        height: 132,
        child: Center(
          child: Text('暂无内容', style: TextStyle(color: _palette.sub)),
        ),
      );
    }
    return SizedBox(
      height: 178,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final item = items[i];
          final img = _homeFeatureImageUrl(item).trim();
          final token = item.account.apiKey.trim();
          final headers =
              token.isEmpty ? null : <String, String>{'X-Emby-Token': token};
          final primary = _homeFeaturePrimaryTitle(item);
          final secondary = _homeFeatureSecondaryTitle(item);
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openItem(item, pool: items),
            child: SizedBox(
              width: 228,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (img.isNotEmpty)
                            Image.network(
                              img,
                              headers: headers,
                              fit: BoxFit.cover,
                              cacheWidth: 720,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                color: _palette.coverPlaceholderBg,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: _palette.sub),
                                ),
                              ),
                            )
                          else
                            ColoredBox(
                              color: _palette.coverPlaceholderBg,
                              child: Center(
                                child: Icon(Icons.movie_outlined,
                                    color: _palette.sub),
                              ),
                            ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.08),
                                  Colors.black.withValues(alpha: 0.54),
                                ],
                              ),
                            ),
                          ),
                          if ((badge ?? '').trim().isNotEmpty)
                            Positioned(
                              left: 10,
                              top: 10,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  badge!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          _itemBadgeOverlay(item),
                          _progressOverlay(item.item),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    primary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _palette.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    secondary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _palette.sub,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
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
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          cacheExtent: 1000,
          addAutomaticKeepAlives: false,
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
      final scopedNextUp = _scopeItems(_nextUp);
      final scopedFavorites = _scopeItems(_favorites);
      final scopedSections = _scopeSections(_sections);

      final groupedFav = <String, List<_UiItem>>{};
      for (final f in scopedFavorites) {
        groupedFav.putIfAbsent(f.account.id, () => <_UiItem>[]).add(f);
      }

      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          cacheExtent: 1200,
          physics: _kEmbyScrollPhysics,
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
              if (scopedResume.isNotEmpty) ...[
                _homeHero(scopedResume.first, pool: scopedResume),
                const SizedBox(height: 12),
              ],
              if (scopedNextUp.isNotEmpty) ...[
                _homeSectionBlock(
                  title: '下一步观看',
                  child: _homeFeatureRail(scopedNextUp, badge: 'Next Up'),
                ),
                const SizedBox(height: 12),
              ],
              _homeSectionBlock(
                title: '\u7ee7\u7eed\u89c2\u770b',
                child: scopedResume.length > 1
                    ? _homeFeatureRail(
                        scopedResume.skip(1).take(20).toList(growable: false),
                        badge: 'Resume',
                      )
                    : SizedBox(
                        height: 120,
                        child: Center(
                          child: Text(
                            scopedResume.isEmpty
                                ? '\u6682\u65e0\u7ee7\u7eed\u89c2\u770b'
                                : '\u6682\u65e0\u66f4\u591a\u7ee7\u7eed\u5185\u5bb9',
                            style: TextStyle(color: _palette.sub),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
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
                _homeSectionBlock(
                  title: row.view.name.trim().isEmpty
                      ? '\u5a92\u4f53'
                      : row.view.name.trim(),
                  onMore: () => _openFolderUi(
                    account: row.account,
                    folderId: row.view.id,
                    title: row.view.name.trim().isEmpty
                        ? '\u5a92\u4f53'
                        : row.view.name.trim(),
                  ),
                  child: _shelf(row.items),
                ),
                const SizedBox(height: 12),
              ],
              _homeSectionBlock(
                title: '媒体库',
                child: _shelf(scopedLibraries),
              ),
              const SizedBox(height: 12),
              if (_sectionsLoading && scopedSections.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Center(
                    child: Text(
                      '\u5206\u533a\u7ee7\u7eed\u52a0\u8f7d\u4e2d\u2026',
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
                _homeSectionBlock(
                  title: _accountName(e.key),
                  onMore: () {
                    final acc = _accountById(e.key);
                    if (acc != null) _openFavoritesUi(account: acc);
                  },
                  child: _shelf(e.value.take(20).toList(growable: false)),
                ),
                const SizedBox(height: 12),
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
  final _FolderPageSeed? initialSeed;
  final _EmbyPaletteMode paletteMode;

  const _EmbyExclusiveFolderPage({
    required this.account,
    required this.title,
    required this.folderId,
    this.favoritesMode = false,
    this.initialSeed,
    required this.paletteMode,
  });

  @override
  State<_EmbyExclusiveFolderPage> createState() =>
      _EmbyExclusiveFolderPageState();
}

enum _FolderTopTab { videos, images, folders }

enum _FolderSortKind { updatedAt, addedAt, title, playDuration, playedAt }

enum _AspectBucket { poster, square, landscape }

enum _LibraryKind { unknown, movies, series, mixed }

class _EmbyExclusiveFolderPageState extends State<_EmbyExclusiveFolderPage> {
  late final EmbyClient _client = EmbyClient(widget.account);
  late final EmbyReadCoordinator _reader = EmbyReadCoordinator(
    client: _client,
    accountId: widget.account.id,
  );
  static const int _kMaxPerDirectoryDisplaySettingsEntries = 500;

  bool _loading = true;
  Object? _loadError;
  List<_UiItem> _items = const <_UiItem>[];
  List<_UiItem> _recursiveVideos = const <_UiItem>[];
  List<_UiItem> _recursiveImages = const <_UiItem>[];
  _LibraryKind _libraryKind = _LibraryKind.unknown;
  _FolderTopTab _topTab = _FolderTopTab.videos;
  String _displayItemsCacheToken = '';
  List<_UiItem> _displayItemsCache = const <_UiItem>[];
  int _dominantAspectCacheKey = 0;
  double _dominantAspectCacheValue = 0.67;
  bool _topTabTouchedSinceReload = false;
  bool _applyEntryTopTabPriority = true;
  _FolderSortKind _sort = _FolderSortKind.title;
  bool _sortAsc = true;
  int _coverHydrationToken = 0;
  bool _perDirectoryDisplaySettingsEnabled = false;
  int _moviePrewarmRunToken = 0;
  Timer? _coverBatchTimer;
  final Map<String, String> _pendingMovieCoverBatch = <String, String>{};
  final Map<String, String> _pendingFolderCoverBatch = <String, String>{};
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
    _applyInitialSeed();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _coverBatchTimer?.cancel();
    super.dispose();
  }

  _EmbyPalette get _palette => _paletteForMode(widget.paletteMode);

  bool _isResumableItem(EmbyItem item) {
    final played = item.playedPercentage ?? 0;
    if (item.playbackPositionTicks > 0 && played < 95) return true;
    return item.playbackPositionTicks > 0 && !item.isPlayed;
  }

  double _progressRatio(EmbyItem item) {
    final played = item.playedPercentage;
    if (played != null && played.isFinite && played > 0) {
      return (played / 100).clamp(0.0, 1.0);
    }
    final ticks = item.playbackPositionTicks;
    final runtime = item.runTimeTicks ?? 0;
    if (ticks > 0 && runtime > 0) {
      return (ticks / runtime).clamp(0.0, 1.0);
    }
    return 0;
  }

  Widget _progressOverlay(EmbyItem item) {
    final ratio = _progressRatio(item);
    if (ratio <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 4,
        color: Colors.black.withValues(alpha: 0.34),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio,
          child: Container(color: _palette.progress),
        ),
      ),
    );
  }

  Widget _itemBadgeOverlay(_UiItem item) {
    final unplayed = item.item.unplayedItemCount;
    final resumable = _isResumableItem(item.item);
    final label = unplayed > 0
        ? '未看 $unplayed'
        : resumable
            ? '继续播放'
            : '';
    if (label.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 8,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  void _applyInitialSeed() {
    final seed = widget.initialSeed;
    if (seed == null || !seed.hasAnyData) return;
    _items = seed.directItems;
    _recursiveVideos = seed.recursiveVideos;
    _recursiveImages = seed.recursiveImages;
    _libraryKind = _libraryKindFromSignal(seed.kindHint);
    _topTab = _chooseTopTab(
      current: _topTab,
      directItems: _items,
      videos: _recursiveVideos,
      images: _recursiveImages,
      preferPriority: true,
    );
    _loading = false;
  }

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
    setState(() {
      _topTab = tab;
      _topTabTouchedSinceReload = true;
      _applyEntryTopTabPriority = false;
    });
    if (tab == _FolderTopTab.folders) {
      _maybePrewarmVisibleCovers(token: _coverHydrationToken);
    }
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

  Future<String?> _resolveFolderCoverById(
    String folderId, {
    int maxWidth = 560,
  }) async {
    final id = folderId.trim();
    if (id.isEmpty) return null;

    final cached = (_folderCoverUrlCache[id] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    final inflight = _folderCoverInflight[id];
    if (inflight != null) return await inflight;

    final fut = (() async {
      try {
        final auto = await _client.pickAutoFolderCoverUrl(
          folderId: id,
          maxWidth: maxWidth,
          quality: 85,
          fallbackToVideo: true,
        );
        final url = (auto ?? '').trim();
        if (url.isNotEmpty) {
          _folderCoverUrlCache[id] = url;
          return url;
        }
      } catch (_) {}
      return null;
    })();

    _folderCoverInflight[id] = fut;
    try {
      return await fut;
    } finally {
      _folderCoverInflight.remove(id);
    }
  }

  // ignore: unused_element
  Future<String?> _resolveFolderCoverFallback(
    _UiItem item, {
    int maxWidth = 560,
  }) async {
    if (!item.isDir) return null;
    return _resolveFolderCoverById(item.item.id, maxWidth: maxWidth);
  }

  String _topTabLabel(_FolderTopTab tab) {
    switch (tab) {
      case _FolderTopTab.videos:
        if (_libraryKind == _LibraryKind.series) return '单集';
        if (_libraryKind == _LibraryKind.movies) return '视频文件';
        return '视频';
      case _FolderTopTab.images:
        return '图片';
      case _FolderTopTab.folders:
        if (_libraryKind == _LibraryKind.series) return '剧集';
        if (_libraryKind == _LibraryKind.movies) return '内容';
        return '分类';
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
    return embyNativeFolderIsSeriesCollection(item.item);
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
    return embyNativeTypeIsSeries(item.item.type);
  }

  bool _isMovieItem(_UiItem item) {
    if (item.isDir || item.isImage) return false;
    final preferMovie = _libraryKind == _LibraryKind.movies;
    final preferSeries = _libraryKind == _LibraryKind.series;
    return _isLikelyMovieVideo(
      item.item,
      preferMovieVideos: preferMovie,
      preferSeriesVideos: preferSeries,
    );
  }

  bool get _prefersStructuredContentTab =>
      _libraryKind == _LibraryKind.series ||
      _libraryKind == _LibraryKind.movies;

  _UiItem _seriesProxyFromVideo(_UiItem item) {
    final seriesId = (item.item.seriesId ?? '').trim();
    final seriesName = (item.item.seriesName ?? '').trim();
    return _UiItem(
      account: widget.account,
      item: EmbyItem(
        id: seriesId,
        name: seriesName.isEmpty ? item.title : seriesName,
        type: 'Series',
        isFolder: true,
        collectionType: 'tvshows',
        dateCreated: item.item.dateCreated,
        dateModified: item.item.dateModified,
        datePlayed: item.item.datePlayed,
      ),
      isDir: true,
      isImage: false,
      coverUrl: item.coverUrl,
    );
  }

  List<_UiItem> _collapsedSeriesVideoItems(List<_UiItem> src) {
    if (src.isEmpty) return src;
    final directSeries = <String, _UiItem>{
      for (final item in _items)
        if (_isSeriesDir(item) && item.item.id.trim().isNotEmpty)
          item.item.id.trim(): item,
    };
    final out = <_UiItem>[];
    final seen = <String>{};
    for (final item in src) {
      final seriesId = (item.item.seriesId ?? '').trim();
      if (seriesId.isEmpty) {
        final id = item.item.id.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        out.add(item);
        continue;
      }
      if (!seen.add(seriesId)) continue;
      out.add(directSeries[seriesId] ?? _seriesProxyFromVideo(item));
    }
    return out;
  }

  List<_UiItem> _contentItemsForCurrentFolder() {
    if (_libraryKind == _LibraryKind.series) {
      final directSeries = _items.where(_isSeriesDir).toList(growable: false);
      if (directSeries.isNotEmpty) return directSeries;
      final directPlayable =
          _items.where((x) => !x.isDir && !x.isImage).toList(growable: false);
      return _collapsedSeriesVideoItems(
        _mergeUiById(directPlayable, _recursiveVideos),
      );
    }

    if (_libraryKind == _LibraryKind.movies) {
      final directMovieFolders =
          _items.where(_isMovieFolder).toList(growable: false);
      final directMovieFiles =
          _items.where(_isMovieItem).toList(growable: false);
      if (directMovieFolders.isNotEmpty) {
        return _mergeUiById(directMovieFolders, directMovieFiles);
      }
      final recursiveMovieFiles =
          _recursiveVideos.where(_isMovieItem).toList(growable: false);
      return _mergeUiById(directMovieFiles, recursiveMovieFiles);
    }

    return _items;
  }

  List<_UiItem> _baseItemsForTab() {
    switch (_topTab) {
      case _FolderTopTab.videos:
        if (_libraryKind == _LibraryKind.series) {
          return _collapsedSeriesVideoItems(_recursiveVideos);
        }
        return _recursiveVideos;
      case _FolderTopTab.images:
        return _recursiveImages;
      case _FolderTopTab.folders:
        return _contentItemsForCurrentFolder();
    }
  }

  _LibraryKind _libraryKindFromSignal(EmbyLibraryKindSignal kind) {
    switch (kind) {
      case EmbyLibraryKindSignal.movies:
        return _LibraryKind.movies;
      case EmbyLibraryKindSignal.series:
        return _LibraryKind.series;
      case EmbyLibraryKindSignal.mixed:
        return _LibraryKind.mixed;
      case EmbyLibraryKindSignal.homeVideos:
      case EmbyLibraryKindSignal.unknown:
        return _LibraryKind.unknown;
    }
  }

  String _libraryKindLabel() {
    switch (_libraryKind) {
      case _LibraryKind.movies:
        return '\u7535\u5f71\u5e93';
      case _LibraryKind.series:
        return '\u5267\u96c6\u5e93';
      case _LibraryKind.mixed:
        return '\u5f71\u89c6\u6df7\u5408';
      case _LibraryKind.unknown:
        return '';
    }
  }

  String _effectiveCoverUrl(_UiItem item) {
    final id = item.item.id.trim();
    if (id.isNotEmpty && item.isDir) {
      if (_isMovieFolder(item)) {
        final movie = (_movieFolderCoverUrlCache[id] ?? '').trim();
        if (movie.isNotEmpty) return movie;
      }
      final folder = (_folderCoverUrlCache[id] ?? '').trim();
      if (folder.isNotEmpty) return folder;
    }
    return item.coverUrl.trim();
  }

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
        return (a.item.runTimeTicks ?? 0).compareTo(b.item.runTimeTicks ?? 0);
      case _FolderSortKind.playedAt:
        return (a.item.datePlayed?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.datePlayed?.millisecondsSinceEpoch ?? 0);
      case _FolderSortKind.title:
        return _naturalTitleCompare(_displayTitle(a), _displayTitle(b));
    }
  }

  int _categorySortRank(_UiItem item) {
    if (item.isDir) return 0;
    if (item.isImage) return 1;
    return 2;
  }

  String _displayItemsToken() {
    return [
      _topTab.index,
      _sort.index,
      _sortAsc ? 1 : 0,
      _libraryKind.index,
      identityHashCode(_items),
      identityHashCode(_recursiveVideos),
      identityHashCode(_recursiveImages),
    ].join('|');
  }

  List<_UiItem> _displayItems() {
    final token = _displayItemsToken();
    if (token == _displayItemsCacheToken) return _displayItemsCache;

    final out = _baseItemsForTab().toList(growable: true);
    out.sort((a, b) {
      if (_topTab == _FolderTopTab.folders) {
        final kindCmp = _categorySortRank(a).compareTo(_categorySortRank(b));
        if (kindCmp != 0) return kindCmp;
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      }
      var cmp = _sortFieldCompare(a, b);
      if (cmp == 0) {
        cmp = _naturalTitleCompare(_displayTitle(a), _displayTitle(b));
      }
      if (!_sortAsc) cmp = -cmp;
      return cmp;
    });
    _displayItemsCacheToken = token;
    _displayItemsCache = out;
    return out;
  }

  double _dominantCoverAspectCached(List<_UiItem> items) {
    if (items.isEmpty) return 0.67;
    final key = identityHashCode(items);
    if (_dominantAspectCacheKey == key) return _dominantAspectCacheValue;
    final value = _dominantCoverAspect(items);
    _dominantAspectCacheKey = key;
    _dominantAspectCacheValue = value;
    return value;
  }

  List<_UiItem> _playableItems(List<_UiItem> src) {
    return src
        .where((x) => _isVideoItem(x) && x.item.id.trim().isNotEmpty)
        .toList(growable: false);
  }

  bool _isVideoItem(_UiItem item) {
    return embyNativeItemIsVideo(item.item);
  }

  bool _hasFolderTabItems(List<_UiItem> source) {
    if (_prefersStructuredContentTab) {
      return _contentItemsForCurrentFolder().isNotEmpty;
    }
    return source.isNotEmpty;
  }

  List<_FolderTopTab> _visibleTopTabs() {
    final tabs = <_FolderTopTab>[];
    if (_prefersStructuredContentTab) {
      if (_contentItemsForCurrentFolder().isNotEmpty) {
        tabs.add(_FolderTopTab.folders);
      } else if (_recursiveVideos.isNotEmpty) {
        tabs.add(_FolderTopTab.videos);
      }
    } else {
      tabs.add(_FolderTopTab.videos);
      tabs.add(_FolderTopTab.folders);
    }
    if (_hasImages) tabs.add(_FolderTopTab.images);
    if (tabs.isEmpty) tabs.add(_FolderTopTab.videos);
    return tabs;
  }

  _FolderTopTab _preferredTopTab({
    required bool hasVideos,
    required bool hasImages,
    required bool hasFolders,
  }) {
    if (_prefersStructuredContentTab && hasFolders) {
      return _FolderTopTab.folders;
    }
    if (hasVideos) return _FolderTopTab.videos;
    if (hasFolders) return _FolderTopTab.folders;
    if (hasImages) return _FolderTopTab.images;
    return _FolderTopTab.videos;
  }

  void _onFolderTopTabSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 260) return;

    final tabs = _visibleTopTabs();
    final idx = tabs.indexOf(_topTab);
    if (idx < 0) return;

    if (velocity < 0 && idx < tabs.length - 1) {
      _setTopTab(tabs[idx + 1]);
      return;
    }
    if (velocity > 0 && idx > 0) {
      _setTopTab(tabs[idx - 1]);
    }
  }

  _FolderTopTab _chooseTopTab({
    required _FolderTopTab current,
    required List<_UiItem> directItems,
    required List<_UiItem> videos,
    required List<_UiItem> images,
    bool preferPriority = false,
  }) {
    final hasVideos = videos.isNotEmpty;
    final hasImages = images.isNotEmpty;
    final hasFolders = _hasFolderTabItems(directItems);
    if (preferPriority) {
      return _preferredTopTab(
        hasVideos: hasVideos,
        hasImages: hasImages,
        hasFolders: hasFolders,
      );
    }

    if (_prefersStructuredContentTab && hasFolders) {
      if (current == _FolderTopTab.folders) {
        return _FolderTopTab.folders;
      }
      if (current == _FolderTopTab.images && hasImages) {
        return _FolderTopTab.images;
      }
      return _FolderTopTab.folders;
    }

    if (current == _FolderTopTab.videos && hasVideos) {
      return _FolderTopTab.videos;
    }
    if (current == _FolderTopTab.folders && hasFolders) {
      return _FolderTopTab.folders;
    }
    if (current == _FolderTopTab.images && hasImages) {
      return _FolderTopTab.images;
    }

    return _preferredTopTab(
      hasVideos: hasVideos,
      hasImages: hasImages,
      hasFolders: hasFolders,
    );
  }

  void _applyCoverBatch(
    Map<String, String> coverById, {
    bool movie = false,
    bool folder = false,
  }) {
    if (coverById.isEmpty) return;
    if (movie) _pendingMovieCoverBatch.addAll(coverById);
    if (folder) _pendingFolderCoverBatch.addAll(coverById);
    _scheduleCoverBatchFlush();
  }

  void _scheduleCoverBatchFlush() {
    if (_coverBatchTimer?.isActive == true) return;
    _coverBatchTimer = Timer(
      const Duration(milliseconds: 140),
      _flushCoverBatch,
    );
  }

  void _flushCoverBatch() {
    if (!mounted) return;
    if (_pendingMovieCoverBatch.isEmpty && _pendingFolderCoverBatch.isEmpty) {
      return;
    }
    final movieBatch = Map<String, String>.from(_pendingMovieCoverBatch);
    final folderBatch = Map<String, String>.from(_pendingFolderCoverBatch);
    _pendingMovieCoverBatch.clear();
    _pendingFolderCoverBatch.clear();
    if (_topTab != _FolderTopTab.folders) {
      if (movieBatch.isNotEmpty) {
        _movieFolderCoverUrlCache.addAll(movieBatch);
      }
      if (folderBatch.isNotEmpty) {
        _folderCoverUrlCache.addAll(folderBatch);
      }
      return;
    }
    setState(() {
      if (movieBatch.isNotEmpty) {
        _movieFolderCoverUrlCache.addAll(movieBatch);
      }
      if (folderBatch.isNotEmpty) {
        _folderCoverUrlCache.addAll(folderBatch);
      }
    });
  }

  List<String> _collectRegularFolderIds(
    Iterable<_UiItem> source,
    Set<String> seen,
  ) {
    final out = <String>[];
    for (final item in source) {
      if (!item.isDir) continue;
      if (_isSeriesFolder(item) || _isMovieFolder(item)) continue;
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      if ((_folderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;
      out.add(id);
    }
    return out;
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

  List<_UiItem> _mergeUiById(List<_UiItem> base, List<_UiItem> extra) {
    if (base.isEmpty) return extra;
    if (extra.isEmpty) return base;
    final seen = <String>{};
    final out = <_UiItem>[];
    for (final item in base) {
      final id = item.item.id.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(item);
    }
    for (final item in extra) {
      final id = item.item.id.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(item);
    }
    return out;
  }

  Map<String, _UiItem> _indexUiById(List<_UiItem> src) {
    final out = <String, _UiItem>{};
    for (final item in src) {
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      out[id] = item;
    }
    return out;
  }

  List<_UiItem> _toUiItemsWithSeed(
    Iterable<EmbyItem> items, {
    required int maxWidth,
    Map<String, _UiItem>? seed,
  }) {
    final out = <_UiItem>[];
    for (final item in items) {
      final id = item.id.trim();
      final cached = (id.isNotEmpty && seed != null) ? seed[id] : null;
      if (cached != null) {
        out.add(cached);
        continue;
      }
      out.add(_toUiItem(item, maxWidth: maxWidth));
    }
    return out;
  }

  void _maybePrewarmVisibleCovers({required int token}) {
    if (_topTab != _FolderTopTab.folders) return;
    unawaited(_prewarmVisibleMovieCovers(token: token));
    unawaited(_prewarmVisibleFolderCovers(token: token));
  }

  Future<void> _applyFastRecursivePreview({
    required int token,
    required List<_UiItem> directItems,
    required EmbyLibraryKindSignal kindHint,
  }) async {
    if (widget.favoritesMode) return;
    if (_recursiveVideos.isNotEmpty || _recursiveImages.isNotEmpty) return;
    final folderId = widget.folderId.trim();
    if (folderId.isEmpty) return;
    try {
      final quick = await _reader.probeFolderRecursiveMedia(
        folderId: folderId,
        kindHint: kindHint,
      );
      if (!mounted || token != _coverHydrationToken) return;
      final existingVideoIds = _recursiveVideos
          .map((x) => x.item.id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final existingImageIds = _recursiveImages
          .map((x) => x.item.id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final quickVideos = _toUiItemsWithSeed(
        quick.videos.where((e) => !existingVideoIds.contains(e.id.trim())),
        maxWidth: 520,
      );
      final quickImages = _toUiItemsWithSeed(
        quick.images.where((e) => !existingImageIds.contains(e.id.trim())),
        maxWidth: 520,
      );
      if (quickVideos.isEmpty && quickImages.isEmpty) return;

      final mergedVideos = _mergeUiById(_recursiveVideos, quickVideos);
      final mergedImages = _mergeUiById(_recursiveImages, quickImages);
      final previousTab = _topTab;
      final tab = _chooseTopTab(
        current: _topTab,
        directItems: directItems,
        videos: mergedVideos,
        images: mergedImages,
        preferPriority: _applyEntryTopTabPriority && !_topTabTouchedSinceReload,
      );
      setState(() {
        _recursiveVideos = mergedVideos;
        _recursiveImages = mergedImages;
        _topTab = tab;
      });
      if (previousTab != tab) {
        unawaited(_persistDisplaySettingsForCurrentFolder());
      }
      _maybePrewarmVisibleCovers(token: token);
    } catch (_) {}
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

    Future<void> flushPending(Map<String, String> pending) async {
      if (pending.isEmpty) return;
      if (!mounted ||
          token != _coverHydrationToken ||
          runId != _moviePrewarmRunToken) {
        return;
      }
      final batch = Map<String, String>.from(pending);
      pending.clear();
      _applyCoverBatch(batch, movie: true);
    }

    Future<void> worker() async {
      final pending = <String, String>{};
      while (true) {
        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          await flushPending(pending);
          return;
        }
        if (cursor >= targetIds.length) break;
        final id = targetIds[cursor++];
        if ((_movieFolderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;

        final primary = await _resolveMovieFolderPrimary(id);
        if (primary == null) continue;
        final url = _coverUrlFor(_client, primary.item, maxWidth: 520).trim();
        if (url.isEmpty) continue;

        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          await flushPending(pending);
          return;
        }
        pending[id] = url;
        if (pending.length >= 3) {
          await flushPending(pending);
        }

        if (gentle) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await flushPending(pending);
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _prewarmRegularFolderCoverIds(
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

    Future<void> flushPending(Map<String, String> pending) async {
      if (pending.isEmpty) return;
      if (!mounted ||
          token != _coverHydrationToken ||
          runId != _moviePrewarmRunToken) {
        return;
      }
      final batch = Map<String, String>.from(pending);
      pending.clear();
      _applyCoverBatch(batch, folder: true);
    }

    Future<void> worker() async {
      final pending = <String, String>{};
      while (true) {
        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          await flushPending(pending);
          return;
        }
        if (cursor >= targetIds.length) break;
        final id = targetIds[cursor++];
        if ((_folderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;

        final url =
            (await _resolveFolderCoverById(id, maxWidth: 560) ?? '').trim();
        if (url.isEmpty) continue;

        if (!mounted ||
            token != _coverHydrationToken ||
            runId != _moviePrewarmRunToken) {
          await flushPending(pending);
          return;
        }
        pending[id] = url;
        if (pending.length >= 3) {
          await flushPending(pending);
        }

        if (gentle) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await flushPending(pending);
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

        return _naturalTitleCompare(a.title, b.title);
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
            !embyNativeItemIsFolder(self) &&
            !embyNativeItemIsImage(self)) {
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

  Future<void> _prewarmVisibleFolderCovers({required int token}) async {
    if (!mounted || token != _coverHydrationToken) return;
    final runId = _moviePrewarmRunToken;
    final ordered = _displayItems();
    final seen = <String>{};
    final visiblePool = _collectRegularFolderIds(ordered.take(24), seen);
    final visibleFirst = visiblePool.take(12).toList(growable: false);
    final remaining = <String>[
      ...visiblePool.skip(12),
      ..._collectRegularFolderIds(ordered.skip(24), seen),
    ];

    await _prewarmRegularFolderCoverIds(
      visibleFirst,
      token: token,
      runId: runId,
      maxWorkers: 2,
      gentle: false,
    );
    if (!mounted || token != _coverHydrationToken) return;
    if (runId != _moviePrewarmRunToken) return;

    await _prewarmRegularFolderCoverIds(
      remaining,
      token: token,
      runId: runId,
      maxWorkers: 1,
      gentle: true,
    );
  }

  Future<void> _openMovieFolder(_UiItem item) async {
    await _openFolderPage(item);
  }

  Future<void> _openMovieDetail(_UiItem movie) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyMovieDetailPage(
          account: widget.account,
          movieId: movie.item.id.trim(),
          seedMovie: movie.item,
          paletteMode: widget.paletteMode,
        ),
      ),
    );
  }

  Future<void> _openFolderPage(_UiItem item) async {
    final folderId = item.item.id.trim();
    if (folderId.isEmpty) {
      if (!mounted) return;
      showAppToast(context,
          '\u8be5\u76ee\u5f55\u7f3a\u5c11 ID\uff0c\u65e0\u6cd5\u6253\u5f00',
          error: true);
      return;
    }
    _FolderPageSeed? seed;
    try {
      final plan =
          await _reader.readFolder(folderId: folderId, favoritesMode: false);
      final snap = plan.immediate;
      final mapped = _toUiItemsWithSeed(snap.directItems, maxWidth: 520);
      final immediateIndex = _indexUiById(mapped);
      seed = _FolderPageSeed(
        directItems: mapped,
        recursiveVideos: _toUiItemsWithSeed(
          snap.directMedia.videos,
          maxWidth: 520,
          seed: immediateIndex,
        ),
        recursiveImages: _toUiItemsWithSeed(
          snap.directMedia.images,
          maxWidth: 520,
          seed: immediateIndex,
        ),
        kindHint: snap.libraryKind,
      );
    } catch (_) {}
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EmbyExclusiveFolderPage(
          account: widget.account,
          title: _displayTitle(item),
          folderId: folderId,
          initialSeed: seed,
          paletteMode: widget.paletteMode,
        ),
      ),
    );
  }

  Future<void> _reload() async {
    await _loadDisplaySettingsForCurrentFolder();
    _moviePrewarmRunToken++;
    _movieFolderPrimaryMisses.clear();
    _topTabTouchedSinceReload = false;
    _applyEntryTopTabPriority = true;
    final token = ++_coverHydrationToken;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final plan = await _reader.readFolder(
        folderId: widget.folderId.trim(),
        favoritesMode: widget.favoritesMode,
      );
      final immediateSnap = plan.immediate;
      final mapped = _toUiItemsWithSeed(
        immediateSnap.directItems,
        maxWidth: 520,
      );
      final immediateIndex = _indexUiById(mapped);
      final immediateVideos = _toUiItemsWithSeed(
        immediateSnap.directMedia.videos,
        maxWidth: 520,
        seed: immediateIndex,
      );
      final immediateImages = _toUiItemsWithSeed(
        immediateSnap.directMedia.images,
        maxWidth: 520,
        seed: immediateIndex,
      );
      final libraryKind = _libraryKindFromSignal(immediateSnap.libraryKind);
      final previousTopTab = _topTab;
      final nextTopTab = _chooseTopTab(
        current: _topTab,
        directItems: mapped,
        videos: immediateVideos,
        images: immediateImages,
        preferPriority: _applyEntryTopTabPriority && !_topTabTouchedSinceReload,
      );
      if (!mounted) return;
      setState(() {
        _items = mapped;
        _recursiveVideos = immediateVideos;
        _recursiveImages = immediateImages;
        _libraryKind = libraryKind;
        _topTab = nextTopTab;
        _loading = false;
      });
      if (previousTopTab != nextTopTab) {
        unawaited(_persistDisplaySettingsForCurrentFolder());
      }
      _maybePrewarmVisibleCovers(token: token);
      unawaited(
        _applyFastRecursivePreview(
          token: token,
          directItems: mapped,
          kindHint: immediateSnap.libraryKind,
        ),
      );
      unawaited(() async {
        try {
          final recursive = await plan.recursiveMedia;
          if (!mounted || token != _coverHydrationToken) return;
          final recursiveVideos = _toUiItemsWithSeed(
            recursive.videos,
            maxWidth: 520,
            seed: immediateIndex,
          );
          final recursiveImages = _toUiItemsWithSeed(
            recursive.images,
            maxWidth: 520,
            seed: immediateIndex,
          );
          final previousTab = _topTab;
          final tab = _chooseTopTab(
            current: _topTab,
            directItems: mapped,
            videos: recursiveVideos,
            images: recursiveImages,
            preferPriority:
                _applyEntryTopTabPriority && !_topTabTouchedSinceReload,
          );
          setState(() {
            _recursiveVideos = recursiveVideos;
            _recursiveImages = recursiveImages;
            _topTab = tab;
            _applyEntryTopTabPriority = false;
          });
          if (previousTab != tab) {
            unawaited(_persistDisplaySettingsForCurrentFolder());
          }
          _maybePrewarmVisibleCovers(token: token);
        } catch (_) {
          _applyEntryTopTabPriority = false;
        }
      }());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _libraryKind = _LibraryKind.unknown;
        _loading = false;
        _applyEntryTopTabPriority = false;
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

    final seriesId = (item.item.seriesId ?? '').trim();
    if (_libraryKind == _LibraryKind.series &&
        !item.isDir &&
        !item.isImage &&
        seriesId.isNotEmpty &&
        seriesId != item.item.id.trim()) {
      final seriesName = (item.item.seriesName ?? '').trim();
      final seedSeries = EmbyItem(
        id: seriesId,
        name: seriesName.isEmpty ? item.title : seriesName,
        type: 'Series',
        isFolder: true,
        collectionType: 'tvshows',
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _EmbySeriesDetailPage(
            account: widget.account,
            seriesId: seriesId,
            seedSeries: seedSeries,
            paletteMode: widget.paletteMode,
          ),
        ),
      );
      return;
    }

    if (_isMovieItem(item)) {
      await _openMovieDetail(item);
      return;
    }

    if (_isMovieFolder(item)) {
      await _openMovieFolder(item);
      return;
    }

    if (item.isDir) {
      await _openFolderPage(item);
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.chipSelectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          style: TextStyle(
            color: p.text.withValues(alpha: selected ? 1 : 0.88),
            fontSize: selected ? 14.2 : 14,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
          ),
          child: Text(_topTabLabel(tab)),
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
    final tabs = _visibleTopTabs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: p.chipBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: _onFolderTopTabSwipe,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tab in tabs) _topTabButton(tab),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _sortMenuButton(),
            const SizedBox(width: 8),
            if (_libraryKind != _LibraryKind.unknown) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.chipBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _libraryKindLabel(),
                  style: TextStyle(
                    color: p.sub,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
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
    final url = _effectiveCoverUrl(item);
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

    Widget buildDirSeed(String seedUrl) {
      return Image.network(
        seedUrl,
        headers: headers,
        fit: BoxFit.cover,
        cacheWidth: coverWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => emptyPlaceholder(),
      );
    }

    if (item.isDir) {
      if (url.isEmpty) return emptyPlaceholder();
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
    if (_isMovieItem(item)) return '\u7535\u5f71';
    if (_libraryKind == _LibraryKind.series &&
        _embyTypeIsEpisode(item.item.type)) {
      return '\u5267\u96c6';
    }
    return '\u89c6\u9891';
  }

  String _displayTitle(_UiItem item) {
    final raw = item.title.trim();
    if (!_isMovieFolder(item) && !_isMovieItem(item)) return raw;
    final stripped = raw.replaceAll(_kMovieMetaTagBracketPattern, '');
    final compact = stripped.replaceAll(_kMultiSpacePattern, ' ').trim();
    return compact.isEmpty ? raw : compact;
  }

  Widget _buildTopTabGridTile(
    _UiItem item,
    List<_UiItem> shown, {
    required double coverAspect,
  }) {
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _cover(item),
                    _itemBadgeOverlay(item),
                    _progressOverlay(item.item),
                  ],
                ),
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
  }

  Widget _buildTopTabSliverContent(List<_UiItem> shown) {
    if (shown.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            '\u76ee\u5f55\u4e3a\u7a7a',
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final coverAspect = _dominantCoverAspectCached(shown);
          final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
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
          return SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildTopTabGridTile(
                shown[i],
                shown,
                coverAspect: coverAspect,
              ),
              childCount: shown.length,
              addAutomaticKeepAlives: false,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 12,
              childAspectRatio: childAspect,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = () {
      final hasAnyData = _items.isNotEmpty ||
          _recursiveVideos.isNotEmpty ||
          _recursiveImages.isNotEmpty;
      if (_loading && !hasAnyData) {
        return Center(
            child: CircularProgressIndicator(color: _palette.progress));
      }
      if (_loadError != null && !hasAnyData) {
        return Center(
            child: Text(friendlyErrorMessage(_loadError!),
                style: TextStyle(color: _palette.sub)));
      }

      final shown = _displayItems();
      return RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          cacheExtent: 1200,
          physics: _kEmbyScrollPhysics,
          slivers: [
            if (_loading)
              SliverToBoxAdapter(
                child: LinearProgressIndicator(
                  minHeight: 1.5,
                  color: _palette.progress,
                  backgroundColor: Colors.transparent,
                ),
              ),
            if (_loadError != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(
                    friendlyErrorMessage(_loadError!),
                    style: TextStyle(color: _palette.sub, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              sliver: SliverToBoxAdapter(
                child: _headerControls(shown.length),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            _buildTopTabSliverContent(shown),
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

Widget _detailFactChip(
  _EmbyPalette palette, {
  required IconData icon,
  required String label,
  bool highlight = false,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: highlight
          ? palette.chipSelectedBg.withValues(alpha: 0.94)
          : palette.chipBg.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: highlight ? palette.text : palette.sub),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: palette.text,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

Widget _detailSectionCard(
  _EmbyPalette palette, {
  required String title,
  String? subtitle,
  Widget? trailing,
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(14, 14, 14, 14),
}) {
  return Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: palette.panel,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if ((subtitle ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!.trim(),
                      style: TextStyle(
                        color: palette.sub,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing,
            ],
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

Widget _detailGenreWrap(_EmbyPalette palette, List<String> genres) {
  final visible = genres
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .take(6)
      .toList(growable: false);
  if (visible.isEmpty) return const SizedBox.shrink();
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final genre in visible)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: palette.chipBg.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            genre,
            style: TextStyle(
              color: palette.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
    ],
  );
}

Widget _detailPrimaryButton(
  _EmbyPalette palette, {
  required VoidCallback onPressed,
  required IconData icon,
  required String label,
  bool primary = false,
}) {
  final fg = primary ? palette.text : Colors.white;
  final bg = primary
      ? palette.chipSelectedBg.withValues(alpha: 0.95)
      : palette.chipBg.withValues(alpha: 0.94);
  return FilledButton.icon(
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      padding: const EdgeInsets.symmetric(vertical: 12),
      textStyle: const TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w700,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
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

  bool _isResumableEpisode(EmbyItem item) {
    final played = item.playedPercentage ?? 0;
    if (item.playbackPositionTicks > 0 && played < 95) return true;
    return item.playbackPositionTicks > 0 && !item.isPlayed;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  bool _isSeriesDir(_UiItem item) {
    if (!item.isDir) return false;
    return embyNativeTypeIsSeries(item.item.type);
  }

  bool _isSeasonType(EmbyItem item) {
    return embyNativeTypeIsSeason(item.type);
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
    final resumable =
        byPlayed.where(_isResumableEpisode).toList(growable: false);
    if (resumable.isNotEmpty) return resumable;
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

  int _episodeSortCompare(EmbyItem a, EmbyItem b) {
    final seasonA = a.parentIndexNumber ?? 0;
    final seasonB = b.parentIndexNumber ?? 0;
    if (seasonA != seasonB) return seasonA.compareTo(seasonB);
    final indexA = a.indexNumber ?? 0;
    final indexB = b.indexNumber ?? 0;
    if (indexA != indexB) return indexA.compareTo(indexB);
    final ad = a.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bd = b.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0);
    final cmp = ad.compareTo(bd);
    if (cmp != 0) return cmp;
    return _naturalTitleCompare(a.name, b.name);
  }

  int _seasonSortCompare(EmbyItem a, EmbyItem b) {
    final indexA = a.indexNumber ?? 0;
    final indexB = b.indexNumber ?? 0;
    if (indexA != indexB) return indexA.compareTo(indexB);
    return _naturalTitleCompare(a.name, b.name);
  }

  String _episodeCode(EmbyItem item) {
    final season = item.parentIndexNumber;
    final episode = item.indexNumber;
    if ((season ?? 0) > 0 && (episode ?? 0) > 0) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    }
    if ((episode ?? 0) > 0) return '第 $episode 集';
    return '';
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
      seasons.sort((a, b) => _seasonSortCompare(a.item, b.item));
      final episodes = _uniqueById(
        episodesRaw
            .map((e) => _toUiItem(e, maxWidth: 640))
            .where((e) => !e.isDir && !e.isImage)
            .toList(growable: false),
      );
      episodes.sort((a, b) => _episodeSortCompare(a.item, b.item));
      var continueEpisodes = _uniqueById(
        continueRaw
            .map((e) => _toUiItem(e, maxWidth: 640))
            .where((e) => !e.isDir && !e.isImage)
            .toList(growable: false),
      );
      continueEpisodes.sort((a, b) {
        final ad = a.item.datePlayed ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.item.datePlayed ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });
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

  Map<String, String>? get _headers {
    final token = widget.account.apiKey.trim();
    if (token.isEmpty) return null;
    return <String, String>{'X-Emby-Token': token};
  }

  String _posterUrl(EmbyItem series) {
    final id = series.id.trim();
    if (id.isEmpty) return '';
    final tag = (series.primaryTag ?? '').trim();
    if (tag.isNotEmpty) {
      return _client.coverUrl(
        id,
        type: 'Primary',
        maxWidth: 560,
        quality: 90,
        tag: tag,
      );
    }
    return _client.coverUrl(
      id,
      type: 'Primary',
      maxWidth: 560,
      quality: 88,
    );
  }

  Widget _metaChip({required IconData icon, required String text}) {
    final p = _palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.chipBg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: p.text),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: p.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeProgressBar(_UiItem ep) {
    final played = ep.item.playedPercentage;
    final ratio = played != null && played.isFinite && played > 0
        ? (played / 100).clamp(0.0, 1.0)
        : (() {
            final runtime = ep.item.runTimeTicks ?? 0;
            if (runtime <= 0 || ep.item.playbackPositionTicks <= 0) return 0.0;
            return (ep.item.playbackPositionTicks / runtime).clamp(0.0, 1.0);
          })();
    if (ratio <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 4,
        color: Colors.black.withValues(alpha: 0.34),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio,
          child: Container(color: _palette.progress),
        ),
      ),
    );
  }

  Widget _episodeStatusBadge(_UiItem ep) {
    final label = ep.item.isPlayed
        ? '已看'
        : _isResumableEpisode(ep.item)
            ? '继续播放'
            : '未看';
    return Positioned(
      left: 8,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.46),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _seasonSubtitle(_UiItem season) {
    final parts = <String>[];
    final index = season.item.indexNumber;
    if ((index ?? 0) > 0) parts.add('第 $index 季');
    final unplayed = season.item.unplayedItemCount;
    if (unplayed > 0) {
      parts.add('未看 $unplayed');
    } else if (season.item.isPlayed) {
      parts.add('已看完');
    }
    return parts.join(' · ');
  }

  _UiItem? _nextUpEpisode(List<_UiItem> playlist) {
    if (playlist.isEmpty) return null;
    for (final item in playlist) {
      if (!item.item.isPlayed) return item;
    }
    if (_continueEpisodes.isEmpty) return playlist.first;
    final last = _continueEpisodes.first;
    final idx = playlist.indexWhere((e) => e.item.id == last.item.id);
    if (idx >= 0 && idx < playlist.length - 1) return playlist[idx + 1];
    return last;
  }

  Future<void> _playNextUp() async {
    final playlist = _episodePlaylist();
    final next = _nextUpEpisode(playlist);
    if (next == null) return;
    await _playEpisode(next, pool: playlist);
  }

  Widget _nextUpCard(_UiItem ep, {required List<_UiItem> playlist}) {
    final p = _palette;
    final thumb = _episodeThumbUrl(ep).trim();
    final code = _episodeCode(ep.item);
    final title = code.isEmpty ? ep.title : '$code · ${ep.title}';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _playEpisode(ep, pool: playlist),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 156,
                height: 88,
                child: thumb.isEmpty
                    ? ColoredBox(
                        color: p.coverPlaceholderBg,
                        child: Center(
                          child: Icon(Icons.movie_outlined, color: p.sub),
                        ),
                      )
                    : Image.network(
                        thumb,
                        headers: _headers,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        filterQuality: FilterQuality.low,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => ColoredBox(
                          color: p.coverPlaceholderBg,
                          child: Center(
                            child:
                                Icon(Icons.broken_image_outlined, color: p.sub),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '\u4e0b\u4e00\u96c6',
                    style: TextStyle(
                      color: p.sub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.chipSelectedBg,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.play_arrow_rounded, color: p.text),
            ),
          ],
        ),
      ),
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
    out.sort((a, b) => _episodeSortCompare(a.item, b.item));
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
      parts.add('\u8bc4\u5206 ${rating.toStringAsFixed(1)}');
    }
    final start = series.productionYear;
    if (start != null && start > 0) {
      final end =
          series.endDate == null ? '\u81f3\u4eca' : '${series.endDate!.year}';
      parts.add('$start-$end');
    }
    final seasonCount = _seasons.length;
    if (seasonCount > 0) {
      parts.add('\u5171$seasonCount\u5b63');
    }
    final episodeCount = _episodes.length;
    if (episodeCount > 0) {
      parts.add('\u5171$episodeCount\u96c6');
    }
    return parts.join('  \u00b7  ');
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
              headers: _headers,
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
                  IconButton(
                    tooltip: '\u6536\u85cf',
                    onPressed: () => showAppToast(
                      context,
                      '\u6682\u4e0d\u652f\u6301\u6536\u85cf',
                    ),
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
              series.name.trim().isEmpty
                  ? '\u672a\u547d\u540d\u5267\u96c6'
                  : series.name.trim(),
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
        child: Text('\u6682\u65e0\u5185\u5bb9', style: TextStyle(color: p.sub)),
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
          final code = _episodeCode(ep.item);
          final no = numberById[ep.item.id.trim()];
          final title = code.isNotEmpty
              ? '$code · ${ep.title}'
              : (no == null ? ep.title : '$no. ${ep.title}');
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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          thumb.isEmpty
                              ? ColoredBox(
                                  color: p.coverPlaceholderBg,
                                  child: Center(
                                    child: Icon(Icons.movie_outlined,
                                        color: p.sub),
                                  ),
                                )
                              : Image.network(
                                  thumb,
                                  headers: _headers,
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
                          _episodeStatusBadge(ep),
                          _episodeProgressBar(ep),
                        ],
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
        child: Text('\u6682\u65e0\u5206\u5b63\u4fe1\u606f',
            style: TextStyle(color: p.sub)),
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
                              headers: _headers,
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
                  const SizedBox(height: 4),
                  Text(
                    _seasonSubtitle(season),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.sub, fontSize: 11.5),
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
    final poster = _posterUrl(series).trim();
    final playlist = _episodePlaylist();
    final nextUp = _nextUpEpisode(playlist);

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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 108,
                          height: 162,
                          child: poster.isEmpty
                              ? ColoredBox(
                                  color: p.coverPlaceholderBg,
                                  child: Center(
                                    child: Icon(Icons.live_tv_outlined,
                                        color: p.sub),
                                  ),
                                )
                              : Image.network(
                                  poster,
                                  headers: _headers,
                                  fit: BoxFit.cover,
                                  cacheWidth: 560,
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (meta.isNotEmpty)
                              Text(
                                meta,
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (series.productionYear != null &&
                                    (series.productionYear ?? 0) > 0)
                                  _metaChip(
                                    icon: Icons.calendar_month_outlined,
                                    text: '${series.productionYear}',
                                  ),
                                if (series.communityRating != null &&
                                    (series.communityRating ?? 0) > 0)
                                  _metaChip(
                                    icon: Icons.star_border_rounded,
                                    text: series.communityRating!
                                        .toStringAsFixed(1),
                                  ),
                                if (_seasons.isNotEmpty)
                                  _metaChip(
                                    icon: Icons.video_collection_outlined,
                                    text: '${_seasons.length}\u5b63',
                                  ),
                                if (_episodes.isNotEmpty)
                                  _metaChip(
                                    icon: Icons.list_alt_rounded,
                                    text: '${_episodes.length}\u96c6',
                                  ),
                                if (genres.isNotEmpty)
                                  _metaChip(
                                    icon: Icons.local_offer_outlined,
                                    text:
                                        genres.split(', ').take(2).join(' / '),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              playlist.isEmpty ? _playPrimary : _playNextUp,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(
                            nextUp == null
                                ? '\u64ad\u653e'
                                : '\u64ad\u653e\u4e0b\u4e00\u96c6',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: p.chipSelectedBg,
                            foregroundColor: p.text,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            textStyle: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '\u4e0b\u4e00\u96c6',
                          style: TextStyle(
                            color: p.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _openAllEpisodes,
                        child: Text(
                          '\u5168\u90e8',
                          style: TextStyle(color: p.sub),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _detailSectionCard(
                    p,
                    title: '下一步观看',
                    subtitle: '优先使用当前续播记录推导下一集',
                    trailing: TextButton(
                      onPressed: _openAllEpisodes,
                      child: Text('全部', style: TextStyle(color: p.sub)),
                    ),
                    child: nextUp != null
                        ? _nextUpCard(nextUp, playlist: playlist)
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              '暂无可播放剧集',
                              style: TextStyle(color: p.sub),
                            ),
                          ),
                  ),
                  const SizedBox(height: 18),
                  _detailSectionCard(
                    p,
                    title: '继续观看',
                    subtitle: '保留你最近看过的剧集位置',
                    child: _episodeShelf(_continueEpisodes),
                  ),
                  const SizedBox(height: 18),
                  _detailSectionCard(
                    p,
                    title: '季',
                    subtitle: _seasons.isEmpty
                        ? '当前没有可用分季信息'
                        : '共 ${_seasons.length} 季 · ${_episodes.length} 集',
                    child: _seasonShelf(_seasons),
                  ),
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

  Map<String, String>? get _headers {
    final token = widget.account.apiKey.trim();
    if (token.isEmpty) return null;
    return <String, String>{'X-Emby-Token': token};
  }

  String _posterUrl(EmbyItem movie) {
    final id = movie.id.trim();
    if (id.isEmpty) return '';
    final tag = (movie.primaryTag ?? '').trim();
    if (tag.isNotEmpty) {
      return _client.coverUrl(
        id,
        type: 'Primary',
        maxWidth: 560,
        quality: 90,
        tag: tag,
      );
    }
    return _client.coverUrl(
      id,
      type: 'Primary',
      maxWidth: 560,
      quality: 88,
    );
  }

  Future<void> _openPoster() async {
    final movie = _movie ?? widget.seedMovie;
    final ui = _toUiItem(movie, maxWidth: 1200);
    final preferred = _preferOriginalUrl(ui.coverUrl).trim();
    final url = preferred.isNotEmpty
        ? preferred
        : _client.originalImageUrl(movie.id).trim();
    if (url.isEmpty || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerPage(
          imagePaths: <String>[url],
          initialIndex: 0,
          sourceKeys: <String>[_imageSourceKeyFor(ui)],
        ),
      ),
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
    return parts.join('  \u00b7  ');
  }

  List<Widget> _movieFactChips(EmbyItem movie) {
    final out = <Widget>[];
    final rating = movie.communityRating;
    if (rating != null && rating > 0) {
      out.add(_detailFactChip(
        _palette,
        icon: Icons.star_rounded,
        label: rating.toStringAsFixed(1),
        highlight: true,
      ));
    }
    final year = movie.productionYear;
    if (year != null && year > 0) {
      out.add(_detailFactChip(
        _palette,
        icon: Icons.calendar_today_outlined,
        label: '$year',
      ));
    }
    final duration = _durationLabel(movie.runTimeTicks);
    if (duration.isNotEmpty) {
      out.add(_detailFactChip(
        _palette,
        icon: Icons.schedule_rounded,
        label: duration,
      ));
    }
    out.add(_detailFactChip(
      _palette,
      icon: Icons.movie_outlined,
      label: '电影',
    ));
    return out;
  }

  Widget _movieSummaryPanel(EmbyItem movie) {
    final p = _palette;
    final poster = _posterUrl(movie);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 104,
              height: 156,
              child: poster.isEmpty
                  ? ColoredBox(
                      color: p.coverPlaceholderBg,
                      child: Center(
                        child:
                            Icon(Icons.movie_outlined, color: p.sub, size: 28),
                      ),
                    )
                  : Image.network(
                      poster,
                      headers: _headers,
                      fit: BoxFit.cover,
                      cacheWidth: 520,
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: p.coverPlaceholderBg,
                        child: Center(
                          child: Icon(Icons.broken_image_outlined,
                              color: p.sub, size: 24),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  movie.name.trim().isEmpty ? '未命名电影' : movie.name.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _movieFactChips(movie),
                ),
                const SizedBox(height: 10),
                Text(
                  _movieStatusText(movie),
                  style: TextStyle(
                    color: p.sub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (movie.genres.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _detailGenreWrap(p, movie.genres),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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

  bool _isResumableMovie(EmbyItem movie) {
    final played = movie.playedPercentage ?? 0;
    if (movie.playbackPositionTicks > 0 && played < 95) return true;
    return movie.playbackPositionTicks > 0 && !movie.isPlayed;
  }

  String _movieStatusText(EmbyItem movie) {
    if (movie.isPlayed) return '已看完';
    if (_isResumableMovie(movie)) return '继续播放';
    return '未开始';
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
              headers: _headers,
              fit: BoxFit.cover,
              cacheWidth: 1400,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
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
                  _movieSummaryPanel(movie),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      meta,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _detailPrimaryButton(
                          p,
                          onPressed: _playMovie,
                          icon: Icons.play_arrow_rounded,
                          label: _isResumableMovie(movie) ? '继续播放' : '播放',
                          primary: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 112,
                        child: _detailPrimaryButton(
                          p,
                          onPressed: _openPoster,
                          icon: Icons.image_outlined,
                          label: '海报',
                        ),
                      ),
                    ],
                  ),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _detailSectionCard(
                      p,
                      title: '剧情简介',
                      child: Text(
                        overview,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _detailSectionCard(
                    p,
                    title: '媒体信息',
                    subtitle: '沿用当前 Emby 返回的评分、年份和时长字段',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _movieFactChips(movie),
                    ),
                  ),
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
