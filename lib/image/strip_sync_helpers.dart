import 'dart:math';

class ImageStripSyncHelpers {
  static ({int start, int end}) scanWindow({
    required int currentIndex,
    required int total,
    int radius = 10,
  }) {
    if (total <= 0) return (start: 0, end: -1);
    return (
      start: max(0, currentIndex - radius),
      end: min(total - 1, currentIndex + radius),
    );
  }

  static double scoreForDy({
    required double dy,
    required double safeTop,
  }) {
    return (dy - safeTop).abs();
  }

  static bool shouldCommitBestIndex({
    required int currentIndex,
    required int bestIndex,
  }) {
    return bestIndex != currentIndex;
  }
}
