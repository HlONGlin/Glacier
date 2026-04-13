part of '../video.dart';

extension _MobileReporterMethods on _MobileVideoPlayerPageState {
  int _toEmbyTicks(Duration d) {
    final us = d.inMicroseconds;
    if (us <= 0) return 0;
    return us * 10;
  }

  Map<String, dynamic> _buildEmbyCheckInBody(
    _EmbyPlaybackSession s, {
    String? eventName,
    bool? isPaused,
  }) {
    final c = _controller;
    final v = c?.value;
    final paused = isPaused ?? !(v?.isPlaying ?? false);
    final pos = v?.position ?? Duration.zero;

    final body = <String, dynamic>{
      'QueueableMediaTypes': const ['Video'],
      'CanSeek': true,
      'ItemId': s.itemId,
      'MediaSourceId': s.mediaSourceId,
      if (s.audioStreamIndex != null) 'AudioStreamIndex': s.audioStreamIndex,
      if (s.subtitleStreamIndex != null)
        'SubtitleStreamIndex': s.subtitleStreamIndex,
      'IsPaused': paused,
      'IsMuted': _volume <= 0,
      'PositionTicks': _toEmbyTicks(pos),
      'VolumeLevel': _volume.round().clamp(0, 100),
      'PlayMethod': 'DirectStream',
      'PlaySessionId': s.playSessionId,
      'PlaylistIndex': _index,
      'PlaylistLength': max(1, _sources.length),
      'PlaybackRate': _rate,
    };
    if (eventName != null && eventName.trim().isNotEmpty) {
      body['EventName'] = eventName.trim();
    }
    return body;
  }

  Future<void> _enqueueEmbyReport(Future<void> Function() job) {
    _embyReportQueue = _embyReportQueue.then((_) => job()).catchError((e) {
      debugPrint(
          'Mobile Emby report failed: ${redactSensitiveText(e.toString())}');
    });
    return _embyReportQueue;
  }

  void _ensureEmbyProgressTimer() {
    if (_embyPlayback == null) return;
    _embyProgressTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_reportEmbyProgress(eventName: 'TimeUpdate'));
    });
  }

  Future<void> _startEmbyPlaybackCheckInsIfNeeded({String reason = ''}) async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) {
      await _stopEmbyPlaybackCheckIns(reason: 'non emby source');
      return;
    }

    final cur = _embyPlayback;
    if (cur != null &&
        cur.account.id == np.account.id &&
        cur.itemId == np.itemId) {
      _ensureEmbyProgressTimer();
      return;
    }

    await _stopEmbyPlaybackCheckIns(reason: 'switch item');

    try {
      final client = EmbyClient(np.account);
      final pb = await client.playbackInfo(np.itemId);
      if (pb == null) return;

      final session = _EmbyPlaybackSession(
        account: np.account,
        itemId: np.itemId,
        mediaSourceId: pb.mediaSourceId,
        playSessionId: pb.playSessionId,
        audioStreamIndex: pb.audioStreamIndex,
        subtitleStreamIndex: pb.subtitleStreamIndex,
      );
      _embyPlayback = session;

      await _enqueueEmbyReport(() async {
        await client.reportPlaybackStarted(
          _buildEmbyCheckInBody(
            session,
            isPaused: !(_controller?.value.isPlaying ?? false),
          ),
        );
      });

      _ensureEmbyProgressTimer();
    } catch (e) {
      debugPrint(
        'Mobile Emby session start failed: ${redactSensitiveText(e.toString())}',
      );
    }
  }

  Future<void> _reportEmbyProgress({
    required String eventName,
    bool interactive = false,
  }) async {
    final s = _embyPlayback;
    if (s == null) return;

    if (interactive) {
      final now = DateTime.now();
      if (now.difference(_embyLastInteractiveReportAt).inMilliseconds < 650) {
        return;
      }
      _embyLastInteractiveReportAt = now;
    }

    final client = EmbyClient(s.account);
    final body = _buildEmbyCheckInBody(s, eventName: eventName);
    await _enqueueEmbyReport(() async {
      await client.reportPlaybackProgress(body);
    });
  }

  Future<void> _stopEmbyPlaybackCheckIns({String reason = ''}) async {
    _embyProgressTimer?.cancel();
    _embyProgressTimer = null;

    final s = _embyPlayback;
    _embyPlayback = null;
    if (s == null) return;

    try {
      final client = EmbyClient(s.account);
      await _enqueueEmbyReport(() async {
        await client.reportPlaybackStopped(
          _buildEmbyCheckInBody(s, isPaused: true),
        );
      });
    } catch (e) {
      debugPrint(
        'Mobile Emby session stop failed: ${redactSensitiveText(e.toString())}',
      );
    }
  }

  void _startAutoRotateIfMobile() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _nativeOriSub?.cancel();
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(_syncOrientationFromSensor(force: true));
    _nativeOriSub = NativeDeviceOrientationCommunicator()
        .onOrientationChanged(useSensor: true)
        .listen((ori) {
      if (!_autoRotateEnabled || _isScreenLocked) return;
      if (ori == NativeDeviceOrientation.unknown) return;

      if (_lastOriCandidate == ori) {
        _oriStableCount += 1;
      } else {
        _lastOriCandidate = ori;
        _oriStableCount = 1;
      }
      if (_oriStableCount < 1) return;

      final now = DateTime.now();
      if (now.difference(_lastOriApplyAt).inMilliseconds < 180) return;
      if (_appliedNativeOri == ori) return;
      _appliedNativeOri = ori;
      _lastOriApplyAt = now;
      unawaited(_applyPreferredOrientationByOri(ori));
    });
  }

  Future<void> _syncOrientationFromSensor({bool force = false}) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    if (!_autoRotateEnabled || _isScreenLocked) return;
    try {
      final ori = await NativeDeviceOrientationCommunicator()
          .orientation(useSensor: true);
      if (ori == NativeDeviceOrientation.unknown) return;
      _lastOriCandidate = ori;
      _oriStableCount = 2;
      if (!force && _appliedNativeOri == ori) return;
      _appliedNativeOri = ori;
      _lastOriApplyAt = DateTime.now();
      await _applyPreferredOrientationByOri(ori);
    } catch (_) {}
  }

  void _stopAutoRotateIfAny() {
    _nativeOriSub?.cancel();
    _nativeOriSub = null;
  }

  Future<void> _applyPreferredOrientationByOri(
    NativeDeviceOrientation ori,
  ) async {
    try {
      switch (ori) {
        case NativeDeviceOrientation.landscapeLeft:
        case NativeDeviceOrientation.landscapeRight:
          try {
            await _mobileOriChannel.invokeMethod('lockLandscape');
          } catch (_) {}
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          break;
        case NativeDeviceOrientation.portraitDown:
          try {
            await _mobileOriChannel.invokeMethod('lockPortraitUpsideDown');
          } catch (_) {}
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
          break;
        case NativeDeviceOrientation.portraitUp:
        default:
          try {
            await _mobileOriChannel.invokeMethod('lockPortrait');
          } catch (_) {}
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
          break;
      }
    } catch (_) {}
  }

  Future<void> _applySubtitleOff({bool report = true}) async {
    try {
      await _controller?.setClosedCaptionFile(null);
    } catch (_) {}
    _localSubtitleSelected = null;
    _embySubtitleSelected = null;
    if (_embyPlayback != null) {
      _embyPlayback!.subtitleStreamIndex = null;
    }
    _refreshMobileState();
    if (report) {
      unawaited(
        _reportEmbyProgress(
            eventName: 'SubtitleTrackChange', interactive: true),
      );
    }
  }

  Future<void> _applyLocalSubtitle(String path, {bool report = true}) async {
    try {
      final bytes = await File(path).readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      final ext = p.extension(path).toLowerCase();
      final file =
          (ext == '.vtt') ? WebVTTCaptionFile(text) : SubRipCaptionFile(text);
      await _controller?.setClosedCaptionFile(Future.value(file));
      _localSubtitleSelected = path;
      _embySubtitleSelected = null;
      if (_embyPlayback != null) {
        _embyPlayback!.subtitleStreamIndex = null;
      }
      _refreshMobileState();
      if (report) {
        unawaited(_reportEmbyProgress(
            eventName: 'SubtitleTrackChange', interactive: true));
      }
    } catch (e) {
      _showSnack('加载字幕失败：${redactSensitiveText(e.toString())}');
    }
  }

  Future<void> _applyEmbySubtitle(
    EmbySubtitleTrack track, {
    bool report = true,
  }) async {
    try {
      final url = await _buildEmbySubtitleUrl(track);
      if (url == null || url.trim().isEmpty) {
        _showSnack('无法获取 Emby 字幕地址');
        return;
      }
      final text = await _downloadText(Uri.parse(url));
      final file = SubRipCaptionFile(text);
      await _controller?.setClosedCaptionFile(Future.value(file));
      _embySubtitleSelected = track;
      _localSubtitleSelected = null;
      if (_embyPlayback != null) {
        _embyPlayback!.subtitleStreamIndex = track.index;
      }
      _refreshMobileState();
      if (report) {
        unawaited(_reportEmbyProgress(
            eventName: 'SubtitleTrackChange', interactive: true));
      }
    } catch (e) {
      _showSnack('加载 Emby 字幕失败：${redactSensitiveText(e.toString())}');
    }
  }

  Future<void> _prepareSubtitleForCurrent() async {
    await _refreshSubtitleCandidates();
    if (!mounted) return;
    final key = await (() async {
      final np = await _resolveEmbyNowPlaying(_currentPath);
      if (np != null) return 'emby:${np.account.id}:${np.itemId}';
      return 'path:$_currentPath';
    })();
    if (_lastAutoSubtitleKey == key) return;

    if (_embySubtitleCandidates.isNotEmpty && _embySubtitleSelected == null) {
      final pick = _pickBestEmbySubtitle(_embySubtitleCandidates);
      if (pick != null) {
        _lastAutoSubtitleKey = key;
        await _applyEmbySubtitle(pick, report: false);
        return;
      }
    }

    if (_localSubtitleCandidates.isNotEmpty && _localSubtitleSelected == null) {
      var pick = _localSubtitleCandidates.first;
      final base = p.basenameWithoutExtension(_currentPath).toLowerCase();
      for (final s in _localSubtitleCandidates) {
        if (p.basenameWithoutExtension(s).toLowerCase() == base) {
          pick = s;
          break;
        }
      }
      _lastAutoSubtitleKey = key;
      await _applyLocalSubtitle(pick, report: false);
    }
  }

  Future<void> _showSubtitleMenu() async {
    await _refreshSubtitleCandidates();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        final items = <Widget>[
          ListTile(
            title: const Text('关闭字幕', style: TextStyle(color: Colors.white)),
            trailing: (_localSubtitleSelected == null &&
                    _embySubtitleSelected == null)
                ? const Icon(Icons.check, color: Colors.white)
                : null,
            onTap: () {
              Navigator.pop(ctx);
              unawaited(_applySubtitleOff());
            },
          ),
        ];

        if (_embySubtitleCandidates.isNotEmpty) {
          items.add(const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text('Emby 字幕',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ));
          for (final t in _embySubtitleCandidates) {
            final selected = (_embySubtitleSelected?.index == t.index) &&
                (_embySubtitleSelected?.mediaSourceId == t.mediaSourceId);
            items.add(ListTile(
              title: Text(t.title, style: const TextStyle(color: Colors.white)),
              trailing: selected
                  ? const Icon(Icons.check, color: Colors.white)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_applyEmbySubtitle(t));
              },
            ));
          }
        }

        if (_localSubtitleCandidates.isNotEmpty) {
          items.add(const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text('本地字幕',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ));
          for (final pth in _localSubtitleCandidates) {
            final selected = (_localSubtitleSelected == pth);
            items.add(ListTile(
              title: Text(
                p.basename(pth),
                style: const TextStyle(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: selected
                  ? const Icon(Icons.check, color: Colors.white)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_applyLocalSubtitle(pth));
              },
            ));
          }
        }

        if (_embySubtitleCandidates.isEmpty &&
            _localSubtitleCandidates.isEmpty) {
          items.add(const Padding(
            padding: EdgeInsets.all(12),
            child: Text('未找到可用字幕', style: TextStyle(color: Colors.white70)),
          ));
        }
        return SafeArea(child: ListView(shrinkWrap: true, children: items));
      },
    );
  }
}
