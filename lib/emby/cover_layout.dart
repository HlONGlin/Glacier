enum EmbyCoverAspectBucket { poster, square, landscape }

class EmbyCoverLayout {
  static const double kInputMin = 0.45;
  static const double kInputMax = 2.4;
  static const double kPosterMin = 0.56;
  static const double kPosterMax = 0.88;
  static const double kSquareMin = 0.9;
  static const double kSquareMax = 1.2;
  static const double kLandscapeMin = 1.3;
  static const double kLandscapeMax = 2.0;

  static const double kGridCrossSpacing = 10.0;
  static const double kGridGapCoverTitle = 6.0;
  static const double kGridTitleHeight = 20.0;
  static const double kGridRatioMin = 0.45;
  static const double kGridRatioMax = 1.45;

  static const double kShelfPosterHeight = 132.0;
  static const double kShelfSquareHeight = 118.0;
  static const double kShelfLandscapeHeight = 108.0;

  static double estimateAspect({
    required double? primaryAspectRatio,
    required bool isImage,
    required bool isDir,
    required String itemType,
  }) {
    final ratio = primaryAspectRatio;
    if (ratio != null &&
        ratio.isFinite &&
        ratio >= kInputMin &&
        ratio <= kInputMax) {
      return ratio;
    }
    if (isImage) return 1.5;
    if (isDir) return 0.67;
    final type = itemType.trim().toLowerCase();
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

  static EmbyCoverAspectBucket classify(double ratio) {
    if (ratio < 0.9) return EmbyCoverAspectBucket.poster;
    if (ratio <= 1.25) return EmbyCoverAspectBucket.square;
    return EmbyCoverAspectBucket.landscape;
  }

  static double clampDominantAspect(
    EmbyCoverAspectBucket bucket,
    double averageRatio,
  ) {
    switch (bucket) {
      case EmbyCoverAspectBucket.poster:
        return averageRatio.clamp(kPosterMin, kPosterMax).toDouble();
      case EmbyCoverAspectBucket.square:
        return averageRatio.clamp(kSquareMin, kSquareMax).toDouble();
      case EmbyCoverAspectBucket.landscape:
        return averageRatio.clamp(kLandscapeMin, kLandscapeMax).toDouble();
    }
  }

  static double dominantAspect<T>(
    List<T> items, {
    required double Function(T item) aspectOf,
    required bool Function(T item) isImage,
  }) {
    if (items.isEmpty) return 0.67;
    final values = <EmbyCoverAspectBucket, List<double>>{
      EmbyCoverAspectBucket.poster: <double>[],
      EmbyCoverAspectBucket.square: <double>[],
      EmbyCoverAspectBucket.landscape: <double>[],
    };
    var imageCount = 0;
    for (final item in items) {
      final ratio = aspectOf(item);
      values[classify(ratio)]!.add(ratio);
      if (isImage(item)) imageCount++;
    }
    final preferLandscape = imageCount * 2 >= items.length;

    var winner = preferLandscape
        ? EmbyCoverAspectBucket.landscape
        : EmbyCoverAspectBucket.poster;
    var winnerCount = values[winner]!.length;
    for (final bucket in EmbyCoverAspectBucket.values) {
      final count = values[bucket]!.length;
      if (count > winnerCount) {
        winner = bucket;
        winnerCount = count;
        continue;
      }
      if (count == winnerCount && count > 0) {
        if (preferLandscape && bucket == EmbyCoverAspectBucket.landscape) {
          winner = bucket;
        }
        if (!preferLandscape && bucket == EmbyCoverAspectBucket.poster) {
          winner = bucket;
        }
      }
    }

    final selected = values[winner]!;
    if (selected.isEmpty) return 0.67;
    var sum = 0.0;
    for (final value in selected) {
      sum += value;
    }
    final avg = sum / selected.length;
    return clampDominantAspect(winner, avg);
  }

  static double tileWidth({
    required double maxWidth,
    required int columns,
    double crossSpacing = kGridCrossSpacing,
  }) {
    if (columns <= 0) return 1.0;
    final safeWidth = maxWidth <= 0 ? 1.0 : maxWidth;
    final usableWidth =
        (safeWidth - crossSpacing * (columns - 1)).clamp(1.0, 100000.0);
    return usableWidth / columns;
  }

  static double gridChildAspectRatio({
    required double maxWidth,
    required int columns,
    required double coverAspectRatio,
    double crossSpacing = kGridCrossSpacing,
    double gapCoverTitle = kGridGapCoverTitle,
    double titleHeight = kGridTitleHeight,
  }) {
    if (columns <= 0) return 0.95;
    final width = tileWidth(
      maxWidth: maxWidth,
      columns: columns,
      crossSpacing: crossSpacing,
    );
    final height = (width / coverAspectRatio) + gapCoverTitle + titleHeight;
    final ratio = width / height;
    return ratio.clamp(kGridRatioMin, kGridRatioMax).toDouble();
  }

  static double shelfCoverHeight(double coverAspectRatio) {
    switch (classify(coverAspectRatio)) {
      case EmbyCoverAspectBucket.poster:
        return kShelfPosterHeight;
      case EmbyCoverAspectBucket.square:
        return kShelfSquareHeight;
      case EmbyCoverAspectBucket.landscape:
        return kShelfLandscapeHeight;
    }
  }
}
