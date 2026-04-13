part of '../video.dart';

class _MobileVideoPlayerPageState extends State<_MobileVideoPlayerHost>
    with WidgetsBindingObserver {
  late final List<String> _sources;
  late final player_presentation.PlayerController _pageController;
  int _index = 0;

  VideoPlayerController? _controller;
  int _openSeq = 0;
  bool _opening = false;
  String? _error;
  String _title = '视频播放';

  bool _draggingSeek = false;
  double _dragSeekMs = 0;
  bool _endHandled = false;
  double _rate = 1.0;
  double _volume = 100.0;
  bool _autoNextAfterEnd = false;
  bool _videoResumeEnabled = true;
  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  int _doubleTapSeekSeconds = 10;
  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;
  double _subtitleBackgroundOpacity = 0.55;
  bool _subtitleOutlineEnabled = true;
  bool _showMiniProgressWhenHidden = true;
  bool _videoCatalogEnabled = true;
  bool _videoEpisodeNavButtonsEnabled = true;
  bool _lockPauseSeekEnabled = true;
  bool _catalogLocateCurrentOnOpen = true;
  double _brightness = 1.0;
  StreamSubscription<NativeDeviceOrientation>? _nativeOriSub;
  final MethodChannel _mobileOriChannel =
      const MethodChannel('glacier/orientation');
  bool _allowRoutePopOnce = false;

  bool get _canOpenCatalogMenu => _PlayerInteractionPolicy.canOpenCatalog(
        hasPlaylist: _hasPlaylist,
        isScreenLocked: _isScreenLocked,
        catalogEnabled: _videoCatalogEnabled,
        menuAlreadyOpen: _catalogMenuOpen,
      );
  Timer? _gestureHideTimer;
  Timer? _lockButtonHideTimer;
  Timer? _resumeHintForceHideTimer;
  int _resumeHintSerial = 0;
  bool _resumeHintVisible = false;
  String _resumeHintText = '';
  bool _exitCleanupDone = false;
  String _openingLabel =
      PlayerUiTextService.openingLabel(hasExistingController: false);
  final ValueNotifier<_MobileHudViewData> _mobileHudNotifier =
      ValueNotifier<_MobileHudViewData>(const _MobileHudViewData.initial());

  static const int _historyMinPlayMs = 800;
  int _historyLastCommitAt = 0;
  String _historyLastCommitPath = '';
  String? _historyArmedPath;
  bool _historyArmed = false;

  Map<String, Map<String, String>>? _webDavAccounts;
  Map<String, EmbyAccount>? _embyAccounts;
  Future<Map<String, EmbyAccount>>? _embyAccountMapFuture;

  bool get _hasPlaylist => _sources.isNotEmpty;
  String get _currentPath => _hasPlaylist ? _sources[_index] : '';
  bool get _canPrev => _index > 0;
  bool get _canNext => _index < _sources.length - 1;

  final _MobileOrientationState _orientationState = _MobileOrientationState();
  final _MobileGestureState _gestureState = _MobileGestureState();
  final ValueNotifier<_MobileGestureOverlayViewData> _gestureOverlayNotifier =
      ValueNotifier<_MobileGestureOverlayViewData>(
          const _MobileGestureOverlayViewData.inactive());
  final _MobileReporterState _reporterState = _MobileReporterState();
  final _MobileSubtitleState _subtitleState = _MobileSubtitleState();

  bool get _isScreenLocked => _orientationState.isScreenLocked;
  set _isScreenLocked(bool value) => _orientationState.isScreenLocked = value;

  bool get _autoRotateEnabled => _orientationState.autoRotateEnabled;
  set _autoRotateEnabled(bool value) =>
      _orientationState.autoRotateEnabled = value;

  NativeDeviceOrientation get _appliedNativeOri =>
      _orientationState.appliedNativeOri;
  set _appliedNativeOri(NativeDeviceOrientation value) =>
      _orientationState.appliedNativeOri = value;

  NativeDeviceOrientation? get _lastOriCandidate =>
      _orientationState.lastOriCandidate;
  set _lastOriCandidate(NativeDeviceOrientation? value) =>
      _orientationState.lastOriCandidate = value;

  int get _oriStableCount => _orientationState.oriStableCount;
  set _oriStableCount(int value) => _orientationState.oriStableCount = value;

  DateTime get _lastOriApplyAt => _orientationState.lastOriApplyAt;
  set _lastOriApplyAt(DateTime value) =>
      _orientationState.lastOriApplyAt = value;

  String get _gestureType => _gestureState.type;
  set _gestureType(String value) => _gestureState.type = value;

  String get _gestureText => _gestureState.text;
  set _gestureText(String value) => _gestureState.text = value;

  IconData? get _gestureIcon => _gestureState.icon;
  set _gestureIcon(IconData? value) => _gestureState.icon = value;

  Offset? get _lastDoubleTapPos => _gestureState.lastDoubleTapPos;
  set _lastDoubleTapPos(Offset? value) =>
      _gestureState.lastDoubleTapPos = value;

  Duration get _dragStartPos => _gestureState.dragStartPos;
  set _dragStartPos(Duration value) => _gestureState.dragStartPos = value;

  Duration get _dragTargetPos => _gestureState.dragTargetPos;
  set _dragTargetPos(Duration value) => _gestureState.dragTargetPos = value;

  double? get _rateBeforeLongPress => _gestureState.rateBeforeLongPress;
  set _rateBeforeLongPress(double? value) =>
      _gestureState.rateBeforeLongPress = value;

  _EmbyPlaybackSession? get _embyPlayback => _reporterState.embyPlayback;
  set _embyPlayback(_EmbyPlaybackSession? value) =>
      _reporterState.embyPlayback = value;

  Timer? get _embyProgressTimer => _reporterState.embyProgressTimer;
  set _embyProgressTimer(Timer? value) =>
      _reporterState.embyProgressTimer = value;

  Future<void> get _embyReportQueue => _reporterState.embyReportQueue;
  set _embyReportQueue(Future<void> value) =>
      _reporterState.embyReportQueue = value;

  DateTime get _embyLastInteractiveReportAt =>
      _reporterState.embyLastInteractiveReportAt;
  set _embyLastInteractiveReportAt(DateTime value) =>
      _reporterState.embyLastInteractiveReportAt = value;

  List<EmbySubtitleTrack> get _embySubtitleCandidates =>
      _subtitleState.embySubtitleCandidates;
  set _embySubtitleCandidates(List<EmbySubtitleTrack> value) =>
      _subtitleState.embySubtitleCandidates = value;

  EmbySubtitleTrack? get _embySubtitleSelected =>
      _subtitleState.embySubtitleSelected;
  set _embySubtitleSelected(EmbySubtitleTrack? value) =>
      _subtitleState.embySubtitleSelected = value;

  List<String> get _localSubtitleCandidates =>
      _subtitleState.localSubtitleCandidates;
  set _localSubtitleCandidates(List<String> value) =>
      _subtitleState.localSubtitleCandidates = value;

  String? get _localSubtitleSelected => _subtitleState.localSubtitleSelected;
  set _localSubtitleSelected(String? value) =>
      _subtitleState.localSubtitleSelected = value;

  String? get _lastAutoSubtitleKey => _subtitleState.lastAutoSubtitleKey;
  set _lastAutoSubtitleKey(String? value) =>
      _subtitleState.lastAutoSubtitleKey = value;

  bool get _controlsVisible => _pageController.controlsVisible;
  bool get _catalogMenuOpen => _pageController.catalogMenuOpen;
  bool get _lockButtonVisible => _pageController.lockButtonVisible;

  void _onAppSettingsChanged() {
    unawaited(_loadMobileSettings());
  }

  void _onPageControllerChanged() {
    _refreshMobileState();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = player_presentation.PlayerController()
      ..addListener(_onPageControllerChanged);
    AppSettings.instance.addListener(_onAppSettingsChanged);
    _sources = List<String>.from(widget.videoPaths);
    if (_sources.isNotEmpty) {
      _index = widget.initialIndex.clamp(0, _sources.length - 1);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(_kLightStatusBarStyle);
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    _startAutoRotateIfMobile();
    unawaited(_loadMobileSettings());
    unawaited(_openCurrent(autoPlay: true));
  }

  Future<void> _loadMobileSettings() async {
    try {
      final values = await _loadMobileVideoSettingsValues();
      if (!mounted) return;
      setState(() {
        _subtitleFontSize = values.subtitleFont.clamp(12.0, 48.0);
        _subtitleBottomOffset = values.subtitleBottom.clamp(0.0, 200.0);
        _subtitleBackgroundOpacity =
            values.subtitleBackgroundOpacity.clamp(0.0, 1.0);
        _subtitleOutlineEnabled = values.subtitleOutlineEnabled;
        _longPressSpeedEnabled = values.longPressEnabled;
        _longPressSpeedMultiplier = values.longPressMultiplier;
        _autoNextAfterEnd = values.autoNext;
        _videoResumeEnabled = values.resumeEnabled;
        _showMiniProgressWhenHidden = values.miniProgress;
        _videoCatalogEnabled = values.catalogEnabled;
        _videoEpisodeNavButtonsEnabled = values.episodeNavButtonsEnabled;
        _lockPauseSeekEnabled = values.lockPauseSeekEnabled;
        _catalogLocateCurrentOnOpen = values.catalogLocateCurrentOnOpen;
        _doubleTapSeekSeconds = values.doubleTapSeekSeconds.clamp(5, 60);
      });
    } catch (_) {}
  }

  Future<void> _refreshEmbySubtitleCandidatesIfAny() async {
    final result = await _loadMobileEmbySubtitleCandidates(
      currentPath: _currentPath,
      currentSelection: _embySubtitleSelected,
      loadAccountMap: () async {
        _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
        return _embyAccounts!;
      },
      resolveAccountForStream: _resolveEmbyAccountForStream,
    );
    _embySubtitleCandidates = result.candidates;
    _embySubtitleSelected = result.selected;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_controller?.pause());
      unawaited(_reportEmbyProgress(eventName: 'Pause'));
      unawaited(_flushHistoryProgress());
      return;
    }
    if (state == AppLifecycleState.resumed && !_isScreenLocked) {
      _startAutoRotateIfMobile();
      unawaited(_syncOrientationFromSensor(force: true));
    }
  }

  @override
  void dispose() {
    unawaited(_stopEmbyPlaybackCheckIns(reason: 'mobile dispose'));
    unawaited(_flushHistoryProgress());
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    _gestureHideTimer?.cancel();
    _lockButtonHideTimer?.cancel();
    _pageController.cancelAutoHide();
    _pageController.cancelDesktopUiHide();
    _pageController.cancelDesktopCursorHide();
    _dismissResumeHint(clearBinding: true);
    _stopAutoRotateIfAny();
    _autoRotateEnabled = false;
    _appliedNativeOri = NativeDeviceOrientation.unknown;
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerTick);
    unawaited(c?.pause());
    unawaited(c?.dispose());
    unawaited(_mobileOriChannel.invokeMethod('unlock').catchError((_) {}));
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_kDarkStatusBarStyle);
    _pageController
      ..removeListener(_onPageControllerChanged)
      ..dispose();
    _gestureOverlayNotifier.dispose();
    _mobileHudNotifier.dispose();
    super.dispose();
  }

  Future<void> _showResumeHint(int resumedMs, String sourcePath) async {
    if (resumedMs < 5000) return;
    if (!_videoResumeEnabled) return;
    var hintEnabled = true;
    try {
      hintEnabled = await AppSettings.getVideoResumeHintEnabled();
    } catch (_) {}
    if (!hintEnabled) return;
    if (!mounted) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _dismissResumeHint(bumpSerial: false);
    final serial = ++_resumeHintSerial;
    setState(() {
      _resumeHintVisible = true;
      _resumeHintText = PlayerUiTextService.resumeHintText(
        Duration(milliseconds: resumedMs),
      );
    });
    _resumeHintForceHideTimer = Timer(const Duration(milliseconds: 3050), () {
      if (!mounted) return;
      if (serial != _resumeHintSerial) return;
      if (_currentPath.trim() != sourcePath.trim()) return;
      _dismissResumeHint(bumpSerial: false);
    });
  }

  void _dismissResumeHint({bool bumpSerial = true, bool clearBinding = false}) {
    if (bumpSerial) _resumeHintSerial++;
    _resumeHintForceHideTimer?.cancel();
    _resumeHintForceHideTimer = null;

    _resumeHintVisible = false;
    _resumeHintText = '';
    if (clearBinding) return;

    if (mounted) {
      setState(() {});
    }
  }

  Future<Map<String, EmbyAccount>> _ensureEmbyAccounts() async {
    final cached = _embyAccounts;
    if (cached != null) return cached;
    final loaded = await (_embyAccountMapFuture ??=
        PlayerSourceResolver.loadEmbyAccountMap());
    _embyAccounts = loaded;
    return loaded;
  }

  _EmbyRef? _parseEmbyRef(String source) {
    final parsed = parseEmbySourceRef(source);
    if (parsed == null) return null;
    return _EmbyRef(accountId: parsed.accountId, itemId: parsed.itemId);
  }

  bool _looksLikeLocalFilePath(String s) =>
      PlayerLocalSubtitleService.looksLikeLocalFilePath(s);

  Future<void> _refreshLocalSubtitleCandidatesIfAny() async {
    if (!_looksLikeLocalFilePath(_currentPath)) {
      _localSubtitleCandidates = <String>[];
      _localSubtitleSelected = null;
      if (mounted) setState(() {});
      return;
    }
    try {
      final subs = await PlayerLocalSubtitleService.listSubtitleCandidates(
        _currentPath,
      );
      _localSubtitleCandidates = subs;
      if (_localSubtitleSelected != null &&
          !subs.contains(_localSubtitleSelected)) {
        _localSubtitleSelected = null;
      }
      if (mounted) setState(() {});
    } catch (_) {
      _localSubtitleCandidates = <String>[];
      _localSubtitleSelected = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshSubtitleCandidates() async {
    await _refreshEmbySubtitleCandidatesIfAny();
    await _refreshLocalSubtitleCandidatesIfAny();
  }

  Future<String> _downloadText(Uri uri, {Map<String, String>? headers}) async {
    return TextDownloadService.downloadText(uri, headers: headers);
  }

  void _refreshMobileState() {
    if (!mounted) return;
    if (_controller == null && _exitCleanupDone) return;
    setState(() {});
  }

  void _setMobileGestureOverlay({
    required bool active,
    String? text,
    IconData? icon,
  }) {
    if (!mounted) return;
    _gestureState.active = active;
    if (text != null) _gestureText = text;
    if (icon != null || !active) _gestureIcon = icon;
    _gestureOverlayNotifier.value = active
        ? _MobileGestureOverlayViewData(
            active: true,
            text: _gestureText,
            icon: _gestureIcon,
          )
        : const _MobileGestureOverlayViewData.inactive();
  }

  void _publishMobileHudIfChanged({
    required bool ready,
    required bool opening,
    required bool buffering,
    required String? error,
  }) {
    final next = _MobileHudViewData(
      ready: ready,
      opening: opening,
      buffering: buffering,
      error: error,
    );
    final cur = _mobileHudNotifier.value;
    if (cur.ready == next.ready &&
        cur.opening == next.opening &&
        cur.buffering == next.buffering &&
        cur.error == next.error) {
      return;
    }
    _mobileHudNotifier.value = next;
  }

  Future<void> _showCatalogMenu() async {
    if (!_canOpenCatalogMenu) return;
    if (!mounted) return;
    _pageController.setCatalogMenuOpen(true);
    const itemExtent = 56.0;
    final viewportHeight =
        min(MediaQuery.of(context).size.height * 0.78, 540.0);
    final centeredOffset =
        _index * itemExtent - (viewportHeight - itemExtent) / 2;
    final initialOffset =
        _catalogLocateCurrentOnOpen ? max(0.0, centeredOffset) : 0.0;
    final controller = ScrollController(initialScrollOffset: initialOffset);
    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        builder: (ctx) {
          return _MobileCatalogSheet(
            height: min(MediaQuery.of(ctx).size.height * 0.78, 540),
            controller: controller,
            itemExtent: itemExtent,
            itemCount: _sources.length,
            itemBuilder: (_, i) {
              final selected = i == _index;
              final source = _sources[i];
              return ListTile(
                dense: true,
                minLeadingWidth: 72,
                leading: SizedBox(
                  width: 72,
                  height: 40,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildMobileCatalogCover(source, cacheWidth: 260),
                      if (selected)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                    ],
                  ),
                ),
                title: Text(
                  PlayerSourceResolver.displayName(source),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
                trailing: selected
                    ? const Icon(Icons.check_circle,
                        color: Colors.white70, size: 18)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  if (i != _index) {
                    unawaited(_jumpTo(i));
                  }
                },
              );
            },
          );
        },
      );
    } finally {
      if (mounted) {
        _pageController.setCatalogMenuOpen(false);
      }
      controller.dispose();
    }
  }

  Widget _mobileCatalogCoverPlaceholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 16, color: Colors.white54),
      ),
    );
  }

  Widget _buildMobileCatalogEmbyCover(
    EmbyAccount account,
    String itemId, {
    int cacheWidth = 260,
  }) {
    final client = EmbyClient(account);
    final url = client.coverUrl(
      itemId,
      type: 'Primary',
      maxWidth: cacheWidth,
      quality: 85,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        headers: client.imageHeaders(),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (_, __, ___) => _mobileCatalogCoverPlaceholder(),
      ),
    );
  }

  Widget _buildMobileCatalogCover(String source, {int cacheWidth = 260}) {
    final embyRef = _parseEmbyRef(source);
    if (embyRef != null) {
      return FutureBuilder<Map<String, EmbyAccount>>(
        future: _ensureEmbyAccounts(),
        builder: (_, snap) {
          final account = snap.data?[embyRef.accountId];
          if (account == null) return _mobileCatalogCoverPlaceholder();
          return _buildMobileCatalogEmbyCover(
            account,
            embyRef.itemId,
            cacheWidth: cacheWidth,
          );
        },
      );
    }

    final stream = PlayerEmbySubtitleService.parseEmbyStreamInfo(source);
    if (stream != null) {
      return FutureBuilder<EmbyAccount?>(
        future: _resolveEmbyAccountForStream(source),
        builder: (_, snap) {
          final account = snap.data;
          if (account == null) return _mobileCatalogCoverPlaceholder();
          return _buildMobileCatalogEmbyCover(
            account,
            stream.itemId,
            cacheWidth: cacheWidth,
          );
        },
      );
    }

    if (_looksLikeLocalFilePath(source)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: VideoThumbImage(videoPath: source, cacheOnly: false),
      );
    }

    return _mobileCatalogCoverPlaceholder();
  }

  void _onControllerTick() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    if (!mounted) return;

    if (v.hasError && (_error ?? '').trim().isEmpty) {
      setState(() => _error = v.errorDescription ?? '播放失败');
      return;
    }

    final ended = v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= (v.duration - const Duration(milliseconds: 350));
    if (ended && !_endHandled) {
      _endHandled = true;
      if (_autoNextAfterEnd && _canNext) {
        unawaited(_next());
      } else {
        unawaited(c.pause());
        if (!_isScreenLocked) {
          _pageController.showControls();
        }
      }
    }
    if (!ended) _endHandled = false;

    _tryCommitHistoryRecord(position: v.position, playing: v.isPlaying);

    if (v.isPlaying) {
      _scheduleAutoHide();
    }
    setState(() {});
  }

  Future<int?> _loadResumePositionMs(String path) {
    return _loadMobileResumePositionMs(path);
  }

  Future<void> _beforeRouteExit({String reason = 'mobile pop'}) async {
    if (_exitCleanupDone) return;
    _exitCleanupDone = true;
    await _runMobileExitCleanup(
      reason: reason,
      dismissResumeHint: () => _dismissResumeHint(clearBinding: true),
      stopAutoRotate: _stopAutoRotateIfAny,
      unlockOrientation: () async {
        try {
          await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        } catch (_) {}
        try {
          await _mobileOriChannel.invokeMethod('unlock');
        } catch (_) {}
      },
      pauseController: () async {
        final c = _controller;
        if (c != null) {
          try {
            await c.pause();
          } catch (_) {}
        }
      },
      flushHistoryProgress: _flushHistoryProgress,
      stopEmbyCheckIns: () => _stopEmbyPlaybackCheckIns(reason: reason),
      resetAutoRotate: () {
        _autoRotateEnabled = false;
        _appliedNativeOri = NativeDeviceOrientation.unknown;
      },
    );
  }

  Future<void> _openCurrent({required bool autoPlay}) async {
    if (!_hasPlaylist) {
      _error = '没有可播放视频';
      _publishMobileHudIfChanged(
        ready: false,
        opening: false,
        buffering: false,
        error: _error,
      );
      if (mounted) setState(() {});
      return;
    }

    final seq = ++_openSeq;
    _dismissResumeHint();
    setState(() {
      _opening = true;
      _error = null;
      _title = PlayerSourceResolver.displayName(_currentPath);
      _openingLabel =
          _mobileOpeningLabel(hasExistingController: _controller != null);
      _draggingSeek = false;
      _dragSeekMs = 0;
    });
    _publishMobileHudIfChanged(
      ready: false,
      opening: true,
      buffering: false,
      error: null,
    );
    VideoPlayerController? nextController;
    try {
      final source = _currentPath;
      final resolved = await _resolveSource(source);
      if (!mounted || seq != _openSeq) return;
      nextController = await _createMobileVideoController(
        resolved: resolved,
        playbackRate: _rate,
        volume: _volume,
      );
      int? resumedAtMs;

      final resumeMs =
          _videoResumeEnabled ? await _loadResumePositionMs(source) : null;
      if (!mounted || seq != _openSeq) {
        await nextController.dispose();
        return;
      }
      resumedAtMs = await _seekMobileResumeIfNeeded(
        controller: nextController,
        resumeMs: resumeMs,
      );

      nextController.addListener(_onControllerTick);

      if (!mounted || seq != _openSeq) {
        nextController.removeListener(_onControllerTick);
        await nextController.dispose();
        return;
      }

      final old = _controller;
      _title = resolved.title;
      _controller = nextController;
      _endHandled = false;
      _opening = false;
      _publishMobileHudIfChanged(
        ready: true,
        opening: false,
        buffering: _controller?.value.isBuffering ?? false,
        error: null,
      );
      if (mounted) setState(() {});

      if (autoPlay) {
        await _controller?.play();
      }
      _finishMobileOpenSuccess(
        source: source,
        resumedAtMs: resumedAtMs,
      );

      if (old != null) {
        old.removeListener(_onControllerTick);
        await old.dispose();
      }
    } catch (e) {
      if (nextController != null) {
        nextController.removeListener(_onControllerTick);
        await nextController.dispose();
      }
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _opening = false;
        _error = redactSensitiveText(e.toString());
      });
      _publishMobileHudIfChanged(
        ready: false,
        opening: false,
        buffering: false,
        error: _error,
      );
    }
  }

  Future<void> _togglePlayPause() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await _pauseMobilePlayback(c);
    } else {
      await _resumeMobilePlayback(c);
    }
  }

  Future<void> _setPlaybackRate(double next) async {
    final rate = _normalizePlaybackRate(next);
    _rate = rate;
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      await _applyMobilePlaybackRate(c, rate);
    }
    if (mounted) setState(() {});
    _reportMobilePlaybackRateChanged();
  }

  Future<void> _showSpeedMenu() async {
    final picked = await _showMobileSpeedPicker(context, currentRate: _rate);
    if (picked != null) {
      await _setPlaybackRate(picked);
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = _computeRelativeSeekTarget(
      current: c.value.position,
      duration: c.value.duration,
      seconds: seconds,
    );
    await c.seekTo(target);
    _afterMobileRelativeSeek();
  }

  Future<void> _jumpTo(int newIndex) async {
    if (newIndex < 0 || newIndex >= _sources.length) return;
    await _flushHistoryProgress();
    setState(() {
      _index = newIndex;
      _openingLabel = _mobileSwitchingLabel(_currentPath);
    });
    await _openCurrent(autoPlay: true);
  }

  Future<void> _prev() => _jumpTo(_index - 1);
  Future<void> _next() => _jumpTo(_index + 1);

  Widget _buildFloatingLockButton({required bool locked}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(15),
      ),
      child: IconButton(
        tooltip: locked ? 'Unlock' : 'Lock',
        onPressed: _toggleScreenLock,
        iconSize: 18,
        color: Colors.white,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        icon: Icon(locked ? Icons.lock : Icons.lock_open),
      ),
    );
  }

  String _fmt(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '${d.inMinutes.remainder(60)}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final value = c?.value;
    final initialized = value?.isInitialized ?? false;
    final playing = value?.isPlaying ?? false;
    final buffering = value?.isBuffering ?? false;
    final duration = initialized ? value!.duration : Duration.zero;
    final position = initialized ? value!.position : Duration.zero;
    final captionText = initialized ? (value!.caption.text.trim()) : '';
    final maxMs = max(1, duration.inMilliseconds);
    final currentMs = _draggingSeek
        ? _dragSeekMs.clamp(0, maxMs.toDouble()).toDouble()
        : position.inMilliseconds
            .toDouble()
            .clamp(0, maxMs.toDouble())
            .toDouble();
    double bufferedMs = 0;
    if (initialized && value != null && duration > Duration.zero) {
      for (final r in value.buffered) {
        final endMs = r.end.inMilliseconds.toDouble();
        if (endMs > bufferedMs) bufferedMs = endMs;
      }
      bufferedMs = bufferedMs.clamp(0.0, maxMs.toDouble());
    }
    final showEpisodeNavButtons =
        _videoEpisodeNavButtonsEnabled && _sources.length > 1;

    return PopScope<void>(
      canPop: _allowRoutePopOnce,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_allowRoutePopOnce) return;
        final navigator = Navigator.of(context);
        await _beforeRouteExit(reason: 'mobile system back');
        if (!mounted) return;
        setState(() => _allowRoutePopOnce = true);
        navigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
          onHorizontalDragStart: initialized &&
                  _PlayerInteractionPolicy.canUseSeekGestures(
                    isScreenLocked: _isScreenLocked,
                    lockPauseSeekEnabled: _lockPauseSeekEnabled,
                  )
              ? _onHorizontalDragStart
              : null,
          onHorizontalDragUpdate: initialized &&
                  _PlayerInteractionPolicy.canUseSeekGestures(
                    isScreenLocked: _isScreenLocked,
                    lockPauseSeekEnabled: _lockPauseSeekEnabled,
                  )
              ? _onHorizontalDragUpdate
              : null,
          onHorizontalDragEnd: initialized &&
                  _PlayerInteractionPolicy.canUseSeekGestures(
                    isScreenLocked: _isScreenLocked,
                    lockPauseSeekEnabled: _lockPauseSeekEnabled,
                  )
              ? _onHorizontalDragEnd
              : null,
          onVerticalDragStart: initialized &&
                  _PlayerInteractionPolicy.canUseVerticalGestures(
                    isScreenLocked: _isScreenLocked,
                  )
              ? _onVerticalDragStart
              : null,
          onVerticalDragUpdate: initialized &&
                  _PlayerInteractionPolicy.canUseVerticalGestures(
                    isScreenLocked: _isScreenLocked,
                  )
              ? _onVerticalDragUpdate
              : null,
          onVerticalDragEnd: initialized &&
                  _PlayerInteractionPolicy.canUseVerticalGestures(
                    isScreenLocked: _isScreenLocked,
                  )
              ? _onVerticalDragEnd
              : null,
          onLongPressStart: initialized &&
                  _PlayerInteractionPolicy.canUseLongPressSpeed(
                    isScreenLocked: _isScreenLocked,
                    longPressSpeedEnabled: _longPressSpeedEnabled,
                  )
              ? _onLongPressStart
              : null,
          onLongPressEnd: initialized &&
                  _PlayerInteractionPolicy.canUseLongPressSpeed(
                    isScreenLocked: _isScreenLocked,
                    longPressSpeedEnabled: _longPressSpeedEnabled,
                  )
              ? _onLongPressEnd
              : null,
          child: Stack(
            children: [
              Center(
                child: (initialized && c != null)
                    ? AspectRatio(
                        aspectRatio:
                            value!.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                        child: VideoPlayer(c),
                      )
                    : const SizedBox.shrink(),
              ),
              if (_brightness < 0.999)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: ((1.0 - _brightness).clamp(0.0, 1.0) * 0.75),
                      ),
                    ),
                  ),
                ),
              if (captionText.isNotEmpty)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: (_controlsVisible && !_isScreenLocked)
                      ? max(_subtitleBottomOffset, 136.0)
                      : _subtitleBottomOffset,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(
                          alpha: _subtitleBackgroundOpacity,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          captionText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _subtitleFontSize,
                            height: 1.25,
                            shadows: _subtitleOutlineEnabled
                                ? const [
                                    Shadow(
                                        offset: Offset(1, 1),
                                        blurRadius: 2,
                                        color: Colors.black),
                                    Shadow(
                                        offset: Offset(-1, 1),
                                        blurRadius: 2,
                                        color: Colors.black),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_controlsVisible &&
                  !_isScreenLocked &&
                  initialized &&
                  _showMiniProgressWhenHidden &&
                  duration > Duration.zero)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: 2,
                        child: LinearProgressIndicator(
                          value: (currentMs / maxMs).clamp(0.0, 1.0),
                          minHeight: 2,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_opening)
                Center(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 18,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                color: Colors.white70,
                                strokeWidth: 2.8,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _openingLabel,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_error != null && _error!.trim().isNotEmpty)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 10),
                            FilledButton(
                              onPressed: () => _openCurrent(autoPlay: true),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_controlsVisible && !_isScreenLocked)
                _buildMobileControlsPanel(
                  context: context,
                  initialized: initialized,
                  currentMs: currentMs,
                  bufferedMs: bufferedMs,
                  maxMs: maxMs,
                  duration: duration,
                  playing: playing,
                  showEpisodeNavButtons: showEpisodeNavButtons,
                  controller: c,
                  onSeekChanged: (value) {
                    setState(() {
                      _draggingSeek = true;
                      _dragSeekMs = value;
                    });
                  },
                ),
              if (!_isScreenLocked && _controlsVisible)
                Positioned(
                  right: 10,
                  top: 0,
                  bottom: 0,
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildFloatingLockButton(locked: false),
                    ),
                  ),
                ),
              if (_isScreenLocked && _lockButtonVisible)
                Positioned(
                  right: 10,
                  top: 0,
                  bottom: 0,
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildFloatingLockButton(locked: true),
                    ),
                  ),
                ),
              ValueListenableBuilder<_MobileGestureOverlayViewData>(
                valueListenable: _gestureOverlayNotifier,
                builder: (_, overlay, __) {
                  if (!overlay.active || overlay.icon == null) {
                    return const SizedBox.shrink();
                  }
                  return Center(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(overlay.icon, color: Colors.white, size: 30),
                              const SizedBox(height: 8),
                              Text(
                                overlay.text,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (_resumeHintVisible && _resumeHintText.trim().isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: (_controlsVisible && !_isScreenLocked) ? 112 : 28,
                  child: SafeArea(
                    top: false,
                    child: IgnorePointer(
                      ignoring: false,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.68),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                          child: Row(
                            children: [
                              const Icon(Icons.history_rounded,
                                  color: Colors.white, size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _resumeHintText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  final cur = _controller;
                                  if (cur == null || !cur.value.isInitialized) {
                                    return;
                                  }
                                  final sourcePath = _currentPath;
                                  _dismissResumeHint();
                                  unawaited(cur.seekTo(Duration.zero));
                                  unawaited(_reportEmbyProgress(
                                    eventName: 'TimeUpdate',
                                    interactive: true,
                                  ));
                                  unawaited(AppHistory.updateProgress(
                                    path: sourcePath,
                                    positionMs: 0,
                                  ));
                                  _showGestureOverlay('从头播放', Icons.replay);
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('从头播放'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (buffering && !_opening)
                const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.white70,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
