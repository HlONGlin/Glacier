part of '../video.dart';

extension _MobileGestureHandlers on _MobileVideoPlayerPageState {
  void _showGestureOverlay(
    String text,
    IconData icon, {
    Duration ttl = const Duration(milliseconds: 650),
  }) {
    _gestureHideTimer?.cancel();
    if (!mounted) return;
    _setMobileGestureOverlay(active: true, text: text, icon: icon);
    _gestureHideTimer = Timer(ttl, () {
      if (!mounted) return;
      _setMobileGestureOverlay(active: false);
    });
  }

  void _beginGestureOverlay(String text, IconData icon) {
    _gestureHideTimer?.cancel();
    if (!mounted) return;
    _setMobileGestureOverlay(active: true, text: text, icon: icon);
  }

  void _endGestureOverlay() {
    _gestureHideTimer?.cancel();
    _gestureHideTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _setMobileGestureOverlay(active: false);
    });
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _lastDoubleTapPos = details.localPosition;
  }

  Future<void> _onDoubleTap() async {
    if (!_PlayerInteractionPolicy.canUseSeekGestures(
      isScreenLocked: _isScreenLocked,
      lockPauseSeekEnabled: _lockPauseSeekEnabled,
    )) {
      return;
    }
    final pos = _lastDoubleTapPos;
    final box = context.findRenderObject();
    if (pos != null && box is RenderBox) {
      final w = box.size.width;
      final x = pos.dx;
      final secs = _doubleTapSeekSeconds.clamp(5, 60);
      if (x < w * 0.33) {
        await _seekRelative(-secs);
        _showGestureOverlay('-${secs}s', Icons.fast_rewind);
        return;
      }
      if (x > w * 0.67) {
        await _seekRelative(secs);
        _showGestureOverlay('+${secs}s', Icons.fast_forward);
        return;
      }
    }
    await _togglePlayPause();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_PlayerInteractionPolicy.canUseSeekGestures(
      isScreenLocked: _isScreenLocked,
      lockPauseSeekEnabled: _lockPauseSeekEnabled,
    )) {
      return;
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _gestureType = 'seek';
    _dragStartPos = c.value.position;
    _dragTargetPos = _dragStartPos;
    _beginGestureOverlay(_fmt(_dragTargetPos), Icons.fast_forward);
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_gestureType != 'seek') return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final duration = c.value.duration;
    final width = max(1.0, MediaQuery.of(context).size.width);
    const maxJumpMs = 180000.0;
    final deltaMs = (details.delta.dx / width * maxJumpMs).round();
    var target = _dragTargetPos + Duration(milliseconds: deltaMs);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _dragTargetPos = target;
    final diffSec = (_dragTargetPos - _dragStartPos).inSeconds;
    final sign = diffSec >= 0 ? '+' : '';
    final icon = diffSec >= 0 ? Icons.fast_forward : Icons.fast_rewind;
    _beginGestureOverlay('${_fmt(_dragTargetPos)}\n($sign${diffSec}s)', icon);
  }

  Future<void> _onHorizontalDragEnd(DragEndDetails details) async {
    if (_gestureType != 'seek') return;
    _gestureType = '';
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        await c.seekTo(_dragTargetPos);
        unawaited(
          _reportEmbyProgress(eventName: 'TimeUpdate', interactive: true),
        );
      } catch (_) {}
    }
    _scheduleAutoHide();
    _endGestureOverlay();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (!_PlayerInteractionPolicy.canUseVerticalGestures(
      isScreenLocked: _isScreenLocked,
    )) {
      return;
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final width = MediaQuery.of(context).size.width;
    final onRight = details.localPosition.dx >= width * 0.5;
    _gestureType = onRight ? 'volume' : 'brightness';
    if (onRight) {
      _beginGestureOverlay('${_volume.round()}%', Icons.volume_up);
    } else {
      _beginGestureOverlay(
        '${(_brightness * 100).round()}%',
        Icons.brightness_6,
      );
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_gestureType != 'volume' && _gestureType != 'brightness') return;
    final h = max(1.0, MediaQuery.of(context).size.height);
    final ratio = -details.delta.dy / h;
    if (_gestureType == 'volume') {
      _volume = (_volume + ratio * 140).clamp(0.0, 100.0);
      final c = _controller;
      if (c != null && c.value.isInitialized) {
        unawaited(c.setVolume((_volume / 100).clamp(0, 1).toDouble()));
      }
      final icon = _volume == 0
          ? Icons.volume_mute
          : (_volume < 50 ? Icons.volume_down : Icons.volume_up);
      _beginGestureOverlay('${_volume.round()}%', icon);
      return;
    }
    _brightness = (_brightness + ratio * 1.2).clamp(0.0, 1.0);
    _beginGestureOverlay('${(_brightness * 100).round()}%', Icons.brightness_6);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final wasVolume = _gestureType == 'volume';
    _gestureType = '';
    _refreshMobileState();
    _endGestureOverlay();
    if (wasVolume) {
      unawaited(
        _reportEmbyProgress(eventName: 'TimeUpdate', interactive: true),
      );
    }
  }

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    if (!_PlayerInteractionPolicy.canUseLongPressSpeed(
      isScreenLocked: _isScreenLocked,
      longPressSpeedEnabled: _longPressSpeedEnabled,
    )) {
      return;
    }
    if (_rateBeforeLongPress != null) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _rateBeforeLongPress = _rate;
    final boosted = (_rate * _longPressSpeedMultiplier).clamp(0.25, 3.0);
    await _setPlaybackRate(boosted);
    _beginGestureOverlay(
      '${boosted.toStringAsFixed((boosted % 1) == 0 ? 0 : 2)}x',
      Icons.speed,
    );
  }

  Future<void> _onLongPressEnd(LongPressEndDetails details) async {
    final prev = _rateBeforeLongPress;
    _rateBeforeLongPress = null;
    if (prev == null) return;
    await _setPlaybackRate(prev);
    _endGestureOverlay();
  }

  void _scheduleLockButtonAutoHide() {
    _lockButtonHideTimer?.cancel();
    if (!_isScreenLocked || !_lockButtonVisible) return;
    _lockButtonHideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || !_isScreenLocked) return;
      _lockButtonVisible = false;
      _refreshMobileState();
    });
  }

  void _toggleScreenLock() {
    if (!mounted) return;
    final nextLocked = !_isScreenLocked;
    _isScreenLocked = nextLocked;
    _lockButtonVisible = true;
    if (nextLocked) {
      _controlsVisible = false;
    }
    _refreshMobileState();
    if (_isScreenLocked) {
      _hideTimer?.cancel();
      _autoRotateEnabled = false;
      _stopAutoRotateIfAny();
      final isLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;
      unawaited(
        () async {
          if (isLandscape) {
            try {
              await _mobileOriChannel.invokeMethod('lockLandscape');
            } catch (_) {}
            await SystemChrome.setPreferredOrientations(const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          } else {
            try {
              await _mobileOriChannel.invokeMethod('lockPortrait');
            } catch (_) {}
            await SystemChrome.setPreferredOrientations(const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ]);
          }
        }(),
      );
      _scheduleLockButtonAutoHide();
      _showGestureOverlay('方向已锁定', Icons.screen_lock_rotation);
      return;
    }

    _lockButtonHideTimer?.cancel();
    _autoRotateEnabled = true;
    _lastOriCandidate = null;
    _oriStableCount = 0;
    _lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);
    _appliedNativeOri = NativeDeviceOrientation.unknown;
    unawaited(() async {
      try {
        await _mobileOriChannel.invokeMethod('unlock');
      } catch (_) {}
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }());
    Future<void>.delayed(const Duration(milliseconds: 220), () async {
      if (!mounted || _isScreenLocked) return;
      _startAutoRotateIfMobile();
      await _syncOrientationFromSensor(force: true);
    });
    _showGestureOverlay('方向已解锁', Icons.screen_rotation);
    _scheduleAutoHide();
  }

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    if (_isScreenLocked) return;
    if (!_controlsVisible) return;
    final c = _controller;
    if (c == null || !c.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _controlsVisible = false;
      _refreshMobileState();
    });
  }

  void _toggleControls() {
    if (_isScreenLocked) {
      _lockButtonVisible = !_lockButtonVisible;
      _refreshMobileState();
      _scheduleLockButtonAutoHide();
      return;
    }
    _controlsVisible = !_controlsVisible;
    _refreshMobileState();
    _scheduleAutoHide();
  }
}

extension _DesktopGestureHandlers on _VideoPlayerPageState {
  Future<void> _adjustVolume(double delta) async {
    _volume = (_volume + delta).clamp(0, 100);
    _player.setVolume(_volume);
    _pokeUI();
    if (!mounted) return;
    _refreshDesktopGestureState();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_ready) return;
    _gestureActive = true;
    _gestureType = 'seek';
    _dragStartPos = _player.state.position;
    _dragTargetPos = _dragStartPos;
    if (!mounted) return;
    _refreshDesktopGestureState();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_PlayerInteractionPolicy.canUseSeekGestures(
      isScreenLocked: _isScreenLocked,
      lockPauseSeekEnabled: false,
    )) {
      return;
    }
    if (!_ready) return;
    final deltaMs = (details.delta.dx * 600).toInt();
    final duration = _player.state.duration;

    var newPosMs = _dragTargetPos.inMilliseconds + deltaMs;
    newPosMs = newPosMs.clamp(0, duration.inMilliseconds);
    _dragTargetPos = Duration(milliseconds: newPosMs);

    final diff = _dragTargetPos - _dragStartPos;
    final sign = diff.isNegative ? '-' : '+';
    final diffSec = diff.inSeconds.abs();

    _gestureIcon = diff.isNegative ? Icons.fast_rewind : Icons.fast_forward;
    _gestureText = '${_fmt(_dragTargetPos)}\n($sign${diffSec}s)';
    if (!mounted) return;
    _refreshDesktopGestureState();
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_ready) return;
    _player.seek(_dragTargetPos);
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
    Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _gestureActive = false;
      _refreshDesktopGestureState();
    });
    _uiVisible ? _pokeUI() : null;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (!_PlayerInteractionPolicy.canUseVerticalGestures(
      isScreenLocked: _isScreenLocked,
    )) {
      return;
    }
    if (!_ready) return;
    final width = MediaQuery.of(context).size.width;
    _gestureActive = true;

    if (details.globalPosition.dx > width / 2) {
      _gestureType = 'volume';
      _gestureIcon = Icons.volume_up;
    } else {
      _gestureType = 'brightness';
      _gestureIcon = Icons.brightness_6;
    }
    if (!mounted) return;
    _refreshDesktopGestureState();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_isScreenLocked) return;
    if (!_ready) return;
    final delta = -details.delta.dy;

    if (_gestureType == 'volume') {
      final step = delta * 0.5;
      _volume = (_volume + step).clamp(0.0, 100.0);
      _player.setVolume(_volume);
      _gestureText = '${_volume.toInt()}%';
      if (_volume == 0) {
        _gestureIcon = Icons.volume_mute;
      } else if (_volume < 50) {
        _gestureIcon = Icons.volume_down;
      } else {
        _gestureIcon = Icons.volume_up;
      }
    } else {
      final step = delta / 200.0;
      _brightness = (_brightness + step).clamp(0.0, 1.0);
      _gestureText = '${(_brightness * 100).toInt()}%';
    }
    if (!mounted) return;
    _refreshDesktopGestureState();
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _gestureActive = false;
      _refreshDesktopGestureState();
    });
    _uiVisible ? _pokeUI() : null;
  }
}
