import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;
import 'tag.dart';
import 'utils.dart';
import 'remote_media_cache.dart';
import 'image.dart';
import 'inspector.dart';
import 'emby.dart';
import 'source_refs.dart';
import 'dart:math';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:collection/collection.dart';

import 'features/media/player/data/play_source_resolver.dart';
import 'features/media/player/data/player_catalog_search_service.dart';
import 'features/media/player/data/player_emby_subtitle_service.dart';
import 'features/media/player/data/player_history_service.dart';
import 'features/media/player/data/player_local_subtitle_service.dart';
import 'features/media/player/data/player_ui_text_service.dart';
import 'features/media/player/data/text_download_service.dart';
import 'features/media/player/presentation/player_controller.dart'
    as player_presentation;
import 'core/network/http_client_factory.dart';
import 'core/network/network_runner.dart';
part 'player/video_state_groups.dart';
part 'player/mobile_controls_overlay.dart';
part 'player/player_controls_overlay.dart';
part 'player/mobile_reporter_subtitle_orientation.dart';
part 'player/desktop_reporter_subtitle_orientation.dart';
part 'player/player_gesture_handlers.dart';
part 'player/player_catalog_and_expansion.dart';
part 'player/mobile_player_surface.dart';
part 'player/desktop_player_surface.dart';

const SystemUiOverlayStyle _kLightStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

// ===== media_video.dart (auto-grouped) =====

// --- from video.dart ---

/// ===============================
/// Video Module (Desktop-first) — PotPlayer-like (v3) [Merged]
///
/// ✅ 主体以“大版本”为主
/// ✅ 合入“WebDAV 播放源”解析（webdav://accountId/xxx -> http(s)://user:pass@...）
///
/// ✅ 主要功能
/// - 控制栏自动隐藏 + 鼠标指针自动隐藏（更快：~1.6~1.8s）
/// - 拖动进度条：只显示预览，不实时 seek；松手才 seek（更像 PotPlayer）
/// - 目录：弹出式浮层（更“pop”），不影响播放；支持快捷键 L / Ctrl+L
/// - 右键菜单：全屏/倍速/打开目录/快捷键说明
/// - 右上方“热区”：鼠标停留自动弹出目录
///
/// ✅ 快捷键（桌面）
/// Space / K：播放暂停
/// ← / →：后退/前进 5s
/// ↑ / ↓：音量 +/-5
/// F：进入/退出全屏
/// L / Ctrl+L：打开目录
/// Esc：退出全屏 或 关闭目录/菜单
/// ===============================

class _EmbyRef {
  final String accountId;
  final String itemId;
  const _EmbyRef({required this.accountId, required this.itemId});
}

/// Emby 播放上报会话信息。
///
/// ✅ 设计原因：
/// - Emby 的 /Sessions/Playing(Progress/Stopped) 需要 PlaySessionId + MediaSourceId。
/// - 这些值应尽量来自 PlaybackInfo（由服务端生成），这样服务端才能正确识别会话、
///   正确记录进度/观看状态，并在停止时更及时地释放转码资源。
class _EmbyPlaybackSession {
  final EmbyAccount account;
  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final int? audioStreamIndex;
  int? subtitleStreamIndex;

  _EmbyPlaybackSession({
    required this.account,
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.audioStreamIndex,
    required this.subtitleStreamIndex,
  });
}

class _PlayerInteractionPolicy {
  static bool canOpenCatalog({
    required bool hasPlaylist,
    required bool isScreenLocked,
    required bool catalogEnabled,
    required bool menuAlreadyOpen,
  }) {
    return hasPlaylist && !isScreenLocked && catalogEnabled && !menuAlreadyOpen;
  }

  static bool canUseSeekGestures({
    required bool isScreenLocked,
    required bool lockPauseSeekEnabled,
  }) {
    return !isScreenLocked || lockPauseSeekEnabled;
  }

  static bool canUseVerticalGestures({
    required bool isScreenLocked,
  }) {
    return !isScreenLocked;
  }

  static bool canUseLongPressSpeed({
    required bool isScreenLocked,
    required bool longPressSpeedEnabled,
  }) {
    return !isScreenLocked && longPressSpeedEnabled;
  }
}

class VideoPlayerPage extends StatefulWidget {
  final List<String> videoPaths;
  final int initialIndex;

  const VideoPlayerPage({
    super.key,
    required this.videoPaths,
    required this.initialIndex,
  });

  @override
  State<VideoPlayerPage> createState() => _createVideoPlayerPageState();
}

State<VideoPlayerPage> _createVideoPlayerPageState() {
  final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  if (isMobile) return _MobileVideoPlayerPageState();
  return _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
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
  // ✅ 亮度：0~1。
  // 说明：移动端“系统亮度”通常需要原生权限/插件，这里采用“遮罩模拟亮度”方案，
  // 保证手势调整立刻可见，且不影响系统全局亮度。
  double _brightness = 1.0;

  // UI 状态
  bool _titleVisible = true;
  Timer? _titleTimer;
  // ✅ 默认不自动打开控制栏（按你的使用习惯：点进视频后保持“纯画面”）。
  // 说明：需要控制栏时，用户可以轻点底部热区唤出。
  // ✅ 进入播放器时默认不弹出控制栏（减少干扰，更贴近手机播放器习惯）。
  final _DesktopOrientationState _orientationState = _DesktopOrientationState();

  // ✅ 新增：传感器驱动的“画面旋转 + 原生强制旋转”
  // 说明：
  // 1) MIUI/部分 ROM 在“系统旋转锁”开启时只会弹出“旋转建议按钮”，不会自动旋转。
  // 2) 为了实现“不靠按钮自动横竖屏”，这里同时做两层兜底：
  //    - 画面旋转：即使屏幕没旋转，视频画面也会跟着旋转（保证一定有变化）。
  //    - 原生强制旋转：通过 MainActivity 的 MethodChannel 请求 requestedOrientation，尽量让屏幕也跟着转。
  final MethodChannel _oriChannel = const MethodChannel('glacier/orientation');
  StreamSubscription<NativeDeviceOrientation>? _nativeOriSub;

  // ✅ 新增：外部字幕（SRT）支持
  final _DesktopSubtitleState _subtitleState = _DesktopSubtitleState();

  // ✅ 新增：Emby 字幕轨道（通过 Emby API 获取）
  // ✅ 新增：Emby 字幕自动选择（仅在未手动选择时触发）
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

  // 目录弹窗
  bool get _canOpenCatalogPopup => _PlayerInteractionPolicy.canOpenCatalog(
        hasPlaylist: _hasPlaylist,
        isScreenLocked: _isScreenLocked,
        catalogEnabled: _videoCatalogEnabled,
        menuAlreadyOpen: _catalogOpen,
      );
  Timer? _catalogHotspotTimer;

  // 手势控制相关状态
  final _DesktopGestureState _gestureState = _DesktopGestureState();
  final ValueNotifier<_DesktopGestureOverlayViewData>
      _desktopGestureOverlayNotifier =
      ValueNotifier<_DesktopGestureOverlayViewData>(
          const _DesktopGestureOverlayViewData.inactive());

  // ===== 新增：设置相关缓存（避免每次 build 都 await） =====
  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;
  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  bool _showMiniProgressWhenHidden = true;
  bool _videoCatalogEnabled = true;

  // ✅ 播放结束行为：
  // - false：播放完暂停（默认）
  // - true ：自动下一集
  bool _autoNextAfterEnd = false;

  // ✅ 用于判断“是否刚到结尾”，以便在“播放完暂停”模式下拦截自动跳集。
  Duration _duration = Duration.zero;
  bool _nearEnd = false;

  // ✅ 历史记录写入策略（重要修复）
  //
  // 背景：当 videoPaths 是“目录内所有视频”的播放列表时，播放器在某些平台/网络失败场景下
  // 可能会短时间内多次触发 playlist index 变化（例如：初始化、解码失败自动跳过等）。
  // 如果在 index 变化时立即写入历史，就可能出现“只播放一个视频，但历史里被写入整个目录的视频”的现象。
  //
  // 解决：改为“起播后再写入”。仅当某个条目实际开始播放并且播放进度达到阈值后，才写入历史。
  // 这样可以避免：
  // - 目录播放列表被批量写入历史（未实际播放）
  // - 播放失败快速跳过导致历史污染
  static const int _historyMinPlayMs = 800; // 起播后至少播放 0.8s 才写入历史
  // ✅ 防抖：避免同一条目在极短时间内重复写入（例如 position 回调抖动/重入）。
  // 允许用户之后再次回到同一条目并正常刷新历史顺序。
  int _historyLastCommitAt = 0;
  String _historyLastCommitPath = '';
  String? _historyArmedPath;
  bool _historyArmed = false;

  // 长按倍速需要“暂存原倍速”，松开后恢复。
  double? _rateBeforeLongPress;

  // 拖动进度相关
  // Getters
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

  void _onAppSettingsChanged() {
    unawaited(_loadSettings());
  }

  Future<Media?> _createEmbyMediaAsync(
    String source,
    Map<String, EmbyAccount> accMap, {
    bool prefetchPlaybackInfo = false,
  }) async {
    try {
      final u = Uri.parse(source);
      final ref = parseEmbySourceRef(source);
      final accId = ref?.accountId.trim() ?? '';
      final itemId = ref?.itemId.trim() ?? '';
      if (accId.isEmpty || itemId.isEmpty) return null;

      final acc = accMap[accId];
      if (acc == null) return null;
      final client = EmbyClient(acc);

      // ✅ name 仅用于提升可读性；缺失也不影响实际播放。
      final name = (u.queryParameters['name'] ?? '').trim();
      // 超长 name 只会让 URL 更长，并不影响真实播放；超过阈值时不再带入 streamUrl。
      final streamName =
          name.isNotEmpty && name.runes.length <= 96 ? name : null;
      String? mediaSourceId;
      if (prefetchPlaybackInfo) {
        try {
          mediaSourceId = (await client
                  .playbackInfo(itemId)
                  .timeout(const Duration(seconds: 2), onTimeout: () => null))
              ?.mediaSourceId;
        } catch (_) {
          mediaSourceId = null;
        }
      }
      // ✅ 与 Emby 播放上报保持同一个 DeviceId。
      // 设计原因：
      // - Emby 以“设备”维度管理会话；
      // - 直连播放如果用固定 DeviceId，而上报又用另一个 DeviceId，服务端可能会出现
      //   “正在播放显示异常/停止不生效”等边缘情况。
      final deviceId = await EmbyStore.getOrCreateDeviceId();
      final url = client.streamUrl(
        itemId,
        name: streamName,
        deviceId: deviceId,
        mediaSourceId: mediaSourceId,
      );
      return Media(url);
    } catch (e) {
      debugPrint('Create Emby Media Error: $e');
      return null;
    }
  }

  Future<List<Media>> _buildMedias() async {
    final out = <Media>[];
    final accountCache = await (_webDavAccountCacheFuture ??
        Future.value(<String, Map<String, String>>{}));

    // ✅ Emby 账号缓存：避免播放列表里每一项都重复读 SharedPreferences。
    // 设计原因：
    // - emby:// 源需要先解析到 streamUrl 才能交给播放器；
    // - 读取一次账号列表并做 map 缓存，能显著减少频繁 IO。
    final embyAccs = await EmbyStore.load();
    final embyAccMap = {for (final a in embyAccs) a.id: a};

    for (int i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (isWebDavSource(s)) {
        final media = await _createWebDavMediaAsync(s, accountCache);
        if (media != null) {
          out.add(media);
        } else {
          debugPrint('WebDAV source failed: $s');
          out.add(Media('error://load_failed_placeholder_$i'));
        }
      } else if (isEmbySource(s)) {
        final media = await _createEmbyMediaAsync(
          s,
          embyAccMap,
          prefetchPlaybackInfo: i == _index,
        );
        if (media != null) {
          out.add(media);
        } else {
          debugPrint('Emby source failed: $s');
          out.add(Media('error://emby_failed_placeholder_$i'));
        }
      } else {
        out.add(Media(s));
      }
    }
    if (out.isEmpty && _sources.isNotEmpty) {
      return [Media('error://all_sources_failed')];
    }
    return out;
  }

  Future<Media?> _createWebDavMediaAsync(
      String source, Map<String, Map<String, String>> accounts) async {
    try {
      String accountId = '';
      String relEncoded = '';

      final ref = parseWebDavSource(source);
      if (ref == null) return null;
      accountId = ref.accountId;
      relEncoded = encodePathPreserveSlash(ref.relPath);

      final acc = accounts[accountId];
      if (acc == null) return null;

      final baseUrl = acc['baseUrl']!;
      final username = acc['username']!;
      final password = acc['password']!;

      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final resolvedUrl = Uri.parse(base).resolve(relEncoded).toString();
      final token = base64Encode(utf8.encode('$username:$password'));

      return Media(
        resolvedUrl,
        httpHeaders: <String, String>{
          HttpHeaders.authorizationHeader: 'Basic $token',
        },
      );
    } catch (e) {
      debugPrint(
          'Create WebDav Media Error: ${redactSensitiveText(e.toString())}');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _pageController = player_presentation.PlayerController()
      ..addListener(_refreshDesktopState);
    AppSettings.instance.addListener(_onAppSettingsChanged);

    // ✅ 初始化内部播放列表（可变）
    _sources = List<String>.from(widget.videoPaths);

    // ✅ 读取设置：字幕样式/交互（长按倍速、隐藏态细进度条等）。
    // 设计原因：这些值需要在视频页生命周期内稳定生效，避免用户操作时出现“忽快忽慢/忽大忽小”的体验。
    _loadSettings();

    // ✅ 按需求：进入视频页后默认不展示控制栏/图标。
    // 设计原因：避免“点开视频瞬间 UI 遮挡画面”，并减少误触。
    if (_isMobile) {
      _pageController.hideDesktopUi();
    }

    if (_isMobile) {
      // ✅ 移动端：开启沉浸式，允许所有方向（随重力感应）
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // ✅ 启动传感器驱动自动旋转：不依赖系统自动旋转开关。
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
      // ✅ Emby/HTTP 里有一类“稀疏交错”的 mp4（音视频块相距很远），
      // 如果 back-cache 太小，会在两个远距离 Range 间反复跳读，表现为
      // 服务端日志里大量 `206 + client disconnected`。
      //
      // 这里提高 demuxer 前/回读上限，尽量把“远距离回读”留在本地缓存内完成，
      // 减少高频断开重连。注意：这是上限，不是一次性常驻分配。
      mpv.setProperty('cache-secs', '45');
      mpv.setProperty('demuxer-max-bytes', '${192 * 1024 * 1024}');
      mpv.setProperty('demuxer-max-back-bytes', '${128 * 1024 * 1024}');
      mpv.setProperty('demuxer-readahead-secs', '120');
      mpv.setProperty('network-timeout', '60');
      // cache-pause 会在缓存不足时“停住画面”，体感像卡顿；这里关闭更像主流播放器。
      mpv.setProperty('cache-pause', 'no');
      mpv.setProperty(
          'user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) MediaKit');
      mpv.setProperty('force-window', 'yes');
    }

    _controller = VideoController(_player);

    _posSub = _player.stream.position.listen((v) {
      _insPos = v;
      // ✅ 重要：仅当“真正起播”后再写入历史，避免目录播放列表被误写入。
      _tryCommitHistoryRecord(v);

      if (_duration.inMilliseconds <= 0) return;
      final remainMs = _duration.inMilliseconds - v.inMilliseconds;
      // ✅ 记录是否接近结尾：用于“播放完暂停”模式下拦截自动跳集。
      // 设计原因：流媒体/解码器回调会有抖动，这里留一点容错。
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

    // ✅ 同步播放列表当前 index（用于字幕自动切换）
    _playlistSub = _player.stream.playlist.listen((pl) {
      final next = pl.index;
      if (next != _index && mounted) {
        final prev = _index;

        // ✅ “播放完暂停”模式：拦截播放器自动跳到下一集。
        // 设计原因：
        // - media_kit/mpv 在 Playlist 下默认会自动播下一条；
        // - 用户希望默认“播完就停在本集”，只有手动打开开关才自动下一集。
        if (!_autoNextAfterEnd && _nearEnd) {
          // 这里用 best-effort：先把 playlist index 拉回，再暂停。
          // 注意：部分设备上可能会出现 1 帧闪到下一集，这是 mpv 内部切片导致，
          // 但最终状态会稳定停在当前集。
          _player.jump(prev);
          _player.pause();
          // ✅ Emby：播完自动暂停也属于状态变化，补一次 Pause 上报。
          unawaited(_reportEmbyProgress(eventName: 'Pause'));
          return;
        }

        setState(() => _index = next);
        _autoLoadSrtIfAny();

        // ✅ Emby：切换条目后同步更新会话上报。
        // 说明：Emby 以 ItemId 为维度记录“正在播放/进度”，因此每次切换都需要上报。
        unawaited(
            _startEmbyPlaybackCheckInsIfNeeded(reason: 'playlistChanged'));

        // ✅ 切换到下一集/下一文件时：仅“起播后”再写入历史（避免列表被批量写入）。
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(redactSensitiveText(e.toString()))),
        );
      }
    });

    _uiVisible ? _pokeUI() : null;
  }

  Future<void> _loadSettings() async {
    try {
      final values = await Future.wait<Object?>([
        AppSettings.getSubtitleFontSize(),
        AppSettings.getSubtitleBottomOffset(),
        AppSettings.getLongPressSpeedEnabled(),
        AppSettings.getLongPressSpeedMultiplier(),
        AppSettings.getVideoMiniProgressWhenHidden(),
        AppSettings.getVideoCatalogEnabled(),
        AppSettings.getVideoAutoNextAfterEnd(),
      ]);
      final font = values[0] as double;
      final bottom = values[1] as double;
      final lpEnabled = values[2] as bool;
      final lpMul = values[3] as double;
      final miniProgress = values[4] as bool;
      final catalogEnabled = values[5] as bool;
      final autoNext = values[6] as bool;
      if (!mounted) return;
      setState(() {
        _subtitleFontSize = font;
        _subtitleBottomOffset = bottom;
        _longPressSpeedEnabled = lpEnabled;
        _longPressSpeedMultiplier = lpMul;
        _showMiniProgressWhenHidden = miniProgress;
        _videoCatalogEnabled = catalogEnabled;
        _autoNextAfterEnd = autoNext;
      });
    } catch (_) {
      // 设置读取失败不应影响播放：保持默认值。
    }
  }

  Future<void> _toggleEndBehavior() async {
    final next = !_autoNextAfterEnd;
    if (mounted) setState(() => _autoNextAfterEnd = next);
    try {
      await AppSettings.setVideoAutoNextAfterEnd(next);
    } catch (_) {
      // 设置持久化失败不影响本次播放体验。
    }
  }

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
    // 仅当：已 arm + 正在播放 + 播放达到阈值 + 尚未记录
    if (!_historyArmed) return;
    final path = (_historyArmedPath ?? '').trim();
    if (path.isEmpty) {
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_historyLastCommitPath == path && (now - _historyLastCommitAt) < 2500) {
      // 2.5s 内同一条目重复触发：认为是抖动，忽略。
      _historyArmed = false;
      _historyArmedPath = null;
      return;
    }

    // 关键：必须是“真正开始播放”，避免初始化/失败跳过导致历史污染
    final playing = _player.state.playing;
    if (!playing) return;
    if (pos.inMilliseconds < _historyMinPlayMs) return;

    _historyLastCommitAt = now;
    _historyLastCommitPath = path;
    _historyArmed = false;
    _historyArmedPath = null;
    // ignore: unawaited_futures
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
    // ✅ 写入历史记录：改为“起播后记录”，避免目录播放列表被误批量写入历史。
    // 说明：当播放真正开始且进度达到阈值后，才会写入。
    _armHistoryRecordForCurrent();
    // ✅ 自动读取同目录 .srt 字幕
    await _autoLoadSrtIfAny();

    // ✅ Emby 播放流程补全：启动播放上报（仪表盘显示/进度同步/停止释放）。
    // 设计原因：
    // - 仅拼接 streamUrl 直连播放会绕过 Emby 的会话管理；
    // - 上报是 best-effort，不影响播放主流程，因此这里用 unawaited。
    unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'initOpen'));
  }

  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) =>
      PlayerEmbySubtitleService.pickBestSubtitle(tracks);

  // ============================
  // Emby 字幕：解析/查询
  // ============================

  Future<EmbyAccount?> _getEmbyAccountById(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    try {
      final m = await (_embyAccountMapFuture ??=
          PlayerSourceResolver.loadEmbyAccountMap());
      final acc = m[id];
      if (acc != null) return acc;
    } catch (_) {}

    // ✅ 兜底：如果 Future 缓存没初始化/读取失败，直接读本地存储。
    try {
      final list = await EmbyStore.load();
      return list.firstWhereOrNull((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 尝试从“当前播放源”解析出 Emby 账号与 ItemId。
  ///
  /// ✅ 设计原因：
  /// - 播放器里很多功能（外挂字幕、播放上报、目录补全）都需要 itemId；
  /// - 但播放源既可能是 emby:// 协议，也可能是历史遗留的 http streamUrl。
  /// - 这里统一解析，避免各处逻辑分叉导致遗漏。
  Future<PlayerEmbyNowPlaying?> _resolveEmbyNowPlaying(String source) {
    return PlayerEmbySubtitleService.resolveNowPlaying(
      source,
      getAccountById: _getEmbyAccountById,
      resolveAccountForStream: _resolveEmbyAccountForStream,
    );
  }

  Future<String?> _buildEmbySubtitleUrl(EmbySubtitleTrack track) async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) return null;
    final client = EmbyClient(np.account);
    final deviceId = await EmbyStore.getOrCreateDeviceId();
    return client.subtitleStreamUrl(
      itemId: np.itemId,
      mediaSourceId: track.mediaSourceId,
      subtitleIndex: track.index,
      // Emby 通常可以转成 srt，兼容性最好
      format: 'srt',
      deviceId: deviceId,
    );
  }

  Future<EmbyAccount?> _resolveEmbyAccountForStream(String url) async {
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

  Widget _buildRotatedVideo(Widget video) {
    if (!_isMobile) return video;

    // ✅ 说明：这里做“画面旋转”而不是依赖系统旋转。
    // - 当系统旋转锁开启，屏幕可能不旋转；但画面旋转一定能生效。
    // - 为了避免旋转后画面被拉伸，这里交换约束宽高来适配 90/270 度。
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
    // ✅ 退出时写入进度：
    // 设计原因：历史列表里展示“上次看到哪里”可以显著提升找回内容的效率。
    // 注意：这里仅做 best-effort，失败不阻断 dispose。
    try {
      final path = _currentPath;
      if (path.trim().isNotEmpty) {
        AppHistory.updateProgress(
            path: path, positionMs: _insPos.inMilliseconds);
      }
    } catch (_) {}

    unawaited(_stopEmbyPlaybackCheckIns(reason: 'desktop dispose'));

    // ✅ 退出播放器：停止自动旋转监听，并解锁原生方向锁，避免影响其它页面。
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

    // 恢复默认状态
    // ✅ 不再强制回到竖屏：
    // 用户诉求是“播放器横竖屏自动切换，不用按钮”。
    // 如果这里强制设回 portraitUp，会让系统认为 App 只能竖屏，
    // 下一次进入播放器时就容易出现“必须点按钮才能横屏”的体验。
    //
    // 因此这里恢复为“允许所有方向”，把旋转权交给系统与用户。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_kDarkStatusBarStyle);

    _desktopGestureOverlayNotifier.dispose();
    _player.dispose();
    super.dispose();
  }

  void _pokeUI() {
    _pageController.showDesktopUi();
    if (_isDesktop) {
      _pageController.showDesktopCursor();
      _showTitleHint();
    }
    _pageController.scheduleDesktopUiHide(
      delay: _hideDelay,
      enabled: true,
      onHide: () {
        if (!mounted) return;
        _pageController.hideDesktopUi();
      },
    );
    if (_isDesktop) {
      _pageController.scheduleDesktopCursorHide(
        delay: _cursorDelay,
        enabled: true,
        onHide: () {
          if (!mounted) return;
          _pageController.hideDesktopCursor();
        },
      );
    }
  }

  /// 轻量提示（尽量不打断播放）。这里不用第三方 toast，避免额外依赖。
  void _toast(String msg) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    } catch (_) {
      // 某些情况下（如 context 不在 Scaffold 树下）SnackBar 会失败，这里静默忽略即可。
    }
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

  // 桌面端全屏逻辑保持不变，移动端主要依赖锁定逻辑
  Future<void> _toggleFullscreen() async {
    if (_isMobile) return; // 移动端不再使用此方法切换全屏
    final next = !_isFullscreen;
    if (mounted) setState(() => _isFullscreen = next);
  }

  // ✅ 新增：屏幕方向锁定/解锁逻辑
  Future<void> _toggleScreenLock() async {
    setState(() => _isScreenLocked = !_isScreenLocked);

    if (_isScreenLocked) {
      // ✅ 用户明确“锁定方向”时：关闭自动旋转，避免系统/传感器与锁定策略互相打架。
      _autoRotateEnabled = false;
      _stopAutoRotateIfAny();

      // 锁定：以当前画面方向为准（优先使用 _videoQuarterTurns，避免屏幕未旋转时判断错误）
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
      // 解锁：允许所有方向，并恢复自动旋转
      _autoRotateEnabled = true;
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await _unlockNativeOrientation();

      // ✅ 解除锁定后，传感器首帧可能存在抖动/错误判定，直接启动会造成画面瞬间“歪到奇怪的方向”。
      // 这里做两步处理：
      // 1) 清空稳定判定缓存
      // 2) 轻微延迟后再启动自动旋转，给系统一次同步当前方向的机会
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

    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);

    // ✅ 需求：去除“弹出动画”，改为“直接出现”。
    // showMenu / showModalBottomSheet 都会带默认动画；这里用 showGeneralDialog 且 transitionDuration=0。
    final selected = await showGeneralDialog<double>(
      context: buttonContext,
      barrierDismissible: true,
      barrierLabel: '倍速',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, anim1, anim2) {
        const items = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        const w = 160.0;
        // 尽量让菜单出现在按钮上方；空间不够则向下
        final top = (pos.dy - items.length * 44 - 8) > 0
            ? (pos.dy - items.length * 44 - 8)
            : (pos.dy + box.size.height + 8);
        final left = (pos.dx).clamp(8.0, overlay.size.width - w - 8);

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(ctx).pop(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: w,
              child: Material(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final v = items[i];
                    final selected = (v == _rate);
                    return InkWell(
                      onTap: () => Navigator.of(ctx).pop(v),
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$v 倍',
                                style: TextStyle(
                                  color:
                                      selected ? Colors.white : Colors.white70,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (selected)
                              const Icon(Icons.check,
                                  color: Colors.white, size: 18),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    if (selected == null) return;
    setState(() => _rate = selected);
    try {
      await _player.setRate(selected);
    } catch (e) {
      _toast('设置倍速失败：$e');
    }

    // ✅ Emby：倍速属于会话状态的一部分，建议按官方事件名上报。
    unawaited(_reportEmbyProgress(
        eventName: 'PlaybackRateChange', interactive: true));
    _pokeUI();
  }

  Future<void> _showCatalogPopup({bool fromHotspot = false}) async {
    if (!_canOpenCatalogPopup) return;
    _pokeUI();
    _pageController.setDesktopCatalogOpen(true);
    int? picked;
    try {
      // ✅ 目录增强：如果当前只有 1 条播放源（常见：从历史打开），尝试补全同目录/同季播放列表。
      // 仅在“第一次打开目录”时触发，避免反复网络请求。
      if (_sources.length <= 1 && !_sourcesExpandedOnce) {
        await _runWithBusyDialog(
          () => _ensureCatalogSourcesReady(),
          message:
              PlayerUiTextService.catalogLoadingMessage(initialExpansion: true),
        );
      }

      // ✅ 目录封面预热：优先预热“当前集 + 前后各 2 集”，让打开目录时就能看到封面。
      // 说明：移动端边播边拉封面可能抢带宽，因此仅做小范围预热，且并发=1。
      _prefetchCatalogThumbsAround(_index);

      if (_isMobile) {
        picked = await _showCatalogBottomSheetMobile();
      } else {
        picked = await _showCatalogSidePanelDesktop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('目录打开失败：${redactSensitiveText(e.toString())}'),
          ),
        );
      }
      return;
    } finally {
      if (mounted) {
        _pageController.setDesktopCatalogOpen(false);
      }
    }

    if (!mounted) return;
    if (picked != null && picked != _index) {
      setState(() => _index = picked!);
      await _player.jump(_index);

      // ✅ 手动切换条目时，playlist listener 不一定会触发（因为我们提前 setState 了 index）。
      // 因此这里显式补齐：字幕自动加载 + Emby 会话上报。
      unawaited(_autoLoadSrtIfAny());
      unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'catalogPick'));

      // ✅ 手动切换条目：同样采用“起播后写入历史”，避免跳转瞬间污染。
      _armHistoryRecordForCurrent();
      _uiVisible ? _pokeUI() : null;
    }
  }

  // ============================
  // 目录 UI（移动端优先）
  // ============================

  Future<int?> _showCatalogBottomSheetMobile() async {
    // ✅ 移动端：用 BottomSheet 更符合手感，也更适配单手操作。
    // - isScrollControlled 允许拉到接近全屏
    // - 顶部圆角 + SafeArea
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
                                  // 刷新后预热当前集附近封面
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
    // ✅ Emby：用户操作需要立即上报 Pause/Unpause。
    unawaited(_reportEmbyProgress(eventName: playing ? 'Pause' : 'Unpause'));
    _uiVisible ? _pokeUI() : null;
  }

  Future<void> _seekBy(int seconds) async {
    final cur = _player.state.position;
    await _player.seek(cur + Duration(seconds: seconds));
    // ✅ Emby：拖动/快进快退属于“用户交互”，需要立即上报一次。
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
    _uiVisible ? _pokeUI() : null;
  }

  Future<void> _runWithBusyDialog(Future<void> Function() job,
      {String message = '正在加载...'}) async {
    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    bool popped = false;

    // 以“轻量阻塞”的方式提示用户：目录/播放列表正在补全。
    // 设计原因：
    // - WebDAV/Emby 目录拉取需要网络；
    // - 不阻塞会导致用户误以为按钮没反应而重复点击。
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

  // 手势处理
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
                : null, // 锁定状态下稍微限制手势防止误触(可选)
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

            // 若要锁定状态下依然允许手势，将上面的 && !_isScreenLocked 去掉即可。
            // 建议：保留手势，下面的 onHorizontalDragStart: _isMobile ? _onHorizontalDragStart : null, 即可

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

            // ✅ 必选功能：长按屏幕触发“倍数播放”。
            // 交互规则：
            // - 按住：临时将倍速提升为“当前倍速 * 乘数”；
            // - 松开：恢复到原倍速；
            // - 若用户在设置中关闭此功能，则不生效。
            onLongPressStart: _isMobile &&
                    _PlayerInteractionPolicy.canUseLongPressSpeed(
                      isScreenLocked: _isScreenLocked,
                      longPressSpeedEnabled: _longPressSpeedEnabled,
                    )
                ? (_) async {
                    if (!_ready) return;
                    // 防抖：如果系统回调多次，确保只提升一次。
                    if (_rateBeforeLongPress != null) return;

                    _rateBeforeLongPress = _rate;
                    final target =
                        (_rate * _longPressSpeedMultiplier).clamp(0.25, 8.0);

                    try {
                      await _player.setRate(target);
                      if (mounted) setState(() => _rate = target);
                    } catch (e) {
                      // 如果倍速设置失败，避免“卡在未知状态”，立刻回滚。
                      final back = _rateBeforeLongPress;
                      _rateBeforeLongPress = null;
                      if (back != null) {
                        try {
                          await _player.setRate(back);
                        } catch (_) {}
                        if (mounted) setState(() => _rate = back);
                      }
                      // ✅ 按需求：长按倍速不弹任何提示。
                      // 说明：失败时也不打断用户，只做静默回滚。
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
                                shadows: const [
                                  Shadow(
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                      color: Colors.black),
                                  Shadow(
                                      offset: Offset(-1, 1),
                                      blurRadius: 2,
                                      color: Colors.black),
                                ],
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

                  // ✅ 亮度遮罩（解决“亮度调整没有反应”）：
                  // - brightness=1：不遮罩
                  // - brightness 越小，黑色遮罩越重，画面越暗
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withValues(
                            alpha: (1.0 - _brightness).clamp(0.0, 1.0) * 0.75),
                      ),
                    ),
                  ),

                  // 缓冲提示：仅在实际 buffering 时显示，避免误导。
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

/// ===============================
/// 让 Slider 轨道“铺满”整个可用宽度
/// ===============================
/// 默认 Slider 会在两端留出 thumb 半径的 padding，导致进度条看起来像“有一小节没包进去”。
/// 这里重写 getPreferredRect，让轨道从 0 开始到最右侧结束。
class _FullWidthSliderTrackShape extends RoundedRectSliderTrackShape {
  const _FullWidthSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 2.0;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

class _MobileResolvedSource {
  final Uri? networkUri;
  final String? localPath;
  final Map<String, String> headers;
  final String title;

  const _MobileResolvedSource.network(
    this.networkUri, {
    required this.title,
    this.headers = const <String, String>{},
  }) : localPath = null;

  const _MobileResolvedSource.local(
    this.localPath, {
    required this.title,
  })  : networkUri = null,
        headers = const <String, String>{};

  bool get isLocal => localPath != null && localPath!.trim().isNotEmpty;
}

class _MobileVideoPlayerPageState extends State<VideoPlayerPage>
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

  Future<void> _loadMobileSettings() async {
    try {
      final values = await Future.wait<Object?>([
        AppSettings.getSubtitleFontSize(),
        AppSettings.getSubtitleBottomOffset(),
        AppSettings.getLongPressSpeedEnabled(),
        AppSettings.getLongPressSpeedMultiplier(),
        AppSettings.getVideoAutoNextAfterEnd(),
        AppSettings.getVideoResumeEnabled(),
        AppSettings.getVideoMiniProgressWhenHidden(),
        AppSettings.getVideoCatalogEnabled(),
        AppSettings.getVideoEpisodeNavButtonsEnabled(),
        AppSettings.getVideoLockPauseSeekEnabled(),
        AppSettings.getVideoCatalogLocateCurrentOnOpen(),
        AppSettings.getDoubleTapSeekSeconds(),
      ]);
      final subtitleFont = values[0] as double;
      final subtitleBottom = values[1] as double;
      final lpEnabled = values[2] as bool;
      final lpMul = values[3] as double;
      final autoNext = values[4] as bool;
      final resumeEnabled = values[5] as bool;
      final miniProgress = values[6] as bool;
      final catalogEnabled = values[7] as bool;
      final episodeNavButtonsEnabled = values[8] as bool;
      final lockPauseSeekEnabled = values[9] as bool;
      final catalogLocateCurrentOnOpen = values[10] as bool;
      final dblTap = values[11] as int;
      if (!mounted) return;
      setState(() {
        _subtitleFontSize = subtitleFont.clamp(12.0, 48.0);
        _subtitleBottomOffset = subtitleBottom.clamp(0.0, 200.0);
        _longPressSpeedEnabled = lpEnabled;
        _longPressSpeedMultiplier = lpMul;
        _autoNextAfterEnd = autoNext;
        _videoResumeEnabled = resumeEnabled;
        _showMiniProgressWhenHidden = miniProgress;
        _videoCatalogEnabled = catalogEnabled;
        _videoEpisodeNavButtonsEnabled = episodeNavButtonsEnabled;
        _lockPauseSeekEnabled = lockPauseSeekEnabled;
        _catalogLocateCurrentOnOpen = catalogLocateCurrentOnOpen;
        _doubleTapSeekSeconds = dblTap.clamp(5, 60);
      });
    } catch (_) {}
  }

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
    if (position.inMilliseconds < _historyMinPlayMs) return;

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

  Future<int?> _loadResumePositionMs(String path) async {
    return PlayerHistoryService.loadResumePositionMs(path);
  }

  Future<void> _beforeRouteExit({String reason = 'mobile pop'}) async {
    if (_exitCleanupDone) return;
    _exitCleanupDone = true;
    _dismissResumeHint(clearBinding: true);
    _stopAutoRotateIfAny();
    _autoRotateEnabled = false;
    _appliedNativeOri = NativeDeviceOrientation.unknown;
    try {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } catch (_) {}
    try {
      await _mobileOriChannel.invokeMethod('unlock');
    } catch (_) {}
    final c = _controller;
    if (c != null) {
      try {
        await c.pause();
      } catch (_) {}
    }
    await _flushHistoryProgress();
    unawaited(_stopEmbyPlaybackCheckIns(reason: reason));
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

    if (mounted) {
      setState(() {
        _resumeHintVisible = false;
        _resumeHintText = '';
      });
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

  Future<_MobileResolvedSource> _resolveEmbySource(String source) async {
    final ref = _parseEmbyRef(source);
    if (ref == null) {
      throw Exception('不支持的 Emby 源：$source');
    }

    _embyAccounts ??= await PlayerSourceResolver.loadEmbyAccountMap();
    final acc = _embyAccounts![ref.accountId];
    if (acc == null) {
      throw Exception('Emby 账号不存在：${ref.accountId}');
    }

    final client = EmbyClient(acc);
    final name = (() {
      try {
        final u = Uri.parse(source);
        return (u.queryParameters['name'] ?? '').trim();
      } catch (_) {
        return '';
      }
    })();
    final streamName = name.isNotEmpty && name.runes.length <= 96 ? name : null;
    String? mediaSourceId;
    try {
      mediaSourceId = (await client
              .playbackInfo(ref.itemId)
              .timeout(const Duration(seconds: 2), onTimeout: () => null))
          ?.mediaSourceId;
    } catch (_) {}

    final deviceId = await EmbyStore.getOrCreateDeviceId();
    final url = client.streamUrl(
      ref.itemId,
      name: streamName,
      deviceId: deviceId,
      mediaSourceId: mediaSourceId,
    );
    return _MobileResolvedSource.network(
      Uri.parse(url),
      title: PlayerSourceResolver.displayName(source),
    );
  }

  Future<_MobileResolvedSource> _resolveWebDavSource(String source) async {
    _webDavAccounts ??= await PlayerSourceResolver.loadWebDavAccountCache();
    final resolved = await PlayerSourceResolver.resolveWebDavSource(
      source,
      accounts: _webDavAccounts,
    );
    return _MobileResolvedSource.network(
      resolved.uri,
      title: resolved.title,
      headers: resolved.headers,
    );
  }

  Future<_MobileResolvedSource> _resolveSource(String source) async {
    if (isEmbySource(source)) return _resolveEmbySource(source);
    if (isWebDavSource(source)) return _resolveWebDavSource(source);
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return _MobileResolvedSource.network(
        Uri.parse(source),
        title: PlayerSourceResolver.displayName(source),
      );
    }
    return _MobileResolvedSource.local(
      source,
      title: PlayerSourceResolver.displayName(source),
    );
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
    if (np == null) return null;
    final client = EmbyClient(np.account);
    final deviceId = await EmbyStore.getOrCreateDeviceId();
    return client.subtitleStreamUrl(
      itemId: np.itemId,
      mediaSourceId: track.mediaSourceId,
      subtitleIndex: track.index,
      format: 'srt',
      deviceId: deviceId,
    );
  }

  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) =>
      PlayerEmbySubtitleService.pickBestSubtitle(tracks);

  Future<void> _refreshEmbySubtitleCandidatesIfAny() async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) {
      _embySubtitleCandidates = <EmbySubtitleTrack>[];
      _embySubtitleSelected = null;
      if (mounted) setState(() {});
      return;
    }
    try {
      final tracks = await EmbyClient(np.account).listSubtitleTracks(np.itemId);
      _embySubtitleCandidates = tracks;
      if (_embySubtitleSelected != null) {
        final keep = tracks.firstWhereOrNull(
          (t) =>
              t.index == _embySubtitleSelected!.index &&
              t.mediaSourceId == _embySubtitleSelected!.mediaSourceId,
        );
        _embySubtitleSelected = keep;
      }
      if (mounted) setState(() {});
    } catch (_) {
      _embySubtitleCandidates = <EmbySubtitleTrack>[];
      _embySubtitleSelected = null;
      if (mounted) setState(() {});
    }
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

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _refreshMobileState() {
    if (!mounted) return;
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
      _openingLabel = PlayerUiTextService.openingLabel(
        hasExistingController: _controller != null,
      );
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
      int? resumedAtMs;

      _title = resolved.title;
      if (resolved.isLocal) {
        nextController = VideoPlayerController.file(File(resolved.localPath!));
      } else {
        nextController = VideoPlayerController.networkUrl(
          resolved.networkUri!,
          httpHeaders: resolved.headers,
        );
      }
      await nextController.initialize();
      await nextController.setLooping(false);
      await nextController.setPlaybackSpeed(_rate);
      await nextController.setVolume((_volume / 100).clamp(0, 1).toDouble());

      int? resumeMs;
      if (_videoResumeEnabled) {
        resumeMs = await _loadResumePositionMs(source);
      }
      if (!mounted || seq != _openSeq) {
        await nextController.dispose();
        return;
      }
      if (resumeMs != null) {
        try {
          final durMs = nextController.value.duration.inMilliseconds;
          final safeMaxMs = max(0, durMs - 1200);
          final targetMs = resumeMs.clamp(0, safeMaxMs);
          if (targetMs > 0) {
            await nextController.seekTo(Duration(milliseconds: targetMs));
            resumedAtMs = targetMs;
          }
        } catch (_) {}
      }

      nextController.addListener(_onControllerTick);

      if (!mounted || seq != _openSeq) {
        nextController.removeListener(_onControllerTick);
        await nextController.dispose();
        return;
      }

      final old = _controller;
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
      unawaited(_syncOrientationFromSensor(force: true));
      _scheduleAutoHide();
      unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'mobile open'));
      unawaited(_prepareSubtitleForCurrent());
      _armHistoryRecordForCurrent();
      if (resumedAtMs != null && resumedAtMs > 0) {
        unawaited(_showResumeHint(resumedAtMs, source));
      }

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
      await c.pause();
      _pageController.showControls();
      _pageController.cancelAutoHide();
      _showGestureOverlay('暂停', Icons.pause_rounded);
      unawaited(_reportEmbyProgress(eventName: 'Pause'));
    } else {
      await c.play();
      _scheduleAutoHide();
      _showGestureOverlay('播放', Icons.play_arrow_rounded);
      unawaited(_reportEmbyProgress(eventName: 'Unpause'));
    }
  }

  Future<void> _setPlaybackRate(double next) async {
    final rate = next.clamp(0.25, 3.0).toDouble();
    _rate = rate;
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        await c.setPlaybackSpeed(rate);
      } catch (_) {}
    }
    if (mounted) setState(() {});
    unawaited(
      _reportEmbyProgress(eventName: 'PlaybackRateChange', interactive: true),
    );
  }

  Future<void> _showSpeedMenu() async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        const options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final r in options)
                ListTile(
                  title: Text(
                    '${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 2)}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: (_rate - r).abs() < 0.001
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                  onTap: () => Navigator.pop(ctx, r),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      await _setPlaybackRate(picked);
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final cur = c.value.position;
    final dur = c.value.duration;
    var target = cur + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await c.seekTo(target);
    _scheduleAutoHide();
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
  }

  Future<void> _jumpTo(int newIndex) async {
    if (newIndex < 0 || newIndex >= _sources.length) return;
    await _flushHistoryProgress();
    setState(() {
      _index = newIndex;
      _openingLabel = PlayerUiTextService.switchingLabel(_currentPath);
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
                        color: Colors.black.withValues(alpha: 0.55),
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
