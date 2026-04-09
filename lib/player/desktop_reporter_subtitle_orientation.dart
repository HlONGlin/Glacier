part of '../video.dart';

extension _DesktopReporterMethods on _VideoPlayerPageState {
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
    final paused = isPaused ?? !_player.state.playing;
    final pos = _player.state.position;

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
      debugPrint('Emby 播放上报失败：${redactSensitiveText(e.toString())}');
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
      await _stopEmbyPlaybackCheckIns(reason: '非 Emby 源');
      return;
    }

    final cur = _embyPlayback;
    if (cur != null &&
        cur.account.id == np.account.id &&
        cur.itemId == np.itemId) {
      _ensureEmbyProgressTimer();
      return;
    }

    await _stopEmbyPlaybackCheckIns(reason: '切换条目');

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
          _buildEmbyCheckInBody(session, isPaused: !_player.state.playing),
        );
      });

      _ensureEmbyProgressTimer();
    } catch (e) {
      debugPrint('Emby 会话创建失败：${redactSensitiveText(e.toString())}');
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
      debugPrint('Emby 停止上报失败：${redactSensitiveText(e.toString())}');
    }
  }

  Future<void> _autoLoadSrtIfAny() async {
    if (!_hasPlaylist) return;
    if (_isWebDavSource(_currentPath)) return;

    await _refreshEmbySubtitleCandidatesIfAny();
    await _refreshSrtCandidates();
    if (_srtCandidates.isEmpty) {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.auto());
      } catch (_) {}
      if (mounted) {
        _srtEnabled = false;
        _srtSelected = null;
        _embySubtitleSelected = null;
        _refreshDesktopState();
      }
      return;
    }
    final base = p.basenameWithoutExtension(_currentPath).toLowerCase();
    var pick = _srtCandidates.first;
    for (final s in _srtCandidates) {
      if (p.basenameWithoutExtension(s).toLowerCase() == base) {
        pick = s;
        break;
      }
    }
    await _applySrt(pick);
  }

  Future<void> _refreshSrtCandidates() async {
    try {
      final p0 = _currentPath.trim();
      if (p0.isEmpty) return;

      final lower = p0.toLowerCase();
      if (lower.startsWith('http://') ||
          lower.startsWith('https://') ||
          lower.startsWith('emby://')) {
        if (mounted) {
          _srtCandidates = <String>[];
          _refreshDesktopState();
        }
        return;
      }

      final f = File(p0);
      final dir = f.parent;
      if (!await dir.exists()) return;

      final base = p.basenameWithoutExtension(f.path).toLowerCase();
      final srts = <String>[];
      await for (final ent in dir.list(followLinks: false)) {
        if (ent is File && ent.path.toLowerCase().endsWith('.srt')) {
          srts.add(ent.path);
        }
      }

      srts.sort((a, b) {
        final aa = p.basenameWithoutExtension(a).toLowerCase();
        final bb = p.basenameWithoutExtension(b).toLowerCase();
        final am = (aa == base);
        final bm = (bb == base);
        if (am != bm) return am ? -1 : 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

      if (mounted) {
        _srtCandidates = srts;
        _refreshDesktopState();
      }
    } catch (_) {}
  }

  Future<void> _applySrt(String? path) async {
    try {
      if (path == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        if (mounted) {
          _srtEnabled = false;
          _srtSelected = null;
          _embySubtitleSelected = null;
          _refreshDesktopState();
        }
      } else {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(File(path).uri.toString(), title: p.basename(path)),
        );
        if (mounted) {
          _srtEnabled = true;
          _srtSelected = path;
          _embySubtitleSelected = null;
          _refreshDesktopState();
        }
      }
    } catch (_) {}

    unawaited(_reportEmbyProgress(
        eventName: 'SubtitleTrackChange', interactive: true));
    _pokeUI();
  }

  Future<void> _applyEmbySubtitle(EmbySubtitleTrack? track) async {
    try {
      if (track == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        if (mounted) {
          _srtEnabled = false;
          _srtSelected = null;
          _embySubtitleSelected = null;
          _refreshDesktopState();
        }
        if (_embyPlayback != null) {
          _embyPlayback!.subtitleStreamIndex = null;
        }
      } else {
        final url = await _buildEmbySubtitleUrl(track);
        if (url == null || url.trim().isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('无法获取 Emby 字幕地址')));
          }
          return;
        }
        await _player
            .setSubtitleTrack(SubtitleTrack.uri(url, title: track.title));
        if (mounted) {
          _srtEnabled = true;
          _srtSelected = null;
          _embySubtitleSelected = track;
          _refreshDesktopState();
        }
        if (_embyPlayback != null) {
          _embyPlayback!.subtitleStreamIndex = track.index;
        }
      }
    } catch (_) {}

    unawaited(_reportEmbyProgress(
        eventName: 'SubtitleTrackChange', interactive: true));
    _pokeUI();
  }

  Future<void> _refreshEmbySubtitleCandidatesIfAny() async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) {
      if (mounted) {
        _embySubtitleCandidates = <EmbySubtitleTrack>[];
        _refreshDesktopState();
      }
      return;
    }

    try {
      final client = EmbyClient(np.account);
      final tracks = await client.listSubtitleTracks(np.itemId);
      if (mounted) {
        _embySubtitleCandidates = tracks;
        _refreshDesktopState();
      }

      if (!_srtEnabled &&
          _srtSelected == null &&
          _embySubtitleSelected == null) {
        final itemId = np.itemId;
        if (_lastAutoSubtitleItemId != itemId) {
          final pick = _pickBestEmbySubtitle(tracks);
          if (pick != null) {
            _lastAutoSubtitleItemId = itemId;
            await _applyEmbySubtitle(pick);
          }
        }
      }
    } catch (_) {
      if (mounted) {
        _embySubtitleCandidates = <EmbySubtitleTrack>[];
        _refreshDesktopState();
      }
    }
  }

  Future<void> _showSrtMenu() async {
    _pokeUI();
    await _refreshEmbySubtitleCandidatesIfAny();
    await _refreshSrtCandidates();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        final items = <Widget>[];
        items.add(ListTile(
          title: const Text('关闭字幕', style: TextStyle(color: Colors.white)),
          trailing: (!_srtEnabled &&
                  _srtSelected == null &&
                  _embySubtitleSelected == null)
              ? const Icon(Icons.check, color: Colors.white)
              : null,
          onTap: () {
            Navigator.pop(ctx);
            _applySrt(null);
          },
        ));
        items.add(ListTile(
          title:
              const Text('自动选择 (内嵌/默认)', style: TextStyle(color: Colors.white)),
          trailing:
              (_srtEnabled == false && _srtSelected == null) ? null : null,
          onTap: () async {
            Navigator.pop(ctx);
            try {
              await _player.setSubtitleTrack(SubtitleTrack.auto());
            } catch (_) {}
            if (mounted) {
              _srtEnabled = false;
              _srtSelected = null;
              _embySubtitleSelected = null;
              _refreshDesktopState();
            }
            _pokeUI();
          },
        ));
        if (_srtCandidates.isNotEmpty) {
          items.add(const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text('同目录 SRT',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ));
          for (final s in _srtCandidates) {
            final selected = (_srtSelected == s);
            items.add(ListTile(
              title: Text(p.basename(s),
                  style: const TextStyle(color: Colors.white)),
              trailing: selected
                  ? const Icon(Icons.check, color: Colors.white)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _applySrt(s);
              },
            ));
          }
        } else {
          final tip = _currentPath.toLowerCase().startsWith('http')
              ? '当前来源为网络播放，无法扫描同目录 .srt（请使用 Emby 字幕轨道）'
              : '当前目录未找到 .srt';
          items.add(Padding(
            padding: const EdgeInsets.all(12),
            child: Text(tip, style: const TextStyle(color: Colors.white70)),
          ));
        }

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
                _applyEmbySubtitle(t);
              },
            ));
          }
        }
        return SafeArea(child: ListView(shrinkWrap: true, children: items));
      },
    );
  }

  void _startAutoRotateIfMobile() {
    if (!_isMobile) return;
    try {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } catch (_) {}

    _nativeOriSub?.cancel();
    _nativeOriSub = NativeDeviceOrientationCommunicator()
        .onOrientationChanged(useSensor: true)
        .listen((ori) {
      if (!_autoRotateEnabled) return;
      if (ori == NativeDeviceOrientation.unknown) return;

      if (_lastOriCandidate == ori) {
        _oriStableCount += 1;
      } else {
        _lastOriCandidate = ori;
        _oriStableCount = 1;
      }
      if (_oriStableCount < 2) return;

      final now = DateTime.now();
      if (now.difference(_lastOriApplyAt).inMilliseconds < 450) return;
      if (_appliedNativeOri == ori) return;

      _appliedNativeOri = ori;
      _lastOriApplyAt = now;
      _applyVideoQuarterTurnsByNativeOri(ori);
      _applyNativeOrientationByChannel(ori);
    });
  }

  void _stopAutoRotateIfAny() {
    _nativeOriSub?.cancel();
    _nativeOriSub = null;
  }

  void _applyVideoQuarterTurnsByNativeOri(NativeDeviceOrientation ori) {
    var turns = 0;
    switch (ori) {
      case NativeDeviceOrientation.landscapeLeft:
        turns = 1;
        break;
      case NativeDeviceOrientation.landscapeRight:
        turns = 3;
        break;
      case NativeDeviceOrientation.portraitDown:
        turns = 2;
        break;
      case NativeDeviceOrientation.portraitUp:
      default:
        turns = 0;
        break;
    }
    if (turns != _videoQuarterTurns && mounted) {
      _videoQuarterTurns = turns;
      _refreshDesktopState();
    }
  }

  Future<void> _applyNativeOrientationByChannel(
      NativeDeviceOrientation ori) async {
    try {
      switch (ori) {
        case NativeDeviceOrientation.landscapeLeft:
        case NativeDeviceOrientation.landscapeRight:
          await _oriChannel.invokeMethod('lockLandscape');
          break;
        case NativeDeviceOrientation.portraitDown:
          await _oriChannel.invokeMethod('lockPortraitUpsideDown');
          break;
        case NativeDeviceOrientation.portraitUp:
        default:
          await _oriChannel.invokeMethod('lockPortrait');
          break;
      }
    } catch (e) {
      debugPrint('原生强制旋转失败：$e');
    }
  }

  Future<void> _unlockNativeOrientation() async {
    try {
      await _oriChannel.invokeMethod('unlock');
    } catch (_) {}
  }
}
