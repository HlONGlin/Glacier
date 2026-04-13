import 'emby_read_scheme.dart';
import 'emby_exclusive_models.dart';
import 'emby_exclusive_helpers.dart';

enum EmbyFolderTopTab { videos, images, folders }

enum EmbyFolderSortKind { updatedAt, addedAt, title, playDuration, playedAt }

enum EmbyAspectBucket { poster, square, landscape }

enum EmbyLibraryKind { unknown, movies, series, mixed }

class EmbyExclusiveFolderHelpers {
  EmbyExclusiveFolderHelpers._();

  static EmbyLibraryKind libraryKindFromSignal(EmbyLibraryKindSignal kind) {
    switch (kind) {
      case EmbyLibraryKindSignal.movies:
        return EmbyLibraryKind.movies;
      case EmbyLibraryKindSignal.series:
        return EmbyLibraryKind.series;
      case EmbyLibraryKindSignal.mixed:
        return EmbyLibraryKind.mixed;
      case EmbyLibraryKindSignal.homeVideos:
      case EmbyLibraryKindSignal.unknown:
        return EmbyLibraryKind.unknown;
    }
  }

  static String libraryKindLabel(EmbyLibraryKind kind) {
    switch (kind) {
      case EmbyLibraryKind.movies:
        return '电影库';
      case EmbyLibraryKind.series:
        return '剧集库';
      case EmbyLibraryKind.mixed:
        return '影视混合';
      case EmbyLibraryKind.unknown:
        return '';
    }
  }

  static String topTabLabel(
    EmbyFolderTopTab tab,
    EmbyLibraryKind libraryKind,
  ) {
    switch (tab) {
      case EmbyFolderTopTab.videos:
        if (libraryKind == EmbyLibraryKind.series) return '单集';
        if (libraryKind == EmbyLibraryKind.movies) return '视频文件';
        return '视频';
      case EmbyFolderTopTab.images:
        return '图片';
      case EmbyFolderTopTab.folders:
        if (libraryKind == EmbyLibraryKind.series) return '剧集';
        if (libraryKind == EmbyLibraryKind.movies) return '内容';
        return '分类';
    }
  }

  static String sortLabel(EmbyFolderSortKind sort) {
    switch (sort) {
      case EmbyFolderSortKind.updatedAt:
        return '更新日期';
      case EmbyFolderSortKind.addedAt:
        return '加入日期';
      case EmbyFolderSortKind.title:
        return '标题';
      case EmbyFolderSortKind.playDuration:
        return '播放时长';
      case EmbyFolderSortKind.playedAt:
        return '播放日期';
    }
  }

  static double? primaryAspectOf(EmbyExclusiveUiItem item) {
    final ratio = item.item.primaryImageAspectRatio;
    if (ratio == null || !ratio.isFinite) return null;
    if (ratio < 0.45 || ratio > 2.4) return null;
    return ratio;
  }

  static double fallbackAspectOf(EmbyExclusiveUiItem item) {
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

  static double estimateAspectOf(EmbyExclusiveUiItem item) {
    return primaryAspectOf(item) ?? fallbackAspectOf(item);
  }

  static EmbyAspectBucket bucketOf(double ratio) {
    if (ratio < 0.9) return EmbyAspectBucket.poster;
    if (ratio <= 1.25) return EmbyAspectBucket.square;
    return EmbyAspectBucket.landscape;
  }

  static int bucketPriority(
    EmbyAspectBucket bucket,
    EmbyFolderTopTab topTab,
  ) {
    switch (topTab) {
      case EmbyFolderTopTab.images:
        switch (bucket) {
          case EmbyAspectBucket.landscape:
            return 3;
          case EmbyAspectBucket.square:
            return 2;
          case EmbyAspectBucket.poster:
            return 1;
        }
      case EmbyFolderTopTab.videos:
        switch (bucket) {
          case EmbyAspectBucket.poster:
            return 3;
          case EmbyAspectBucket.landscape:
            return 2;
          case EmbyAspectBucket.square:
            return 1;
        }
      case EmbyFolderTopTab.folders:
        switch (bucket) {
          case EmbyAspectBucket.poster:
            return 3;
          case EmbyAspectBucket.square:
            return 2;
          case EmbyAspectBucket.landscape:
            return 1;
        }
    }
  }

  static double dominantCoverAspect(
    List<EmbyExclusiveUiItem> items, {
    required EmbyFolderTopTab topTab,
  }) {
    if (items.isEmpty) return 0.67;
    final values = <EmbyAspectBucket, List<double>>{
      EmbyAspectBucket.poster: <double>[],
      EmbyAspectBucket.square: <double>[],
      EmbyAspectBucket.landscape: <double>[],
    };

    for (final item in items) {
      final ratio = estimateAspectOf(item);
      values[bucketOf(ratio)]!.add(ratio);
    }

    var winner = EmbyAspectBucket.poster;
    var winnerCount = -1;
    for (final bucket in EmbyAspectBucket.values) {
      final count = values[bucket]!.length;
      if (count > winnerCount) {
        winner = bucket;
        winnerCount = count;
        continue;
      }
      if (count == winnerCount &&
          count > 0 &&
          bucketPriority(bucket, topTab) > bucketPriority(winner, topTab)) {
        winner = bucket;
      }
    }

    final selected = values[winner]!;
    if (selected.isEmpty) return 0.67;
    var sum = 0.0;
    for (final value in selected) {
      sum += value;
    }
    final average = sum / selected.length;
    switch (winner) {
      case EmbyAspectBucket.poster:
        return average.clamp(0.56, 0.88).toDouble();
      case EmbyAspectBucket.square:
        return average.clamp(0.9, 1.2).toDouble();
      case EmbyAspectBucket.landscape:
        return average.clamp(1.3, 2.0).toDouble();
    }
  }

  static double gridChildAspectRatio({
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

  static int adaptiveGridColumns({
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

  static int categorySortRank(EmbyExclusiveUiItem item) {
    if (item.isDir) return 0;
    if (item.isImage) return 1;
    return 2;
  }

  static int sortFieldCompare(
    EmbyExclusiveUiItem a,
    EmbyExclusiveUiItem b, {
    required EmbyFolderSortKind sort,
    required String Function(EmbyExclusiveUiItem) displayTitle,
  }) {
    switch (sort) {
      case EmbyFolderSortKind.updatedAt:
        return (a.item.dateModified?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.dateModified?.millisecondsSinceEpoch ?? 0);
      case EmbyFolderSortKind.addedAt:
        return (a.item.dateCreated?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.dateCreated?.millisecondsSinceEpoch ?? 0);
      case EmbyFolderSortKind.playDuration:
        return (a.item.runTimeTicks ?? 0).compareTo(b.item.runTimeTicks ?? 0);
      case EmbyFolderSortKind.playedAt:
        return (a.item.datePlayed?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.item.datePlayed?.millisecondsSinceEpoch ?? 0);
      case EmbyFolderSortKind.title:
        return naturalTitleCompare(displayTitle(a), displayTitle(b));
    }
  }
}
