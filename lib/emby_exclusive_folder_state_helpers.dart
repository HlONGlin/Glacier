import 'emby.dart';
import 'emby_exclusive_folder_helpers.dart';
import 'emby_exclusive_models.dart';
import 'emby_native_logic.dart';

class EmbyExclusiveFolderStateHelpers {
  EmbyExclusiveFolderStateHelpers._();

  static List<EmbyExclusiveUiItem> mergeUiById(
    List<EmbyExclusiveUiItem> base,
    List<EmbyExclusiveUiItem> extra,
  ) {
    if (base.isEmpty) return extra;
    if (extra.isEmpty) return base;
    final seen = <String>{};
    final out = <EmbyExclusiveUiItem>[];
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

  static Map<String, EmbyExclusiveUiItem> indexUiById(
    List<EmbyExclusiveUiItem> src,
  ) {
    final out = <String, EmbyExclusiveUiItem>{};
    for (final item in src) {
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      out[id] = item;
    }
    return out;
  }

  static List<EmbyExclusiveUiItem> toUiItemsWithSeed(
    Iterable<EmbyItem> items, {
    required EmbyExclusiveUiItem Function(EmbyItem item, {int maxWidth})
        toUiItem,
    required int maxWidth,
    Map<String, EmbyExclusiveUiItem>? seed,
  }) {
    final out = <EmbyExclusiveUiItem>[];
    for (final item in items) {
      final id = item.id.trim();
      final cached = (id.isNotEmpty && seed != null) ? seed[id] : null;
      if (cached != null) {
        out.add(cached);
        continue;
      }
      out.add(toUiItem(item, maxWidth: maxWidth));
    }
    return out;
  }

  static bool isMovieItem(
    EmbyExclusiveUiItem item, {
    required EmbyLibraryKind libraryKind,
  }) {
    if (item.isDir || item.isImage) return false;
    final preferMovie = libraryKind == EmbyLibraryKind.movies;
    final preferSeries = libraryKind == EmbyLibraryKind.series;
    if (preferSeries) return false;
    if (preferMovie) return embyNativeItemIsMovie(item.item);
    return embyNativeItemIsMovie(item.item);
  }

  static bool prefersStructuredContentTab(EmbyLibraryKind libraryKind) {
    return libraryKind == EmbyLibraryKind.series ||
        libraryKind == EmbyLibraryKind.movies;
  }

  static bool isImageDominantMixedLibrary({
    required bool imageLibrarySimpleModeEnabled,
    required EmbyLibraryKind libraryKind,
    required int recursiveImagesCount,
    required int recursiveVideosCount,
    required int thresholdPercent,
  }) {
    if (!imageLibrarySimpleModeEnabled) return false;
    if (prefersStructuredContentTab(libraryKind)) return false;
    if (recursiveImagesCount <= 0) return false;
    if (recursiveVideosCount <= 0) return true;
    final total = recursiveImagesCount + recursiveVideosCount;
    if (total <= 0) return false;
    final imageRatioPct = recursiveImagesCount * 100.0 / total;
    final threshold = thresholdPercent.clamp(50, 90);
    return imageRatioPct >= threshold;
  }

  static EmbyExclusiveUiItem seriesProxyFromVideo(
    EmbyExclusiveUiItem item, {
    required EmbyAccount account,
  }) {
    final seriesId = (item.item.seriesId ?? '').trim();
    final seriesName = (item.item.seriesName ?? '').trim();
    return EmbyExclusiveUiItem(
      account: account,
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

  static List<EmbyExclusiveUiItem> collapsedSeriesVideoItems(
    List<EmbyExclusiveUiItem> source, {
    required List<EmbyExclusiveUiItem> directItems,
    required bool Function(EmbyExclusiveUiItem item) isSeriesDir,
    required EmbyExclusiveUiItem Function(EmbyExclusiveUiItem item)
        seriesProxyFromVideo,
  }) {
    if (source.isEmpty) return source;
    final directSeries = <String, EmbyExclusiveUiItem>{
      for (final item in directItems)
        if (isSeriesDir(item) && item.item.id.trim().isNotEmpty)
          item.item.id.trim(): item,
    };
    final out = <EmbyExclusiveUiItem>[];
    final seen = <String>{};
    for (final item in source) {
      final seriesId = (item.item.seriesId ?? '').trim();
      if (seriesId.isEmpty) {
        final id = item.item.id.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        out.add(item);
        continue;
      }
      if (!seen.add(seriesId)) continue;
      out.add(directSeries[seriesId] ?? seriesProxyFromVideo(item));
    }
    return out;
  }

  static List<EmbyExclusiveUiItem> contentItemsForCurrentFolder({
    required EmbyLibraryKind libraryKind,
    required bool imageDominantMixedLibrary,
    required List<EmbyExclusiveUiItem> items,
    required List<EmbyExclusiveUiItem> recursiveVideos,
    required bool Function(EmbyExclusiveUiItem item) isSeriesDir,
    required bool Function(EmbyExclusiveUiItem item) isMovieFolder,
    required bool Function(EmbyExclusiveUiItem item) isMovieItem,
    required List<EmbyExclusiveUiItem> Function(
            List<EmbyExclusiveUiItem> source)
        collapsedSeriesVideoItems,
  }) {
    if (imageDominantMixedLibrary) return items;

    if (libraryKind == EmbyLibraryKind.series) {
      final directSeries = items.where(isSeriesDir).toList(growable: false);
      if (directSeries.isNotEmpty) return directSeries;
      final directPlayable = items
          .where((item) => !item.isDir && !item.isImage)
          .toList(growable: false);
      final collapsed = collapsedSeriesVideoItems(
          mergeUiById(directPlayable, recursiveVideos));
      return collapsed.isNotEmpty ? collapsed : items;
    }

    if (libraryKind == EmbyLibraryKind.movies) {
      final directMovieFolders =
          items.where(isMovieFolder).toList(growable: false);
      final directMovieFiles = items.where(isMovieItem).toList(growable: false);
      if (directMovieFolders.isNotEmpty) {
        return mergeUiById(directMovieFolders, directMovieFiles);
      }
      final recursiveMovieFiles =
          recursiveVideos.where(isMovieItem).toList(growable: false);
      final merged = mergeUiById(directMovieFiles, recursiveMovieFiles);
      return merged.isNotEmpty ? merged : items;
    }

    return items;
  }

  static List<EmbyExclusiveUiItem> baseItemsForTab({
    required EmbyFolderTopTab topTab,
    required EmbyLibraryKind libraryKind,
    required bool imageDominantMixedLibrary,
    required List<EmbyExclusiveUiItem> items,
    required List<EmbyExclusiveUiItem> recursiveVideos,
    required List<EmbyExclusiveUiItem> recursiveImages,
    required bool Function(EmbyExclusiveUiItem item) isVideoItem,
    required List<EmbyExclusiveUiItem> Function(
            List<EmbyExclusiveUiItem> source)
        collapsedSeriesVideoItems,
    required List<EmbyExclusiveUiItem> Function() contentItemsForCurrentFolder,
  }) {
    final directImages =
        items.where((item) => item.isImage).toList(growable: false);
    final directVideos = items
        .where((item) => !item.isDir && isVideoItem(item))
        .toList(growable: false);

    switch (topTab) {
      case EmbyFolderTopTab.videos:
        if (libraryKind == EmbyLibraryKind.series) {
          return collapsedSeriesVideoItems(recursiveVideos);
        }
        if (imageDominantMixedLibrary && directVideos.isNotEmpty) {
          return directVideos;
        }
        return recursiveVideos;
      case EmbyFolderTopTab.images:
        if (imageDominantMixedLibrary && directImages.isNotEmpty) {
          return mergeUiById(directImages, recursiveImages);
        }
        if (recursiveImages.isEmpty && directImages.isNotEmpty) {
          return directImages;
        }
        return recursiveImages;
      case EmbyFolderTopTab.folders:
        return contentItemsForCurrentFolder();
    }
  }

  static List<EmbyFolderTopTab> visibleTopTabs({
    required bool prefersStructuredContentTab,
    required bool imageDominantMixedLibrary,
    required bool hasImages,
    required bool recursiveVideosNotEmpty,
    required bool hasFolderTabItems,
    required bool contentItemsNotEmpty,
  }) {
    final tabs = <EmbyFolderTopTab>[];
    void addTab(EmbyFolderTopTab tab) {
      if (!tabs.contains(tab)) tabs.add(tab);
    }

    if (prefersStructuredContentTab) {
      if (contentItemsNotEmpty) {
        addTab(EmbyFolderTopTab.folders);
      } else if (recursiveVideosNotEmpty) {
        addTab(EmbyFolderTopTab.videos);
      }
    } else if (imageDominantMixedLibrary) {
      addTab(EmbyFolderTopTab.folders);
      if (hasImages) addTab(EmbyFolderTopTab.images);
      if (recursiveVideosNotEmpty) addTab(EmbyFolderTopTab.videos);
    } else {
      if (recursiveVideosNotEmpty) {
        addTab(EmbyFolderTopTab.videos);
      }
      if (hasFolderTabItems) addTab(EmbyFolderTopTab.folders);
    }
    if (hasImages) addTab(EmbyFolderTopTab.images);
    if (tabs.isEmpty) {
      if (recursiveVideosNotEmpty) {
        addTab(EmbyFolderTopTab.videos);
      } else {
        addTab(EmbyFolderTopTab.folders);
      }
    }
    return tabs;
  }

  static EmbyFolderTopTab preferredTopTab({
    required bool hasVideos,
    required bool hasImages,
    required bool hasFolders,
    required bool prefersStructuredContentTab,
    required bool imageDominantMixedLibrary,
  }) {
    if (prefersStructuredContentTab && hasFolders) {
      return EmbyFolderTopTab.folders;
    }
    if (imageDominantMixedLibrary) {
      if (hasFolders) return EmbyFolderTopTab.folders;
      if (hasImages) return EmbyFolderTopTab.images;
      if (hasVideos) return EmbyFolderTopTab.videos;
    }
    if (hasVideos) return EmbyFolderTopTab.videos;
    if (hasFolders) return EmbyFolderTopTab.folders;
    if (hasImages) return EmbyFolderTopTab.images;
    return EmbyFolderTopTab.videos;
  }

  static EmbyFolderTopTab chooseTopTab({
    required EmbyFolderTopTab current,
    required List<EmbyExclusiveUiItem> directItems,
    required List<EmbyExclusiveUiItem> videos,
    required List<EmbyExclusiveUiItem> images,
    required bool preferPriority,
    required bool prefersStructuredContentTab,
    required bool Function(List<EmbyExclusiveUiItem> directItems)
        hasFolderTabItems,
    required EmbyFolderTopTab Function({
      required bool hasVideos,
      required bool hasImages,
      required bool hasFolders,
    }) preferredTopTab,
  }) {
    final hasVideos = videos.isNotEmpty;
    final hasImages = images.isNotEmpty;
    final hasFolders = hasFolderTabItems(directItems);
    if (preferPriority) {
      return preferredTopTab(
        hasVideos: hasVideos,
        hasImages: hasImages,
        hasFolders: hasFolders,
      );
    }

    if (prefersStructuredContentTab && hasFolders) {
      if (current == EmbyFolderTopTab.folders) {
        return EmbyFolderTopTab.folders;
      }
      if (current == EmbyFolderTopTab.images && hasImages) {
        return EmbyFolderTopTab.images;
      }
      return EmbyFolderTopTab.folders;
    }

    if (current == EmbyFolderTopTab.videos && hasVideos) {
      return EmbyFolderTopTab.videos;
    }
    if (current == EmbyFolderTopTab.folders && hasFolders) {
      return EmbyFolderTopTab.folders;
    }
    if (current == EmbyFolderTopTab.images && hasImages) {
      return EmbyFolderTopTab.images;
    }

    return preferredTopTab(
      hasVideos: hasVideos,
      hasImages: hasImages,
      hasFolders: hasFolders,
    );
  }
}
