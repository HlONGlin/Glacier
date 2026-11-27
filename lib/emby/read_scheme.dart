import 'dart:async';

import '../emby.dart';
import 'native_logic.dart';
import '../core/logging/app_logger.dart';

enum EmbyLibraryKindSignal { unknown, movies, series, mixed, homeVideos }

class EmbyMediaSplit {
  final List<EmbyItem> videos;
  final List<EmbyItem> images;

  const EmbyMediaSplit({
    this.videos = const <EmbyItem>[],
    this.images = const <EmbyItem>[],
  });
}

class EmbyHomeCoreSnapshot {
  final List<EmbyItem> views;
  final List<EmbyItem> resume;
  final List<EmbyItem> favorites;

  const EmbyHomeCoreSnapshot({
    this.views = const <EmbyItem>[],
    this.resume = const <EmbyItem>[],
    this.favorites = const <EmbyItem>[],
  });
}

class EmbyFolderImmediateSnapshot {
  final List<EmbyItem> directItems;
  final EmbyMediaSplit directMedia;
  final EmbyLibraryKindSignal libraryKind;
  final EmbyItem? rootContext;
  final Object? error;

  const EmbyFolderImmediateSnapshot({
    this.directItems = const <EmbyItem>[],
    this.directMedia = const EmbyMediaSplit(),
    this.libraryKind = EmbyLibraryKindSignal.unknown,
    this.rootContext,
    this.error,
  });
}

class EmbyFolderReadPlan {
  final EmbyFolderImmediateSnapshot immediate;
  final Future<EmbyMediaSplit> recursiveMedia;

  const EmbyFolderReadPlan({
    required this.immediate,
    required this.recursiveMedia,
  });
}

class EmbyReadCoordinator {
  static const Duration _kHomeCacheTtl = Duration(seconds: 12);
  static const Duration _kFolderDirectCacheTtl = Duration(seconds: 12);
  static const Duration _kFolderDeepCacheTtl = Duration(seconds: 18);
  static const int _kMaxHomeCacheEntries = 64;
  static const int _kMaxFolderDirectCacheEntries = 220;
  static const int _kMaxFolderDeepCacheEntries = 220;

  static final Map<String, _Timed<EmbyHomeCoreSnapshot>> _homeCache =
      <String, _Timed<EmbyHomeCoreSnapshot>>{};
  static final Map<String, Future<EmbyHomeCoreSnapshot>> _homeInflight =
      <String, Future<EmbyHomeCoreSnapshot>>{};

  static final Map<String, _Timed<_DirectFolderBundle>> _folderDirectCache =
      <String, _Timed<_DirectFolderBundle>>{};
  static final Map<String, Future<_DirectFolderBundle>> _folderDirectInflight =
      <String, Future<_DirectFolderBundle>>{};

  static final Map<String, _Timed<EmbyMediaSplit>> _folderDeepCache =
      <String, _Timed<EmbyMediaSplit>>{};
  static final Map<String, Future<EmbyMediaSplit>> _folderDeepInflight =
      <String, Future<EmbyMediaSplit>>{};

  final EmbyClient client;
  final String accountId;

  const EmbyReadCoordinator({
    required this.client,
    required this.accountId,
  });

  static void clearAccountCaches(String accountId) {
    final prefix = '${accountId.trim()}/';
    _homeCache.removeWhere((key, _) => key.startsWith(prefix));
    _homeInflight.removeWhere((key, _) => key.startsWith(prefix));
    _folderDirectCache.removeWhere((key, _) => key.startsWith(prefix));
    _folderDirectInflight.removeWhere((key, _) => key.startsWith(prefix));
    _folderDeepCache.removeWhere((key, _) => key.startsWith(prefix));
    _folderDeepInflight.removeWhere((key, _) => key.startsWith(prefix));
  }

  static void _trimTimedCache<T>(
    Map<String, _Timed<T>> cache, {
    required int maxEntries,
  }) {
    if (cache.length <= maxEntries) return;
    final keys = cache.keys.toList(growable: false)
      ..sort((a, b) => cache[a]!.at.compareTo(cache[b]!.at));
    final removeCount = cache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      cache.remove(keys[i]);
    }
  }

  Future<EmbyHomeCoreSnapshot> loadHomeCore({
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final key = '$accountId/home-core';
    if (!forceRefresh) {
      final cached = _homeCache[key];
      if (cached != null && cached.isFresh(_kHomeCacheTtl)) {
        return cached.value;
      }
      final shared = _homeInflight[key];
      if (shared != null) return await shared;
    }

    final fut = () async {
      final loaded = await Future.wait<_ReadAttempt<List<EmbyItem>>>([
        _attemptList(() => client.listViews().timeout(timeout)),
        _attemptList(() => client.listResumeItems(limit: 20).timeout(timeout)),
        _attemptList(
          () => client.listFavorites().timeout(const Duration(seconds: 8)),
        ),
      ]);
      for (final result in loaded) {
        if (result.error != null) throw result.error!;
      }
      final snap = EmbyHomeCoreSnapshot(
        views: loaded[0].value,
        resume: loaded[1].value,
        favorites: loaded[2].value,
      );
      _homeCache[key] = _Timed<EmbyHomeCoreSnapshot>(snap);
      _trimTimedCache(
        _homeCache,
        maxEntries: _kMaxHomeCacheEntries,
      );
      return snap;
    }();
    _homeInflight[key] = fut;
    try {
      return await fut;
    } finally {
      _homeInflight.remove(key);
    }
  }

  Future<EmbyFolderReadPlan> readFolder({
    required String folderId,
    required bool favoritesMode,
    bool forceRefresh = false,
    Duration directTimeout = const Duration(seconds: 8),
  }) async {
    final normalizedId = folderId.trim();
    final key = favoritesMode
        ? '$accountId/folder:__favorites__'
        : '$accountId/folder:$normalizedId';

    _DirectFolderBundle directBundle;
    final cachedDirect = _folderDirectCache[key];
    if (!forceRefresh &&
        cachedDirect != null &&
        cachedDirect.isFresh(_kFolderDirectCacheTtl)) {
      directBundle = cachedDirect.value;
    } else {
      final shared = forceRefresh ? null : _folderDirectInflight[key];
      if (shared != null) {
        directBundle = await shared;
      } else {
        final fut = _readDirectFolderBundle(
          folderId: normalizedId,
          favoritesMode: favoritesMode,
          timeout: directTimeout,
        );
        _folderDirectInflight[key] = fut;
        try {
          directBundle = await fut;
          if (directBundle.snapshot.error == null) {
            _folderDirectCache[key] = _Timed<_DirectFolderBundle>(directBundle);
            _trimTimedCache(
              _folderDirectCache,
              maxEntries: _kMaxFolderDirectCacheEntries,
            );
          }
        } finally {
          _folderDirectInflight.remove(key);
        }
      }
    }

    final deepCached = _folderDeepCache[key];
    if (!forceRefresh &&
        deepCached != null &&
        deepCached.isFresh(_kFolderDeepCacheTtl)) {
      return EmbyFolderReadPlan(
        immediate: directBundle.snapshot,
        recursiveMedia: Future<EmbyMediaSplit>.value(deepCached.value),
      );
    }

    final inflightDeep = forceRefresh ? null : _folderDeepInflight[key];
    if (inflightDeep != null) {
      return EmbyFolderReadPlan(
        immediate: directBundle.snapshot,
        recursiveMedia: inflightDeep,
      );
    }

    final deepFuture = _collectRecursiveMedia(
      folderId: normalizedId,
      favoritesMode: favoritesMode,
      rootItems: directBundle.snapshot.directItems,
      kind: directBundle.snapshot.libraryKind,
    ).then((value) {
      if (directBundle.snapshot.error == null &&
          (value.videos.isNotEmpty || value.images.isNotEmpty)) {
        _folderDeepCache[key] = _Timed<EmbyMediaSplit>(value);
        _trimTimedCache(
          _folderDeepCache,
          maxEntries: _kMaxFolderDeepCacheEntries,
        );
      }
      return value;
    });
    _folderDeepInflight[key] = deepFuture;
    unawaited(
      deepFuture.whenComplete(() {
        _folderDeepInflight.remove(key);
      }),
    );

    return EmbyFolderReadPlan(
      immediate: directBundle.snapshot,
      recursiveMedia: deepFuture,
    );
  }

  Future<EmbyMediaSplit> probeFolderRecursiveMedia({
    required String folderId,
    required EmbyLibraryKindSignal kindHint,
    int limit = 360,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final id = folderId.trim();
    if (id.isEmpty) return const EmbyMediaSplit();
    final include = _recursiveIncludeItemTypesForHint(hint: kindHint);
    var recursive = await _safeList(
      () => client
          .listChildren(
            parentId: id,
            recursive: true,
            includeItemTypes: include,
            sortBy: 'DateCreated',
            sortOrder: 'Descending',
            limit: limit,
            lightweight: true,
          )
          .timeout(timeout),
    );
    if (recursive.isEmpty) {
      recursive = await _safeList(
        () => client
            .listChildren(
              parentId: id,
              recursive: true,
              sortBy: 'DateCreated',
              sortOrder: 'Descending',
              limit: limit,
              lightweight: true,
            )
            .timeout(timeout),
      );
    }
    if (recursive.isEmpty) return const EmbyMediaSplit();
    return _splitMedia(recursive, kind: kindHint);
  }

  Future<_DirectFolderBundle> _readDirectFolderBundle({
    required String folderId,
    required bool favoritesMode,
    required Duration timeout,
  }) async {
    List<EmbyItem> directItems = const <EmbyItem>[];
    EmbyItem? rootContext;
    Object? readError;

    if (favoritesMode) {
      final result = await _attemptList(
        () => client.listFavorites().timeout(timeout),
      );
      directItems = result.value;
      readError = result.error;
    } else if (folderId.isNotEmpty) {
      final kindInclude = _includeItemTypesForHint(
        hint: EmbyLibraryKindSignal.unknown,
      );
      final loaded = await Future.wait<dynamic>([
        () async {
          var attempt = await _attemptList(
            () => client
                .listChildren(
                  parentId: folderId,
                  includeItemTypes: kindInclude,
                  lightweight: true,
                )
                .timeout(timeout),
          );
          if (attempt.value.isEmpty) {
            final fallback = await _attemptList(
              () => client
                  .listChildren(
                    parentId: folderId,
                    lightweight: true,
                  )
                  .timeout(timeout),
            );
            if (fallback.value.isEmpty) {
              attempt = _ReadAttempt<List<EmbyItem>>(
                value: const <EmbyItem>[],
                error: fallback.error ?? attempt.error,
              );
            } else {
              attempt = fallback;
            }
          }
          return attempt;
        }(),
        _attemptItem(
          () =>
              client.getItemById(folderId).timeout(const Duration(seconds: 5)),
        ),
      ]);
      final children = loaded[0] as _ReadAttempt<List<EmbyItem>>;
      final root = loaded[1] as _ReadAttempt<EmbyItem?>;
      directItems = children.value;
      readError = children.error;
      rootContext = root.value;
    }

    final kind = _detectLibraryKind(directItems, root: rootContext);
    final directMedia = _splitMedia(directItems, kind: kind);
    final snap = EmbyFolderImmediateSnapshot(
      directItems: directItems,
      directMedia: directMedia,
      libraryKind: kind,
      rootContext: rootContext,
      error: readError,
    );
    return _DirectFolderBundle(snapshot: snap);
  }

  Future<EmbyMediaSplit> _collectRecursiveMedia({
    required String folderId,
    required bool favoritesMode,
    required List<EmbyItem> rootItems,
    required EmbyLibraryKindSignal kind,
  }) async {
    // Prefer a single recursive server query to avoid client-side folder-chain
    // explosion in movie/series libraries with category->movie double nesting.
    Object? recursiveError;
    if (!favoritesMode && folderId.isNotEmpty) {
      final include = _recursiveIncludeItemTypesForHint(hint: kind);
      var recursive = await _attemptList(
        () => client
            .listChildren(
              parentId: folderId,
              recursive: true,
              includeItemTypes: include,
              limit: 2000,
              lightweight: true,
            )
            .timeout(const Duration(seconds: 10)),
      );
      if (recursive.value.isNotEmpty) {
        return _splitMedia(recursive.value, kind: kind);
      }
      recursiveError = recursive.error;
      if (recursive.value.isEmpty) {
        recursive = await _attemptList(
          () => client
              .listChildren(
                parentId: folderId,
                recursive: true,
                limit: 2000,
                lightweight: true,
              )
              .timeout(const Duration(seconds: 10)),
        );
        if (recursive.value.isNotEmpty) {
          return _splitMedia(recursive.value, kind: kind);
        }
        recursiveError = recursive.error;
      }
    }

    const maxFoldersToScan = 72;
    const maxMediaItems = 1200;
    const scanBudget = Duration(seconds: 3);
    const maxWorkers = 2;

    final allMedia = <EmbyItem>[];
    final seenItems = <String>{};
    final seenFolders = <String>{};
    final folderQueue = <String>[];
    var cursor = 0;
    final startedAt = DateTime.now();
    final include = _includeItemTypesForHint(hint: kind);
    Object? scanError;

    bool outOfBudget() {
      if (allMedia.length >= maxMediaItems) return true;
      if (seenFolders.length >= maxFoldersToScan) return true;
      return DateTime.now().difference(startedAt) > scanBudget;
    }

    void push(EmbyItem item) {
      final id = item.id.trim();
      if (id.isEmpty) return;
      if (!seenItems.add(id)) return;

      if (_isDir(item)) {
        if (_isSeriesFolder(item) || _isMovieFolder(item, kind: kind)) {
          allMedia.add(item);
          return;
        }
        if (seenFolders.length >= maxFoldersToScan) return;
        if (seenFolders.add(id)) {
          folderQueue.add(id);
        }
        return;
      }

      if (allMedia.length >= maxMediaItems) return;
      allMedia.add(item);
    }

    for (final item in rootItems) {
      push(item);
    }

    if (folderQueue.isNotEmpty) {
      final workerCount =
          folderQueue.length < maxWorkers ? folderQueue.length : maxWorkers;

      Future<void> worker() async {
        while (true) {
          if (outOfBudget()) return;
          if (cursor >= folderQueue.length) return;
          final folderId = folderQueue[cursor++];
          final children = await _attemptList(
            () => client
                .listChildren(
                  parentId: folderId,
                  includeItemTypes: include,
                  lightweight: true,
                )
                .timeout(const Duration(seconds: 8)),
          );
          scanError ??= children.error;
          for (final child in children.value) {
            if (outOfBudget()) return;
            push(child);
          }
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));
    }

    if (allMedia.isEmpty && (scanError ?? recursiveError) != null) {
      throw scanError ?? recursiveError!;
    }
    return _splitMedia(allMedia, kind: kind);
  }

  EmbyLibraryKindSignal _detectLibraryKind(
    List<EmbyItem> source, {
    EmbyItem? root,
  }) {
    if (embyNativeCollectionIsHomeVideos(root?.collectionType)) {
      return EmbyLibraryKindSignal.homeVideos;
    }
    if (embyNativeCollectionIsMovies(root?.collectionType)) {
      return EmbyLibraryKindSignal.movies;
    }
    if (embyNativeCollectionIsSeries(root?.collectionType)) {
      return EmbyLibraryKindSignal.series;
    }

    if (root != null) {
      if (embyNativeTypeIsSeries(root.type) ||
          embyNativeTypeIsSeason(root.type)) {
        return EmbyLibraryKindSignal.series;
      }
      if (embyNativeTypeIsMovie(root.type)) return EmbyLibraryKindSignal.movies;
    }

    var movieScore = 0;
    var seriesScore = 0;
    var genericVideoCount = 0;
    for (final item in source.take(600)) {
      if (_isImageItem(item)) continue;

      if (_isSeriesFolder(item) || embyNativeItemIsEpisode(item)) {
        seriesScore += 2;
        continue;
      }
      if (_isMovieFolder(item, kind: EmbyLibraryKindSignal.mixed) ||
          embyNativeItemIsMovie(item)) {
        movieScore += 2;
        continue;
      }
      if (_isVideoItem(item)) {
        genericVideoCount++;
      }
    }

    if (movieScore > 0 && seriesScore == 0) return EmbyLibraryKindSignal.movies;
    if (seriesScore > 0 && movieScore == 0) return EmbyLibraryKindSignal.series;
    if (movieScore > 0 || seriesScore > 0) return EmbyLibraryKindSignal.mixed;
    if (genericVideoCount > 0) return EmbyLibraryKindSignal.homeVideos;
    return EmbyLibraryKindSignal.unknown;
  }

  EmbyMediaSplit _splitMedia(
    List<EmbyItem> source, {
    required EmbyLibraryKindSignal kind,
  }) {
    final videos = <EmbyItem>[];
    final images = <EmbyItem>[];
    for (final item in source) {
      if (_isDir(item)) {
        if (_isSeriesFolder(item) || _isMovieFolder(item, kind: kind)) {
          videos.add(item);
        }
        continue;
      }
      if (_isImageItem(item)) {
        images.add(item);
      } else if (_isVideoItem(item)) {
        videos.add(item);
      }
    }
    return EmbyMediaSplit(videos: videos, images: images);
  }

  String? _includeItemTypesForHint({
    required EmbyLibraryKindSignal hint,
  }) {
    switch (hint) {
      case EmbyLibraryKindSignal.movies:
        return 'Folder,CollectionFolder,PhotoAlbum,BoxSet,Movie,Video,MusicVideo,Photo';
      case EmbyLibraryKindSignal.series:
        return 'Folder,CollectionFolder,PhotoAlbum,Series,Season,Episode,Video,Photo';
      case EmbyLibraryKindSignal.homeVideos:
        return 'Folder,CollectionFolder,PhotoAlbum,Video,Photo';
      case EmbyLibraryKindSignal.mixed:
      case EmbyLibraryKindSignal.unknown:
        return 'Folder,CollectionFolder,PhotoAlbum,BoxSet,Series,Season,Movie,Episode,Video,MusicVideo,Photo';
    }
  }

  String _recursiveIncludeItemTypesForHint({
    required EmbyLibraryKindSignal hint,
  }) {
    switch (hint) {
      case EmbyLibraryKindSignal.movies:
        return 'Movie,Video,MusicVideo,Photo';
      case EmbyLibraryKindSignal.series:
        return 'Series,Season,Episode,Video,MusicVideo,Photo';
      case EmbyLibraryKindSignal.homeVideos:
        return 'Video,Photo';
      case EmbyLibraryKindSignal.mixed:
      case EmbyLibraryKindSignal.unknown:
        return 'Movie,Series,Season,Episode,Video,MusicVideo,Photo';
    }
  }

  Future<List<EmbyItem>> _safeList(
      Future<List<EmbyItem>> Function() task) async {
    try {
      return await task();
    } catch (error, stackTrace) {
      AppLogger.error('Emby list read failed',
          error: error, stackTrace: stackTrace, tag: 'emby');
      return const <EmbyItem>[];
    }
  }

  Future<_ReadAttempt<List<EmbyItem>>> _attemptList(
    Future<List<EmbyItem>> Function() task,
  ) async {
    try {
      return _ReadAttempt<List<EmbyItem>>(value: await task());
    } catch (error, stackTrace) {
      AppLogger.error('Emby folder read failed',
          error: error, stackTrace: stackTrace, tag: 'emby');
      return _ReadAttempt<List<EmbyItem>>(
        value: const <EmbyItem>[],
        error: error,
      );
    }
  }

  Future<_ReadAttempt<EmbyItem?>> _attemptItem(
    Future<EmbyItem?> Function() task,
  ) async {
    try {
      return _ReadAttempt<EmbyItem?>(value: await task());
    } catch (error, stackTrace) {
      AppLogger.error('Emby folder metadata read failed',
          error: error, stackTrace: stackTrace, tag: 'emby');
      return _ReadAttempt<EmbyItem?>(value: null, error: error);
    }
  }
}

class _ReadAttempt<T> {
  final T value;
  final Object? error;

  const _ReadAttempt({required this.value, this.error});
}

class _DirectFolderBundle {
  final EmbyFolderImmediateSnapshot snapshot;

  const _DirectFolderBundle({required this.snapshot});
}

class _Timed<T> {
  final T value;
  final DateTime at;

  _Timed(this.value) : at = DateTime.now();

  bool isFresh(Duration ttl) => DateTime.now().difference(at) <= ttl;
}

bool _isDir(EmbyItem item) => embyNativeItemIsFolder(item);

bool _isImageItem(EmbyItem item) => embyNativeItemIsImage(item);

bool _isVideoItem(EmbyItem item) => embyNativeItemIsVideo(item);

bool _isSeriesFolder(EmbyItem item) => embyNativeFolderIsSeriesCollection(item);

bool _isMovieFolder(
  EmbyItem item, {
  required EmbyLibraryKindSignal kind,
}) {
  if (kind == EmbyLibraryKindSignal.homeVideos) return false;
  return embyNativeFolderIsMovieCollection(item);
}
