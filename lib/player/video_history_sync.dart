part of '../video.dart';

extension _DesktopVideoHistorySync on _VideoPlayerPageState {
  void _armHistoryRecordForCurrent() {
    try {
      final p = _currentPath.trim();
      if (p.isEmpty) return;
      _historyArmedPath = p;
      _historyArmed = true;
    } catch (_) {
      // 忽略：历史记录是“锦上添花”，不阻断播放。
    }
  }

  void _tryCommitHistoryRecord(Duration pos) {
    if (!_historyArmed) return;
    final path = (_historyArmedPath ?? '').trim();
    if (path.isEmpty) {
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_historyLastCommitPath == path && (now - _historyLastCommitAt) < 2500) {
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }

    final playing = _player.state.playing;
    if (!playing) return;
    if (pos.inMilliseconds < _VideoPlayerPageState._historyMinPlayMs) return;

    _historyLastCommitAt = now;
    _historyLastCommitPath = path;
    _historyArmed = false;
    _historyArmedPath = null;
    _recordHistoryForPath(path);
  }

  Future<void> _recordHistoryForPath(String path) async {
    try {
      final p0 = path.trim();
      if (p0.isEmpty) return;
      await PlayerHistoryService.upsertMediaHistory(p0);
    } catch (_) {
      // 历史记录失败不应影响播放。
    }
  }
}

extension _MobileVideoHistorySync on _MobileVideoPlayerPageState {
  void _armHistoryRecordForCurrent() {
    try {
      final path = _currentPath.trim();
      if (path.isEmpty) return;
      _historyArmedPath = path;
      _historyArmed = true;
    } catch (_) {}
  }

  Future<void> _upsertHistoryForCurrent({int? positionMs}) async {
    try {
      final path = _currentPath.trim();
      if (path.isEmpty) return;

      _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
      await PlayerHistoryService.upsertMediaHistory(
        path,
        positionMs: positionMs,
        embyAccounts: _embyAccounts,
      );
    } catch (_) {}
  }

  void _tryCommitHistoryRecord({
    required Duration position,
    required bool playing,
  }) {
    if (!_historyArmed) return;
    final path = (_historyArmedPath ?? '').trim();
    if (path.isEmpty) {
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }
    if (!playing) return;
    if (position.inMilliseconds <
        _MobileVideoPlayerPageState._historyMinPlayMs) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_historyLastCommitPath == path && (now - _historyLastCommitAt) < 2500) {
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }
    _historyLastCommitPath = path;
    _historyLastCommitAt = now;
    _historyArmed = false;
    _historyArmedPath = null;
    unawaited(_upsertHistoryForCurrent(positionMs: position.inMilliseconds));
  }

  Future<void> _flushHistoryProgress() async {
    try {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final path = _currentPath.trim();
      if (path.isEmpty) return;
      await PlayerHistoryService.updateHistoryProgress(
        path,
        positionMs: c.value.position.inMilliseconds.clamp(0, 0x7fffffff),
      );
    } catch (_) {}
  }
}
