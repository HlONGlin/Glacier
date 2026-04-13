import 'emby.dart';
import 'emby_exclusive_helpers.dart';
import 'emby_exclusive_models.dart';
import 'emby_native_logic.dart';

class EmbyExclusiveSeriesHelpers {
  EmbyExclusiveSeriesHelpers._();

  static bool isResumableEpisode(EmbyItem item) {
    final played = item.playedPercentage ?? 0;
    if (item.playbackPositionTicks > 0 && played < 95) return true;
    return item.playbackPositionTicks > 0 && !item.isPlayed;
  }

  static double progressRatio(EmbyItem item) {
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

  static bool isSeriesDir(EmbyExclusiveUiItem item) {
    if (!item.isDir) return false;
    return embyNativeTypeIsSeries(item.item.type);
  }

  static bool isSeasonType(EmbyItem item) => embyNativeTypeIsSeason(item.type);

  static List<EmbyExclusiveUiItem> uniqueById(List<EmbyExclusiveUiItem> src) {
    final out = <EmbyExclusiveUiItem>[];
    final seen = <String>{};
    for (final item in src) {
      final id = item.item.id.trim();
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add(item);
    }
    return out;
  }

  static int episodeSortCompare(EmbyItem a, EmbyItem b) {
    final sa = a.parentIndexNumber ?? 0;
    final sb = b.parentIndexNumber ?? 0;
    if (sa != sb) return sa.compareTo(sb);
    final ea = a.indexNumber ?? 0;
    final eb = b.indexNumber ?? 0;
    if (ea != eb) return ea.compareTo(eb);
    return naturalTitleCompare(a.name, b.name);
  }

  static String episodeCode(EmbyItem item) {
    final season = item.parentIndexNumber ?? 0;
    final episode = item.indexNumber ?? 0;
    if (season > 0 && episode > 0) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    }
    if (episode > 0) return 'E${episode.toString().padLeft(2, '0')}';
    return '';
  }

  static String seasonSubtitle(EmbyExclusiveUiItem season) {
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

  static EmbyExclusiveUiItem? nextUpEpisode(
    List<EmbyExclusiveUiItem> playlist,
    List<EmbyExclusiveUiItem> continueEpisodes,
  ) {
    if (playlist.isEmpty) return null;
    for (final item in playlist) {
      if (!item.item.isPlayed) return item;
    }
    if (continueEpisodes.isEmpty) return playlist.first;
    final last = continueEpisodes.first;
    final idx = playlist.indexWhere((e) => e.item.id == last.item.id);
    if (idx >= 0 && idx < playlist.length - 1) return playlist[idx + 1];
    return last;
  }

  static List<EmbyExclusiveUiItem> episodePlaylist(
    List<EmbyExclusiveUiItem> episodes,
  ) {
    final out = episodes.where((e) => !isSeriesDir(e)).toList(growable: true);
    out.sort((a, b) => episodeSortCompare(a.item, b.item));
    return out;
  }

  static Map<String, int> episodeNumberById(
    List<EmbyExclusiveUiItem> playlist,
  ) {
    final out = <String, int>{};
    for (var i = 0; i < playlist.length; i++) {
      final id = playlist[i].item.id.trim();
      if (id.isEmpty) continue;
      out[id] = i + 1;
    }
    return out;
  }

  static String metaLine({
    required EmbyItem series,
    required int seasonsCount,
    required int episodesCount,
  }) {
    final parts = <String>[];
    final rating = series.communityRating;
    if (rating != null && rating > 0) {
      parts.add('评分 ${rating.toStringAsFixed(1)}');
    }
    final start = series.productionYear;
    if (start != null && start > 0) {
      final end = series.endDate == null ? '至今' : '${series.endDate!.year}';
      parts.add('$start-$end');
    }
    if (seasonsCount > 0) {
      parts.add('共$seasonsCount季');
    }
    if (episodesCount > 0) {
      parts.add('共$episodesCount集');
    }
    return parts.join('  ·  ');
  }
}
