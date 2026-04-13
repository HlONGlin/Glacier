part of '../video.dart';

class _VideoPlayerPageState extends State<_DesktopVideoPlayerHost> {
  late final Player _player;
  late final VideoController _controller;
  late final player_presentation.PlayerController _pageController;

  bool _ready = false;
  int _index = 0;

  /// 播放列表（可变）。
  ///
  /// ✅ 设计原因：
  /// - 外部传入的 videoPaths 可能只有 1 条（例如：从历史记录打开）。
  /// - 用户希望在播放器内也能打开“同目录/同季/同文件夹”的目录列表（WebDAV/Emby 同样生效）。
  /// - 因此这里把 sources 作为内部可变列表：需要时可以“按需扩容并重建 playlist”。
  late List<String> _sources;

  bool _sourcesExpandedOnce = false;
  bool _sourcesExpanding = false;

  // WebDAV 账号表
  Future<Map<String, Map<String, String>>>? _webDavAccountCacheFuture;

  // Emby 账号表（用于目录封面/目录补全等）
  Future<Map<String, EmbyAccount>>? _embyAccountMapFuture;

  // ============================
  // Emby 播放上报（Playback Check-ins）
  // ============================
  final _DesktopReporterState _reporterState = _DesktopReporterState();

  /// 发送上报的串行队列（避免并发多次 POST 导致顺序错乱）。
  Future<void> get _embyReportQueue => _reporterState.embyReportQueue;
  set _embyReportQueue(Future<void> value) =>
      _reporterState.embyReportQueue = value;

  /// 降噪：记录最近一次主动上报时间，用于避免用户频繁操作时“刷爆服务端”。
  DateTime get _embyLastInteractiveReportAt =>
      _reporterState.embyLastInteractiveReportAt;
  set _embyLastInteractiveReportAt(DateTime value) =>
      _reporterState.embyLastInteractiveReportAt = value;

  /// 播放器目录：WebDAV 视频 → 同目录“侧边封面图”（若存在）
  /// - key: 视频 source（webdav://...）
  /// - value: 图片 source（webdav://... 指向 jpg/png/webp）
  final LinkedHashMap<String, String> _webDavSidecarCoverByVideoSource =
      LinkedHashMap<String, String>();
  static const int _kMaxWebDavSidecarCoverEntries = 300;

  /// WebDAV：目录缩略图生成（前缀下载 + 抽帧）Future 缓存
  final LinkedHashMap<String, Future<File?>> _webDavVideoThumbFutureCache =
      LinkedHashMap<String, Future<File?>>();
  static const int _kMaxWebDavVideoThumbFutureEntries = 160;

  /// WebDAV：source → (url, headers) 解析 Future 缓存
  final LinkedHashMap<String,
          Future<({String url, Map<String, String> headers})?>>
      _webDavResolveFutureCache = LinkedHashMap<String,
          Future<({String url, Map<String, String> headers})?>>();
  static const int _kMaxWebDavResolveEntries = 200;

  /// 目录缩略图任务并发控制（移动端：避免边播边疯狂拉封面导致卡顿）
  final AsyncSemaphore _catalogThumbSemaphore = AsyncSemaphore(1);

  T _rememberLru<T>(LinkedHashMap<String, T> cache, String key, T value) {
    cache.remove(key);
    cache[key] = value;
    return value;
  }

  T? _touchLru<T>(LinkedHashMap<String, T> cache, String key) {
    final hit = cache.remove(key);
    if (hit != null) {
      cache[key] = hit;
    }
    return hit;
  }

  void _trimStringCache(LinkedHashMap<String, String> cache, int maxEntries) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  void _trimFutureCache<T>(
      LinkedHashMap<String, Future<T>> cache, int maxEntries) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  // 播放器参数
  double _rate = 1.0;
  double _volume = 100.0;
  double _brightness = 1.0;

  // UI 状态
  bool _titleVisible = true;
  Timer? _titleTimer;
  final _DesktopOrientationState _orientationState = _DesktopOrientationState();

  final MethodChannel _oriChannel = const MethodChannel('glacier/orientation');
  StreamSubscription<NativeDeviceOrientation>? _nativeOriSub;

  final _DesktopSubtitleState _subtitleState = _DesktopSubtitleState();

  StreamSubscription<Playlist>? _playlistSub;

  // 检查器
  bool _inspectorOpen = false;
  Timer? _inspectorTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<Duration>? _bufSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<double>? _rateSub;

  Duration _insPos = Duration.zero;
  Duration _insBuf = Duration.zero;
  bool _insBuffering = false;
  bool _insPlaying = false;
  double _insRate = 1.0;

  bool get _canOpenCatalogPopup => _PlayerInteractionPolicy.canOpenCatalog(
        hasPlaylist: _hasPlaylist,
        isScreenLocked: _isScreenLocked,
        catalogEnabled: _videoCatalogEnabled,
        menuAlreadyOpen: _catalogOpen,
      );
  Timer? _catalogHotspotTimer;

  final _DesktopGestureState _gestureState = _DesktopGestureState();
  final ValueNotifier<_DesktopGestureOverlayViewData>
      _desktopGestureOverlayNotifier =
      ValueNotifier<_DesktopGestureOverlayViewData>(
          const _DesktopGestureOverlayViewData.inactive());

  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;
  double _subtitleBackgroundOpacity = 0.55;
  bool _subtitleOutlineEnabled = true;
  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  bool _showMiniProgressWhenHidden = true;
  bool _videoCatalogEnabled = true;

  bool _autoNextAfterEnd = false;

  Duration _duration = Duration.zero;
  bool _nearEnd = false;

  static const int _historyMinPlayMs = 800;
  int _historyLastCommitAt = 0;
  String _historyLastCommitPath = '';
  String? _historyArmedPath;
  bool _historyArmed = false;

  double? _rateBeforeLongPress;

  bool get _hasPlaylist => _sources.isNotEmpty;
  bool get _isDesktop => !kIsWeb && !Platform.isAndroid && !Platform.isIOS;
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  String get _currentPath => _hasPlaylist ? _sources[_index] : '';
  String get _title =>
      _hasPlaylist ? PlayerSourceResolver.displayName(_currentPath) : '视频播放';

  static const _hideDelay = Duration(seconds: 5);
  static const _cursorDelay = Duration(milliseconds: 1600);

  _EmbyPlaybackSession? get _embyPlayback => _reporterState.embyPlayback;
  set _embyPlayback(_EmbyPlaybackSession? value) =>
      _reporterState.embyPlayback = value;

  Timer? get _embyProgressTimer => _reporterState.embyProgressTimer;
  set _embyProgressTimer(Timer? value) =>
      _reporterState.embyProgressTimer = value;

  bool get _isFullscreen => _orientationState.isFullscreen;
  set _isFullscreen(bool value) => _orientationState.isFullscreen = value;

  bool get _isScreenLocked => _orientationState.isScreenLocked;
  set _isScreenLocked(bool value) => _orientationState.isScreenLocked = value;

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

  int get _videoQuarterTurns => _orientationState.videoQuarterTurns;
  set _videoQuarterTurns(int value) =>
      _orientationState.videoQuarterTurns = value;

  bool get _autoRotateEnabled => _orientationState.autoRotateEnabled;
  set _autoRotateEnabled(bool value) =>
      _orientationState.autoRotateEnabled = value;

  bool get _uiVisible => _pageController.desktopUiVisible;
  bool get _cursorHidden => _pageController.desktopCursorHidden;
  bool get _catalogOpen => _pageController.desktopCatalogOpen;

  List<String> get _srtCandidates => _subtitleState.srtCandidates;
  set _srtCandidates(List<String> value) =>
      _subtitleState.srtCandidates = value;

  String? get _srtSelected => _subtitleState.srtSelected;
  set _srtSelected(String? value) => _subtitleState.srtSelected = value;

  bool get _srtEnabled => _subtitleState.srtEnabled;
  set _srtEnabled(bool value) => _subtitleState.srtEnabled = value;

  List<EmbySubtitleTrack> get _embySubtitleCandidates =>
      _subtitleState.embySubtitleCandidates;
  set _embySubtitleCandidates(List<EmbySubtitleTrack> value) =>
      _subtitleState.embySubtitleCandidates = value;

  EmbySubtitleTrack? get _embySubtitleSelected =>
      _subtitleState.embySubtitleSelected;
  set _embySubtitleSelected(EmbySubtitleTrack? value) =>
      _subtitleState.embySubtitleSelected = value;

  String? get _lastAutoSubtitleItemId => _subtitleState.lastAutoSubtitleItemId;
  set _lastAutoSubtitleItemId(String? value) =>
      _subtitleState.lastAutoSubtitleItemId = value;

  String get _gestureType => _gestureState.type;
  set _gestureType(String value) => _gestureState.type = value;

  String get _gestureText => _gestureState.text;
  set _gestureText(String value) => _gestureState.text = value;

  IconData? get _gestureIcon => _gestureState.icon;
  set _gestureIcon(IconData? value) => _gestureState.icon = value;

  Duration get _dragStartPos => _gestureState.dragStartPos;
  set _dragStartPos(Duration value) => _gestureState.dragStartPos = value;

  Duration get _dragTargetPos => _gestureState.dragTargetPos;
  set _dragTargetPos(Duration value) => _gestureState.dragTargetPos = value;

  @override
  void initState() {
    super.initState();
    _pageController = player_presentation.PlayerController()
      ..addListener(_refreshDesktopState);
    AppSettings.instance.addListener(_onAppSettingsChanged);

    _sources = List<String>.from(widget.videoPaths);
    _loadSettings();

    if (_isMobile) {
      _pageController.hideDesktopUi();
    }

    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    SystemChrome.setSystemUIOverlayStyle(_kLightStatusBarStyle);
    WebDavBackgroundGate.pauseHard();

    if (_sources.any((s) => isWebDavSource(s))) {
      _webDavAccountCacheFuture = PlayerSourceResolver.loadWebDavAccountCache();
    }

    if (_sources.any((s) => isEmbySource(s))) {
      _embyAccountMapFuture = PlayerSourceResolver.loadEmbyAccountMap();
    }

    _player = Player();
    if (_player.platform is NativePlayer) {
      final mpv = _player.platform as NativePlayer;
      mpv.setProperty('cache', 'yes');
      mpv.setProperty('cache-on-disk', 'no');
      mpv.setProperty('cache-secs', '45');
      mpv.setProperty('demuxer-max-bytes', '${192 * 1024 * 1024}');
      mpv.setProperty('demuxer-max-back-bytes', '${128 * 1024 * 1024}');
      mpv.setProperty('demuxer-readahead-secs', '120');
      mpv.setProperty('network-timeout', '60');
      mpv.setProperty('cache-pause', 'no');
      mpv.setProperty(
          'user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) MediaKit');
      mpv.setProperty('force-window', 'yes');
    }

    _controller = VideoController(_player);

    _posSub = _player.stream.position.listen((v) {
      _insPos = v;
      _tryCommitHistoryRecord(v);

      if (_duration.inMilliseconds <= 0) return;
      final remainMs = _duration.inMilliseconds - v.inMilliseconds;
      _nearEnd = remainMs <= 600;
    });
    _durSub = _player.stream.duration.listen((v) => _duration = v);
    _bufSub = _player.stream.buffer.listen((v) => _insBuf = v);
    _bufferingSub = _player.stream.buffering.listen((v) {
      if (_insBuffering == v) return;
      _insBuffering = v;
      if (mounted) setState(() {});
    });
    _playingSub = _player.stream.playing.listen((v) => _insPlaying = v);
    _rateSub = _player.stream.rate.listen((v) => _insRate = v);

    _playlistSub = _player.stream.playlist.listen((pl) {
      final next = pl.index;
      if (next != _index && mounted) {
        final prev = _index;
        if (!_autoNextAfterEnd && _nearEnd) {
          _player.jump(prev);
          _player.pause();
          unawaited(_reportEmbyProgress(eventName: 'Pause'));
          return;
        }

        setState(() => _index = next);
        _autoLoadSrtIfAny();
        unawaited(
            _startEmbyPlaybackCheckInsIfNeeded(reason: 'playlistChanged'));
        _armHistoryRecordForCurrent();
      }
    });

    StallDetector.I.start();
    _inspectorTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      PlayerInspector.I.push(PlayerSample(
        t: DateTime.now(),
        position: _insPos,
        playing: _insPlaying,
        buffering: _insBuffering,
        buffer: _insBuf,
        rate: _insRate,
      ));
    });

    if (_hasPlaylist) {
      _index = widget.initialIndex.clamp(0, _sources.length - 1);
    }

    _initOpen().catchError((e) async {
      try {
        await _player.stop();
      } catch (_) {}
      _ready = false;
      if (mounted) setState(() {});
      _showDesktopErrorSnack(redactSensitiveText(e.toString()));
    });

    _uiVisible ? _pokeUI() : null;
  }

  void _onAppSettingsChanged() {
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final values = await _loadDesktopVideoSettingsValues();
      if (!mounted) return;
      setState(() {
        _subtitleFontSize = values.font;
        _subtitleBottomOffset = values.bottom;
        _subtitleBackgroundOpacity = values.backgroundOpacity.clamp(0.0, 1.0);
        _subtitleOutlineEnabled = values.outlineEnabled;
        _longPressSpeedEnabled = values.longPressEnabled;
        _longPressSpeedMultiplier = values.longPressMultiplier;
        _showMiniProgressWhenHidden = values.miniProgress;
        _videoCatalogEnabled = values.catalogEnabled;
        _autoNextAfterEnd = values.autoNext;
      });
    } catch (_) {}
  }

  Future<void> _toggleEndBehavior() async {
    final next = !_autoNextAfterEnd;
    if (mounted) setState(() => _autoNextAfterEnd = next);
    try {
      await AppSettings.setVideoAutoNextAfterEnd(next);
    } catch (_) {}
  }

  Future<void> _initOpen() async {
    if (!_hasPlaylist) {
      setState(() => _ready = false);
      return;
    }
    final medias = await _buildMedias();
    await _player.open(Playlist(medias, index: _index), play: true);
    _player.setRate(_rate);
    _player.setVolume(_volume);

    _ready = true;
    if (mounted) setState(() {});
    _armHistoryRecordForCurrent();
    await _autoLoadSrtIfAny();
    unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'initOpen'));
  }

  Widget _buildRotatedVideo(Widget video) {
    if (!_isMobile) return video;
    final turns = _videoQuarterTurns % 4;
    if (turns == 0) return video;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final swapped = (turns % 2 == 1);

        return Center(
          child: RotatedBox(
            quarterTurns: turns,
            child: SizedBox(
              width: swapped ? h : w,
              height: swapped ? w : h,
              child: video,
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    try {
      final path = _currentPath;
      if (path.trim().isNotEmpty) {
        AppHistory.updateProgress(
            path: path, positionMs: _insPos.inMilliseconds);
      }
    } catch (_) {}

    unawaited(_stopEmbyPlaybackCheckIns(reason: 'desktop dispose'));
    _stopAutoRotateIfAny();
    _unlockNativeOrientation();
    _inspectorTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _bufSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();
    _rateSub?.cancel();
    _playlistSub?.cancel();
    StallDetector.I.stop();

    WebDavBackgroundGate.resume();
    _titleTimer?.cancel();
    _catalogHotspotTimer?.cancel();
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    _pageController
      ..removeListener(_refreshDesktopState)
      ..dispose();

    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_kDarkStatusBarStyle);

    _desktopGestureOverlayNotifier.dispose();
    _player.dispose();
    super.dispose();
  }

  void _refreshDesktopState() {
    if (!mounted) return;
    setState(() {});
  }

  void _refreshDesktopGestureState() {
    if (!mounted) return;
    _desktopGestureOverlayNotifier.value =
        _gestureState.active && _gestureIcon != null
            ? _DesktopGestureOverlayViewData(
                active: true,
                text: _gestureText,
                icon: _gestureIcon,
              )
            : const _DesktopGestureOverlayViewData.inactive();
  }

  void _refreshCatalogExpansionState() {
    if (!mounted) return;
    setState(() {});
  }

  void _showTitleHint() {
    _titleTimer?.cancel();
    if (!_titleVisible) setState(() => _titleVisible = true);
    _titleTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _titleVisible = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    if (_isMobile) return;
    final next = !_isFullscreen;
    if (mounted) setState(() => _isFullscreen = next);
  }

  Future<void> _toggleScreenLock() async {
    setState(() => _isScreenLocked = !_isScreenLocked);

    if (_isScreenLocked) {
      _autoRotateEnabled = false;
      _stopAutoRotateIfAny();

      final isLandscape = (_videoQuarterTurns % 2 == 1) ||
          MediaQuery.of(context).orientation == Orientation.landscape;
      if (isLandscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await _oriChannel.invokeMethod('lockLandscape');
      } else {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        await _oriChannel.invokeMethod('lockPortrait');
      }
    } else {
      _autoRotateEnabled = true;
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await _unlockNativeOrientation();

      _lastOriCandidate = null;
      _oriStableCount = 0;
      _lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);

      Future.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        if (_isScreenLocked) return;
        _startAutoRotateIfMobile();
      });
    }
    _pokeUI();
  }

  Future<void> _showRateMenu(BuildContext buttonContext) async {
    _pokeUI();
    final selected = await _showDesktopRatePicker(
      buttonContext,
      currentRate: _rate,
    );

    if (selected == null) return;
    setState(() => _rate = selected);
    try {
      await _player.setRate(selected);
    } catch (e) {
      _toast('设置倍速失败：$e');
    }

    unawaited(_reportEmbyProgress(
        eventName: 'PlaybackRateChange', interactive: true));
    _pokeUI();
  }

  Future<void> _showCatalogPopup({bool fromHotspot = false}) async {
    final picked = await _showDesktopCatalogPicker(fromHotspot: fromHotspot);

    if (!mounted) return;
    if (picked != null && picked != _index) {
      setState(() => _index = picked);
      await _player.jump(_index);
      unawaited(_autoLoadSrtIfAny());
      unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'catalogPick'));
      _armHistoryRecordForCurrent();
      _uiVisible ? _pokeUI() : null;
    }
  }

  Future<int?> _showCatalogBottomSheetMobile() async {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String q = '';
        bool searchExpanded = false;

        final maxH = MediaQuery.of(ctx).size.height;
        final preferredH = max(220.0, maxH * 0.86);
        final cappedH = min(preferredH, maxH - 12.0);
        final sheetH = min(maxH, max(120.0, cappedH));

        return IgnorePointer(
          ignoring: _isScreenLocked,
          child: StatefulBuilder(
            builder: (ctx2, setState2) {
              final showSearch = searchExpanded || q.trim().isNotEmpty;
              final indices = PlayerCatalogSearchService.filterIndices(
                _sources,
                query: q,
              );

              return SizedBox(
                height: sheetH,
                child: Material(
                  color: Theme.of(ctx2).colorScheme.surface,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(18)),
                  clipBehavior: Clip.antiAlias,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
                          child: Row(
                            children: [
                              const Icon(Icons.list_alt),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '目录 ${_index + 1}/${_sources.length}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: showSearch ? '收起搜索' : '展开搜索',
                                icon: Icon(
                                  showSearch ? Icons.search_off : Icons.search,
                                ),
                                onPressed: () => setState2(() {
                                  if (showSearch) {
                                    q = '';
                                    searchExpanded = false;
                                  } else {
                                    searchExpanded = true;
                                  }
                                }),
                              ),
                              IconButton(
                                tooltip: '刷新目录',
                                icon: const Icon(Icons.refresh),
                                onPressed: () async {
                                  await _runWithBusyDialog(
                                    () =>
                                        _ensureCatalogSourcesReady(force: true),
                                    message: PlayerUiTextService
                                        .catalogLoadingMessage(
                                      initialExpansion: false,
                                    ),
                                  );
                                  if (ctx2.mounted) setState2(() {});
                                  _prefetchCatalogThumbsAround(_index);
                                },
                              ),
                              IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.pop(ctx2)),
                            ],
                          ),
                        ),
                        if (showSearch)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: TextField(
                              autofocus: true,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '搜索本目录...',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: q.trim().isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: '清空',
                                        icon: const Icon(Icons.close),
                                        onPressed: () =>
                                            setState2(() => q = ''),
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onChanged: (v) => setState2(() => q = v),
                            ),
                          ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.builder(
                            itemCount: indices.length,
                            itemBuilder: (_, k) {
                              final i = indices[k];
                              final src = _sources[i];
                              final name =
                                  PlayerSourceResolver.displayName(src);

                              return ListTile(
                                selected: i == _index,
                                dense: true,
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 96,
                                    height: 54,
                                    child: _buildCatalogThumb(src,
                                        cacheWidth: 320),
                                  ),
                                ),
                                title: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  '${i + 1} / $_sources.length',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: Theme.of(ctx2)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: i == _index
                                    ? const Icon(Icons.play_arrow)
                                    : null,
                                onTap: () => Navigator.pop(ctx2, i),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<int?> _showCatalogSidePanelDesktop() async {
    return showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'catalog',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, _, __) {
        final size = MediaQuery.of(ctx).size;
        final w = size.width;
        final h = size.height;
        final panelWidth = w >= 980 ? 420.0 : (w * 0.42).clamp(320.0, 420.0);
        final top = (h * 0.12).clamp(64.0, 120.0);

        String q = '';
        bool searchExpanded = false;

        return IgnorePointer(
          ignoring: _isScreenLocked,
          child: StatefulBuilder(builder: (ctx2, setState2) {
            final showSearch = searchExpanded || q.trim().isNotEmpty;
            final indices = PlayerCatalogSearchService.filterIndices(
              _sources,
              query: q,
            );

            return Stack(
              children: [
                Positioned(
                  top: top,
                  right: 18,
                  bottom: 18,
                  width: panelWidth,
                  child: Material(
                    color: Theme.of(ctx2).colorScheme.surface,
                    elevation: 16,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: SafeArea(
                      left: false,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                            child: Row(
                              children: [
                                const Icon(Icons.list_alt),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '目录 ${_index + 1}/${_sources.length}',
                                    maxLines: 1,
                                  ),
                                ),
                                IconButton(
                                  tooltip: showSearch ? '收起搜索' : '展开搜索',
                                  icon: Icon(
                                    showSearch
                                        ? Icons.search_off
                                        : Icons.search_outlined,
                                  ),
                                  onPressed: () => setState2(() {
                                    if (showSearch) {
                                      q = '';
                                      searchExpanded = false;
                                    } else {
                                      searchExpanded = true;
                                    }
                                  }),
                                ),
                                IconButton(
                                  tooltip: '刷新目录',
                                  icon: const Icon(Icons.refresh),
                                  onPressed: () async {
                                    await _runWithBusyDialog(
                                      () => _ensureCatalogSourcesReady(
                                          force: true),
                                      message: PlayerUiTextService
                                          .catalogLoadingMessage(
                                        initialExpansion: false,
                                      ),
                                    );
                                    if (ctx2.mounted) setState2(() {});
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.pop(ctx2),
                                ),
                              ],
                            ),
                          ),
                          if (showSearch)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                              child: TextField(
                                autofocus: true,
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: '搜索本目录...',
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: q.trim().isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: '清空',
                                          icon: const Icon(Icons.close),
                                          onPressed: () {
                                            setState2(() => q = '');
                                          },
                                        ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onChanged: (v) {
                                  setState2(() => q = v);
                                },
                              ),
                            ),
                          const Divider(height: 1),
                          Expanded(
                            child: ListView.builder(
                              itemExtent: 56.0,
                              itemCount: indices.length,
                              itemBuilder: (_, k) {
                                final i = indices[k];
                                final src = _sources[i];
                                final name =
                                    PlayerSourceResolver.displayName(src);
                                return ListTile(
                                  dense: true,
                                  selected: i == _index,
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 72,
                                      height: 40,
                                      child: _buildCatalogThumb(src,
                                          cacheWidth: 260),
                                    ),
                                  ),
                                  title: Text(name, maxLines: 1),
                                  trailing: i == _index
                                      ? const Icon(Icons.play_arrow)
                                      : null,
                                  onTap: () => Navigator.pop(ctx2, i),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        return FadeTransition(opacity: anim, child: child);
      },
    );
  }

  Future<void> _togglePlayPause() async {
    final playing = _player.state.playing;
    playing ? await _player.pause() : await _player.play();
    unawaited(_reportEmbyProgress(eventName: playing ? 'Pause' : 'Unpause'));
    _uiVisible ? _pokeUI() : null;
  }

  Future<void> _seekBy(int seconds) async {
    final cur = _player.state.position;
    await _player.seek(cur + Duration(seconds: seconds));
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
    _uiVisible ? _pokeUI() : null;
  }

  Future<void> _runWithBusyDialog(Future<void> Function() job,
      {String message = '正在加载...'}) async {
    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    bool popped = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(blurRadius: 18, color: Colors.black26)
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(message, maxLines: 1),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      await job();
    } finally {
      if (mounted && !popped && nav.canPop()) {
        popped = true;
        nav.pop();
      }
    }
  }

  Future<void> _showRateSubMenu(
      {required double parentLeft,
      required double parentTop,
      required double parentWidth}) async {
    const rates = <double>[0.5, 1.0, 1.25, 1.5, 2.0];
    final result = await showMenu<double>(
      context: context,
      position: RelativeRect.fromLTRB(
        parentLeft,
        parentTop,
        max(0, MediaQuery.of(context).size.width - parentLeft - parentWidth),
        0,
      ),
      items: [
        for (final rate in rates)
          PopupMenuItem<double>(
            value: rate,
            child: Row(
              children: [
                Icon(
                  _rate == rate
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text('${rate}x'),
              ],
            ),
          ),
      ],
    );
    if (result != null) {
      setState(() => _rate = result);
      try {
        await _player.setRate(result);
      } catch (e) {
        _toast('设置倍速失败：$e');
      }
      unawaited(_reportEmbyProgress(
          eventName: 'PlaybackRateChange', interactive: true));
      _pokeUI();
    }
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    _pokeUI();
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        max(0, MediaQuery.of(context).size.width - globalPos.dx),
        max(0, MediaQuery.of(context).size.height - globalPos.dy),
      ),
      items: const [
        PopupMenuItem<String>(value: 'play_pause', child: Text('播放 / 暂停')),
        PopupMenuItem<String>(value: 'fullscreen', child: Text('全屏 / 退出全屏')),
        PopupMenuItem<String>(value: 'rate', child: Text('倍速')),
      ],
    );
    switch (value) {
      case 'play_pause':
        await _togglePlayPause();
        break;
      case 'fullscreen':
        _toggleFullscreen();
        break;
      case 'rate':
        await _showRateSubMenu(
          parentLeft: globalPos.dx,
          parentTop: globalPos.dy,
          parentWidth: 180,
        );
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_isDesktop || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      if (!_canOpenCatalogPopup) return KeyEventResult.handled;
      _showCatalogPopup();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int x) => x.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {
            if (!_isMobile) _uiVisible ? _pokeUI() : null;
          },
          onPointerSignal: (sig) {
            if (sig is PointerScrollEvent && _isDesktop) {
              _pokeUI();
              final pressed = HardwareKeyboard.instance.logicalKeysPressed;
              final ctrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
                  pressed.contains(LogicalKeyboardKey.controlRight);
              if (ctrl) {
                _seekBy(sig.scrollDelta.dy > 0 ? -5 : 5);
              } else {
                _adjustVolume(sig.scrollDelta.dy > 0 ? -5 : 5);
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _isMobile &&
                    _PlayerInteractionPolicy.canUseSeekGestures(
                      isScreenLocked: _isScreenLocked,
                      lockPauseSeekEnabled: false,
                    )
                ? _onHorizontalDragStart
                : null,
            onHorizontalDragUpdate: _isMobile &&
                    _PlayerInteractionPolicy.canUseSeekGestures(
                      isScreenLocked: _isScreenLocked,
                      lockPauseSeekEnabled: false,
                    )
                ? _onHorizontalDragUpdate
                : null,
            onHorizontalDragEnd: _isMobile &&
                    _PlayerInteractionPolicy.canUseSeekGestures(
                      isScreenLocked: _isScreenLocked,
                      lockPauseSeekEnabled: false,
                    )
                ? _onHorizontalDragEnd
                : null,
            onVerticalDragStart: _isMobile &&
                    _PlayerInteractionPolicy.canUseVerticalGestures(
                      isScreenLocked: _isScreenLocked,
                    )
                ? _onVerticalDragStart
                : null,
            onVerticalDragUpdate: _isMobile &&
                    _PlayerInteractionPolicy.canUseVerticalGestures(
                      isScreenLocked: _isScreenLocked,
                    )
                ? _onVerticalDragUpdate
                : null,
            onVerticalDragEnd: _isMobile &&
                    _PlayerInteractionPolicy.canUseVerticalGestures(
                      isScreenLocked: _isScreenLocked,
                    )
                ? _onVerticalDragEnd
                : null,
            onTap: () {
              if (!_isMobile) return;
              if (_isScreenLocked) return;
              _uiVisible
                  ? _pageController.hideDesktopUi()
                  : _pageController.showDesktopUi();
              if (_uiVisible) _pokeUI();
            },
            onTapUp: (d) {
              if (_isMobile) return;
              final size = MediaQuery.of(context).size;
              if (d.localPosition.dy < 90 && d.localPosition.dx < 260) return;
              if (d.localPosition.dy > size.height - 140) return;
              _togglePlayPause();
            },
            onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
            onDoubleTap: () {
              if (!_isMobile || _isScreenLocked) return;
              _togglePlayPause();
              _uiVisible ? _pokeUI() : null;
            },
            onLongPressStart: _isMobile &&
                    _PlayerInteractionPolicy.canUseLongPressSpeed(
                      isScreenLocked: _isScreenLocked,
                      longPressSpeedEnabled: _longPressSpeedEnabled,
                    )
                ? (_) async {
                    if (!_ready) return;
                    if (_rateBeforeLongPress != null) return;

                    _rateBeforeLongPress = _rate;
                    final target =
                        (_rate * _longPressSpeedMultiplier).clamp(0.25, 8.0);

                    try {
                      await _player.setRate(target);
                      if (mounted) setState(() => _rate = target);
                    } catch (_) {
                      final back = _rateBeforeLongPress;
                      _rateBeforeLongPress = null;
                      if (back != null) {
                        try {
                          await _player.setRate(back);
                        } catch (_) {}
                        if (mounted) setState(() => _rate = back);
                      }
                    }
                  }
                : null,
            onLongPressEnd: _isMobile &&
                    _PlayerInteractionPolicy.canUseLongPressSpeed(
                      isScreenLocked: _isScreenLocked,
                      longPressSpeedEnabled: _longPressSpeedEnabled,
                    )
                ? (_) async {
                    final back = _rateBeforeLongPress;
                    _rateBeforeLongPress = null;
                    if (back == null) return;

                    try {
                      await _player.setRate(back);
                    } catch (_) {}
                    if (mounted) setState(() => _rate = back);
                  }
                : null,
            child: MouseRegion(
              cursor: (!_isDesktop || !_cursorHidden)
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.none,
              onHover: (_) => _pokeUI(),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _ready
                        ? _buildRotatedVideo(Video(
                            controller: _controller,
                            subtitleViewConfiguration:
                                SubtitleViewConfiguration(
                              style: TextStyle(
                                fontSize: _subtitleFontSize,
                                color: Colors.white,
                                backgroundColor: Colors.black.withValues(
                                  alpha: _subtitleBackgroundOpacity,
                                ),
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
                              padding: EdgeInsets.only(
                                  bottom: _subtitleBottomOffset),
                            ),
                            controls: (state) => _PlayerControlsOverlay(
                                  state: state,
                                  player: _player,
                                  currentVideoPath: _currentPath,
                                  uiVisible: _uiVisible,
                                  onUserInteract: _pokeUI,
                                  volume: _volume,
                                  rate: _rate,
                                  isFullscreen: _isFullscreen,
                                  subtitlesEnabled: _srtEnabled,
                                  autoNextAfterEnd: _autoNextAfterEnd,
                                  showMiniProgressWhenHidden:
                                      _showMiniProgressWhenHidden,
                                  catalogEnabled: _videoCatalogEnabled,
                                  playlistCount:
                                      _sources.isEmpty ? 1 : _sources.length,
                                  playlistIndex: _index,
                                  onShowCatalog: () => _showCatalogPopup(),
                                  onTogglePlayPause: _togglePlayPause,
                                  onShowSubtitles: _showSrtMenu,
                                  onShowRate: _showRateMenu,
                                  onToggleEndBehavior: _toggleEndBehavior,
                                  isScreenLocked: _isScreenLocked,
                                )))
                        : const Center(
                            child: Text(
                              '无法打开视频',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withValues(
                            alpha: (1.0 - _brightness).clamp(0.0, 1.0) * 0.75),
                      ),
                    ),
                  ),
                  if (_ready && _insBuffering)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 10),
                            Text(
                              '加载中...',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ..._buildDesktopPlayerOverlays(context),
                  if (_inspectorOpen)
                    PlaybackInspectorOverlay(onClose: () {
                      if (mounted) setState(() => _inspectorOpen = false);
                    }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
