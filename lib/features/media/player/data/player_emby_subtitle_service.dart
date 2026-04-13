import 'package:collection/collection.dart';

import '../../../../emby.dart';
import '../../../../sources/refs.dart';

class PlayerEmbyNowPlaying {
  final EmbyAccount account;
  final String itemId;

  const PlayerEmbyNowPlaying({required this.account, required this.itemId});
}

class PlayerEmbyStreamInfo {
  final String itemId;

  const PlayerEmbyStreamInfo({required this.itemId});
}

class PlayerEmbySubtitleService {
  PlayerEmbySubtitleService._();

  static PlayerEmbyStreamInfo? parseEmbyStreamInfo(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      final videosIndex =
          segments.indexWhere((segment) => segment.toLowerCase() == 'videos');
      if (videosIndex < 0 || videosIndex + 2 >= segments.length) return null;

      final itemId = segments[videosIndex + 1].trim();
      final tail = segments[videosIndex + 2].toLowerCase();
      if (itemId.isEmpty || !tail.startsWith('stream')) return null;
      return PlayerEmbyStreamInfo(itemId: itemId);
    } catch (_) {
      return null;
    }
  }

  static EmbySubtitleTrack? pickBestSubtitle(
    List<EmbySubtitleTrack> tracks,
  ) {
    if (tracks.isEmpty) return null;

    final defaultTrack = tracks.firstWhereOrNull((track) => track.isDefault);
    if (defaultTrack != null) return defaultTrack;

    bool isChineseLike(EmbySubtitleTrack track) {
      final text =
          ('${track.language ?? ''} ${track.title} ${track.codec ?? ''}')
              .toLowerCase();
      return text.contains('chi') ||
          text.contains('zho') ||
          text.contains('zh') ||
          text.contains('中文') ||
          text.contains('chinese') ||
          text.contains('简体') ||
          text.contains('繁体');
    }

    final chineseExternal = tracks.firstWhereOrNull(
      (track) => track.isExternal && isChineseLike(track),
    );
    if (chineseExternal != null) return chineseExternal;

    final anyExternal = tracks.firstWhereOrNull((track) => track.isExternal);
    if (anyExternal != null) return anyExternal;

    return tracks.first;
  }

  static Future<PlayerEmbyNowPlaying?> resolveNowPlaying(
    String source, {
    required Future<EmbyAccount?> Function(String accountId) getAccountById,
    required Future<EmbyAccount?> Function(String url) resolveAccountForStream,
  }) async {
    final ref = parseEmbySourceRef(source);
    if (ref != null) {
      final account = await getAccountById(ref.accountId);
      if (account == null) return null;
      return PlayerEmbyNowPlaying(account: account, itemId: ref.itemId);
    }

    final streamInfo = parseEmbyStreamInfo(source);
    if (streamInfo == null) return null;

    final account = await resolveAccountForStream(source);
    if (account == null) return null;
    return PlayerEmbyNowPlaying(account: account, itemId: streamInfo.itemId);
  }
}
