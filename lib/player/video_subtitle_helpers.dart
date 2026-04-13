part of '../video.dart';

EmbySubtitleTrack? _pickPreferredEmbySubtitle(
  List<EmbySubtitleTrack> tracks,
) {
  return PlayerEmbySubtitleService.pickBestSubtitle(tracks);
}

Future<String?> _buildResolvedEmbySubtitleUrl({
  required PlayerEmbyNowPlaying? nowPlaying,
  required EmbySubtitleTrack track,
}) async {
  if (nowPlaying == null) return null;
  final client = EmbyClient(nowPlaying.account);
  final deviceId = await EmbyStore.getOrCreateDeviceId();
  return client.subtitleStreamUrl(
    itemId: nowPlaying.itemId,
    mediaSourceId: track.mediaSourceId,
    subtitleIndex: track.index,
    format: 'srt',
    deviceId: deviceId,
  );
}

Future<EmbyAccount?> _findEmbyAccountByToken(String url) async {
  try {
    final u = Uri.parse(url);
    final key = (u.queryParameters['api_key'] ??
            u.queryParameters['X-Emby-Token'] ??
            '')
        .trim();
    if (key.isEmpty) return null;
    final list = await EmbyStore.load();
    for (final a in list) {
      if (a.apiKey.trim() == key) return a;
    }
    return null;
  } catch (_) {
    return null;
  }
}

extension _DesktopVideoSubtitleHelpers on _VideoPlayerPageState {
  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) {
    return _pickPreferredEmbySubtitle(tracks);
  }

  Future<EmbyAccount?> _getEmbyAccountById(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    try {
      final m = await (_embyAccountMapFuture ??=
          PlayerSourceResolver.loadEmbyAccountMap());
      final acc = m[id];
      if (acc != null) return acc;
    } catch (_) {}

    try {
      final list = await EmbyStore.load();
      return list.firstWhereOrNull((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<EmbyAccount?> _resolveEmbyAccountForStream(String url) {
    return _findEmbyAccountByToken(url);
  }

  Future<PlayerEmbyNowPlaying?> _resolveEmbyNowPlaying(String source) {
    return PlayerEmbySubtitleService.resolveNowPlaying(
      source,
      getAccountById: _getEmbyAccountById,
      resolveAccountForStream: _resolveEmbyAccountForStream,
    );
  }

  Future<String?> _buildEmbySubtitleUrl(EmbySubtitleTrack track) async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    return _buildResolvedEmbySubtitleUrl(nowPlaying: np, track: track);
  }
}

extension _MobileVideoSubtitleHelpers on _MobileVideoPlayerPageState {
  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) {
    return _pickPreferredEmbySubtitle(tracks);
  }

  Future<EmbyAccount?> _resolveEmbyAccountForStream(String url) async {
    try {
      final u = Uri.parse(url);
      final key = (u.queryParameters['api_key'] ??
              u.queryParameters['X-Emby-Token'] ??
              '')
          .trim();
      if (key.isEmpty) return null;
      _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
      for (final a in _embyAccounts!.values) {
        if (a.apiKey.trim() == key) return a;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<PlayerEmbyNowPlaying?> _resolveEmbyNowPlaying(String source) {
    return PlayerEmbySubtitleService.resolveNowPlaying(
      source,
      getAccountById: (accountId) async {
        _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
        return _embyAccounts![accountId];
      },
      resolveAccountForStream: _resolveEmbyAccountForStream,
    );
  }

  Future<String?> _buildEmbySubtitleUrl(EmbySubtitleTrack track) async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    return _buildResolvedEmbySubtitleUrl(nowPlaying: np, track: track);
  }
}

class _MobileEmbySubtitleCandidatesResult {
  final List<EmbySubtitleTrack> candidates;
  final EmbySubtitleTrack? selected;

  const _MobileEmbySubtitleCandidatesResult({
    required this.candidates,
    required this.selected,
  });
}

Future<_MobileEmbySubtitleCandidatesResult> _loadMobileEmbySubtitleCandidates({
  required String currentPath,
  required EmbySubtitleTrack? currentSelection,
  required Future<Map<String, EmbyAccount>> Function() loadAccountMap,
  required Future<EmbyAccount?> Function(String url) resolveAccountForStream,
}) async {
  final np = await PlayerEmbySubtitleService.resolveNowPlaying(
    currentPath,
    getAccountById: (accountId) async {
      final accounts = await loadAccountMap();
      return accounts[accountId];
    },
    resolveAccountForStream: resolveAccountForStream,
  );
  if (np == null) {
    return const _MobileEmbySubtitleCandidatesResult(
      candidates: <EmbySubtitleTrack>[],
      selected: null,
    );
  }

  try {
    final tracks = await EmbyClient(np.account).listSubtitleTracks(np.itemId);
    EmbySubtitleTrack? selected;
    if (currentSelection != null) {
      selected = tracks.firstWhereOrNull(
        (t) =>
            t.index == currentSelection.index &&
            t.mediaSourceId == currentSelection.mediaSourceId,
      );
    }
    return _MobileEmbySubtitleCandidatesResult(
      candidates: tracks,
      selected: selected,
    );
  } catch (_) {
    return const _MobileEmbySubtitleCandidatesResult(
      candidates: <EmbySubtitleTrack>[],
      selected: null,
    );
  }
}
