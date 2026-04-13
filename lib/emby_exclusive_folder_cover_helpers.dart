import 'emby_exclusive_models.dart';

class EmbyExclusiveFolderCoverHelpers {
  EmbyExclusiveFolderCoverHelpers._();

  static Map<String, String> takePendingBatch(Map<String, String> pending) {
    final batch = Map<String, String>.from(pending);
    pending.clear();
    return batch;
  }

  static List<String> collectRegularFolderIds(
    Iterable<EmbyExclusiveUiItem> source,
    Set<String> seen, {
    required bool Function(EmbyExclusiveUiItem item) isSeriesFolder,
    required bool Function(EmbyExclusiveUiItem item) isMovieFolder,
    required Map<String, String> folderCoverUrlCache,
  }) {
    final out = <String>[];
    for (final item in source) {
      if (!item.isDir) continue;
      if (isSeriesFolder(item) || isMovieFolder(item)) continue;
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      if ((folderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;
      out.add(id);
    }
    return out;
  }

  static List<String> collectMovieFolderIds(
    Iterable<EmbyExclusiveUiItem> source,
    Set<String> seen, {
    required bool Function(EmbyExclusiveUiItem item) isMovieFolder,
    required Map<String, String> movieFolderCoverUrlCache,
    required Set<String> movieFolderPrimaryMisses,
  }) {
    final out = <String>[];
    for (final item in source) {
      if (!isMovieFolder(item)) continue;
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      if ((movieFolderCoverUrlCache[id] ?? '').trim().isNotEmpty) continue;
      if (movieFolderPrimaryMisses.contains(id)) continue;
      out.add(id);
    }
    return out;
  }
}
