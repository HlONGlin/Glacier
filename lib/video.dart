import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'tag.dart';
import 'utils.dart';
import 'image.dart';
import 'inspector.dart';
import 'emby.dart';
import 'dart:collection';
import 'dart:math';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

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
/// ✅ 主体以“大版本”为主（带 Anime4K Profile 链式方案）
/// ✅ 合入“WebDAV 播放源”解析（webdav://accountId/xxx -> http(s)://user:pass@...）
///
/// ✅ 主要功能
/// - 控制栏自动隐藏 + 鼠标指针自动隐藏（更快：~1.6~1.8s）
/// - 拖动进度条：只显示预览，不实时 seek；松手才 seek（更像 PotPlayer）
/// - 目录：弹出式浮层（更“pop”），不影响播放；支持快捷键 L / Ctrl+L
/// - 右键菜单：全屏/倍速/打开目录/快捷键说明/Anime4K
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

String? _anime4kShaderDirOnDisk;

/// 播放器内“目录/同文件夹播放列表”按需扩容结果。
///
/// - sources：扩容后的 sources 列表
/// - index：当前播放条目在扩容列表中的索引
class _ExpandedPlaylist {
  final List<String> sources;
  final int index;
  const _ExpandedPlaylist({required this.sources, required this.index});
}

class _WebDavRef {
  final String accountId;
  final String relPath; // decoded (no leading slash)
  const _WebDavRef({required this.accountId, required this.relPath});
}

class _WebDavListItem {
  final String name;
  final String relPath; // decoded (no leading slash)
  final bool isDir;
  final int size;
  final DateTime? modified;
  const _WebDavListItem({
    required this.name,
    required this.relPath,
    required this.isDir,
    required this.size,
    required this.modified,
  });
}

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

/// 当前播放源解析出的 Emby 信息（账号 + ItemId）。
///
/// 说明：播放器内部可能持有两种 Emby 来源：
/// - emby://<accountId>/item:<itemId>?name=...
/// - http(s)://.../Videos/<itemId>/stream?...（极少数场景，比如历史记录里存了直链）
///
/// 因此这里用一个统一结构，避免在“字幕/上报/目录”等多个功能里重复判断。
class _EmbyNowPlaying {
  final EmbyAccount account;
  final String itemId;
  const _EmbyNowPlaying({required this.account, required this.itemId});
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
  _EmbyPlaybackSession? _embyPlayback;
  Timer? _embyProgressTimer;

  /// 发送上报的串行队列（避免并发多次 POST 导致顺序错乱）。
  Future<void> _embyReportQueue = Future.value();

  /// 降噪：记录最近一次主动上报时间，用于避免用户频繁操作时“刷爆服务端”。
  DateTime _embyLastInteractiveReportAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放器目录：WebDAV 视频 → 同目录“侧边封面图”（若存在）
  /// - key: 视频 source（webdav://...）
  /// - value: 图片 source（webdav://... 指向 jpg/png/webp）
  final Map<String, String> _webDavSidecarCoverByVideoSource =
      <String, String>{};

  /// WebDAV：目录缩略图生成（前缀下载 + 抽帧）Future 缓存
  final Map<String, Future<File?>> _webDavVideoThumbFutureCache =
      <String, Future<File?>>{};

  /// WebDAV：source → (url, headers) 解析 Future 缓存
  final Map<String, Future<({String url, Map<String, String> headers})?>>
      _webDavResolveFutureCache =
      <String, Future<({String url, Map<String, String> headers})?>>{};

  /// 目录缩略图任务并发控制（移动端：避免边播边疯狂拉封面导致卡顿）
  final AsyncSemaphore _catalogThumbSemaphore = AsyncSemaphore(1);

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
  bool _uiVisible = false;
  bool _cursorHidden = false;
  Timer? _uiHideTimer;
  Timer? _cursorHideTimer;
  bool _isFullscreen = false; // 仅桌面端使用逻辑，移动端主要靠重力感应

  // ✅ 新增：屏幕方向锁定状态
  bool _isScreenLocked = false;

  // ✅ 新增：传感器驱动的“画面旋转 + 原生强制旋转”
  // 说明：
  // 1) MIUI/部分 ROM 在“系统旋转锁”开启时只会弹出“旋转建议按钮”，不会自动旋转。
  // 2) 为了实现“不靠按钮自动横竖屏”，这里同时做两层兜底：
  //    - 画面旋转：即使屏幕没旋转，视频画面也会跟着旋转（保证一定有变化）。
  //    - 原生强制旋转：通过 MainActivity 的 MethodChannel 请求 requestedOrientation，尽量让屏幕也跟着转。
  final MethodChannel _oriChannel = const MethodChannel('glacier/orientation');
  StreamSubscription<NativeDeviceOrientation>? _nativeOriSub;
  NativeDeviceOrientation _appliedNativeOri = NativeDeviceOrientation.unknown;
  NativeDeviceOrientation? _lastOriCandidate;
  int _oriStableCount = 0;
  DateTime _lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _videoQuarterTurns = 0;
  bool _autoRotateEnabled = true;

  // ✅ 新增：外部字幕（SRT）支持
  List<String> _srtCandidates = <String>[];
  String? _srtSelected;
  bool _srtEnabled = false;

  // ✅ 新增：Emby 字幕轨道（通过 Emby API 获取）
  List<EmbySubtitleTrack> _embySubtitleCandidates = <EmbySubtitleTrack>[];
  EmbySubtitleTrack? _embySubtitleSelected;

  // ✅ 新增：Emby 字幕自动选择（仅在未手动选择时触发）
  String? _lastAutoSubtitleItemId;
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

  // Anime4K
  String? _anime4kSelection;
  final Map<String, String> _shaderDiskCache = <String, String>{};

  // 目录弹窗
  bool _catalogOpen = false;
  Timer? _catalogHotspotTimer;

  // 手势控制相关状态
  bool _gestureActive = false;
  String _gestureType = ''; // 'seek', 'volume', 'brightness'
  String _gestureText = '';
  IconData? _gestureIcon;

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
  Duration _dragStartPos = Duration.zero;
  Duration _dragTargetPos = Duration.zero;
  double _dragAccumulator = 0.0;
  double _dragStartVal = 0.0;

  // Getters
  bool get _hasPlaylist => _sources.isNotEmpty;
  bool get _isDesktop => !kIsWeb && !Platform.isAndroid && !Platform.isIOS;
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  String get _currentPath => _hasPlaylist ? _sources[_index] : '';
  String get _title => _hasPlaylist ? _displayName(_currentPath) : '视频播放';

  static const _hideDelay = Duration(seconds: 5);
  static const _cursorDelay = Duration(milliseconds: 1600);

  // WebDAV Helpers (保持不变)
  Future<Map<String, Map<String, String>>> _loadWebDavAccountCache() async {
    final out = <String, Map<String, String>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('webdav_accounts_v1');
      if (raw == null || raw.trim().isEmpty) return out;
      final List list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is Map) {
          final id = (e['id'] ?? '').toString();
          final baseUrl = (e['baseUrl'] ?? '').toString();
          final username = (e['username'] ?? '').toString();
          final password = (e['password'] ?? '').toString();
          if (id.isNotEmpty && baseUrl.isNotEmpty) {
            out[id] = {
              'baseUrl': baseUrl,
              'username': username,
              'password': password,
            };
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading webdav accounts: $e');
    }
    return out;
  }

  Future<Map<String, EmbyAccount>> _loadEmbyAccountMap() async {
    try {
      final list = await EmbyStore.load();
      final m = <String, EmbyAccount>{};
      for (final a in list) {
        if (a.id.trim().isEmpty) continue;
        m[a.id] = a;
      }
      return m;
    } catch (e) {
      debugPrint('Error loading emby accounts: $e');
      return <String, EmbyAccount>{};
    }
  }

  bool _isWebDavSource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'webdav' && u.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _isEmbySource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'emby' && u.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Media?> _createEmbyMediaAsync(
    String source,
    Map<String, EmbyAccount> accMap, {
    bool prefetchPlaybackInfo = false,
  }) async {
    try {
      // source: emby://<accId>/item:<itemId>?name=xxx
      final u = Uri.parse(source);
      final accId = u.host.trim();
      final raw = u.path.startsWith('/') ? u.path.substring(1) : u.path;
      final m = RegExp(r'^item:([^/?#]+)').firstMatch(raw);
      final itemId = m?.group(1) ?? '';
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

  String _displayName(String source) {
    if (_isEmbySource(source)) {
      // ✅ Emby：优先使用 name 参数（由列表页传入），避免显示 item:xxx。
      try {
        final u = Uri.parse(source);
        final name = (u.queryParameters['name'] ?? '').trim();
        if (name.isNotEmpty) return safeDecodeUriComponent(name);
      } catch (_) {}
      return 'Emby 媒体';
    }
    if (_isWebDavSource(source)) {
      final u = Uri.parse(source);
      final rel = u.path.startsWith('/') ? u.path.substring(1) : u.path;
      final base = rel.split('/').isEmpty ? rel : rel.split('/').last;
      return safeDecodeUriComponent(base);
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      try {
        final u = Uri.parse(source);
        // ✅ Emby：如果 URL 带了 name 参数，则优先用它显示标题。
        // 设计原因：Emby 的播放地址通常是 /Videos/<id>/stream，直接取 pathSegments 会得到 stream，
        // 不符合用户认知；携带 name 后可以稳定显示“真实文件名”。
        final qName = (u.queryParameters['name'] ?? '').trim();
        if (qName.isNotEmpty) return qName;
        if (u.pathSegments.isNotEmpty) {
          return safeDecodeUriComponent(u.pathSegments.last);
        }
      } catch (_) {}
    }
    return p.basename(source);
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
      if (_isWebDavSource(s)) {
        final media = await _createWebDavMediaAsync(s, accountCache);
        if (media != null) {
          out.add(media);
        } else {
          debugPrint('WebDAV source failed: $s');
          out.add(Media('error://load_failed_placeholder_$i'));
        }
      } else if (_isEmbySource(s)) {
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
      int? sizeHint;
      String? contentTypeHint;

      try {
        final u = Uri.parse(source);
        accountId = u.host;
        sizeHint = int.tryParse(u.queryParameters['size'] ?? '');
        contentTypeHint = u.queryParameters['ct'];
        final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
        relEncoded = segs.map(Uri.encodeComponent).join('/');
      } catch (_) {
        const prefix = 'webdav://';
        if (!source.startsWith(prefix)) return null;
        final raw = source.substring(prefix.length);
        final slash = raw.indexOf('/');
        if (slash == -1) return null;
        accountId = raw.substring(0, slash);
        var relRaw = raw.substring(slash + 1);
        relRaw = relRaw.split('?').first.split('#').first;
        final segs = relRaw.split('/').where((s) => s.isNotEmpty).map((seg) {
          var decoded = seg;
          try {
            decoded = safeDecodeUriComponent(seg);
          } catch (_) {
            try {
              decoded = safeDecodeUriComponent(seg.replaceAll('%', '%25'));
            } catch (_) {
              decoded = seg;
            }
          }
          return Uri.encodeComponent(decoded);
        }).toList();
        relEncoded = segs.join('/');
      }

      final acc = accounts[accountId];
      if (acc == null) return null;

      final baseUrl = acc['baseUrl']!;
      final username = acc['username']!;
      final password = acc['password']!;

      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final resolvedUrl = Uri.parse(base).resolve(relEncoded).toString();
      final token = base64Encode(utf8.encode('$username:$password'));

      final remoteUri = Uri.parse(resolvedUrl);
      final directUrl =
          remoteUri.replace(userInfo: '$username:$password').toString();

      if (Platform.isAndroid) {
        return Media(directUrl);
      }

      // ✅ 仅安卓手机使用：统一走直连（带 userInfo 的 basic auth），避免依赖桌面端本地代理。
      return Media(directUrl);
    } catch (e) {
      debugPrint(
          'Create WebDav Media Error: ${redactSensitiveText(e.toString())}');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();

    // ✅ 初始化内部播放列表（可变）
    _sources = List<String>.from(widget.videoPaths);

    // ✅ 读取设置：字幕样式/交互（长按倍速、隐藏态细进度条等）。
    // 设计原因：这些值需要在视频页生命周期内稳定生效，避免用户操作时出现“忽快忽慢/忽大忽小”的体验。
    _loadSettings();

    // ✅ 按需求：进入视频页后默认不展示控制栏/图标。
    // 设计原因：避免“点开视频瞬间 UI 遮挡画面”，并减少误触。
    if (_isMobile) {
      _uiVisible = false;
    }

    if (_isMobile) {
      // ✅ 移动端：开启沉浸式，允许所有方向（随重力感应）
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // ✅ 启动传感器驱动自动旋转：不依赖系统自动旋转开关。
    }
    SystemChrome.setSystemUIOverlayStyle(_kLightStatusBarStyle);
    WebDavBackgroundGate.pauseHard();

    if (_sources.any((s) => _isWebDavSource(s))) {
      _webDavAccountCacheFuture = _loadWebDavAccountCache();
    }

    if (_sources.any((s) => _isEmbySource(s))) {
      _embyAccountMapFuture = _loadEmbyAccountMap();
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
      if (mounted) setState(() => _ready = false);
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
      final font = await AppSettings.getSubtitleFontSize();
      final bottom = await AppSettings.getSubtitleBottomOffset();
      final lpEnabled = await AppSettings.getLongPressSpeedEnabled();
      final lpMul = await AppSettings.getLongPressSpeedMultiplier();
      final miniProgress = await AppSettings.getVideoMiniProgressWhenHidden();
      final catalogEnabled = await AppSettings.getVideoCatalogEnabled();
      final autoNext = await AppSettings.getVideoAutoNextAfterEnd();
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
      // ✅ 标题统一走 _displayName：
      // 设计原因：
      // - Emby/WebDAV 这种“协议源”如果直接 basename，极容易出现 stream?...api_key=... 的乱码；
      // - _displayName 会优先使用我们传入的 name 参数，更符合用户认知。
      var title = _displayName(p0).trim().isEmpty ? '未知视频' : _displayName(p0);

      // ✅ 重点修复：有些入口会传入 emby://.../item:<id>（未携带 name 参数），
      // 这会导致标题退化为“Emby 媒体”。为了让中文标题稳定显示，这里做一次轻量补全。
      if (title == 'Emby 媒体' && _isEmbySource(p0)) {
        try {
          final m = RegExp(r'^emby://([^/]+)/item:([^/?#]+)').firstMatch(p0);
          final accId = (m?.group(1) ?? '').trim();
          final itemId = (m?.group(2) ?? '').trim();
          if (accId.isNotEmpty && itemId.isNotEmpty) {
            final accs = await EmbyStore.load();
            // 注意：如果未找到对应账号，则不强行请求，避免误用 token。
            final acc = accs.where((a) => a.id == accId).isEmpty
                ? null
                : accs.firstWhere((a) => a.id == accId);
            if (acc != null) {
              final client = EmbyClient(acc);
              final nm = await client.getItemName(itemId);
              if (nm != null && nm.trim().isNotEmpty) {
                title = nm.trim();
              }
            }
          }
        } catch (_) {
          // 获取失败不影响主流程，仍按默认标题写入。
        }
      }

      await AppHistory.upsert(path: p0, title: title);
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

    if (mounted) setState(() => _ready = true);
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

  Future<void> _autoLoadSrtIfAny() async {
    if (!_hasPlaylist) return;
    if (_isWebDavSource(_currentPath)) return;

    // ✅ Emby：刷新字幕轨道（不依赖本地同目录文件）。
    // 这里不强制自动启用，避免误切换；仅用于菜单选择。
    await _refreshEmbySubtitleCandidatesIfAny();

    await _refreshSrtCandidates();
    if (_srtCandidates.isEmpty) {
      // 没有外部字幕：恢复自动(内嵌)选择
      try {
        await _player.setSubtitleTrack(SubtitleTrack.auto());
      } catch (_) {}
      if (mounted)
        setState(() {
          _srtEnabled = false;
          _srtSelected = null;
          _embySubtitleSelected = null;
        });
      return;
    }
    final base = p.basenameWithoutExtension(_currentPath).toLowerCase();
    String pick = _srtCandidates.first;
    for (final s in _srtCandidates) {
      if (p.basenameWithoutExtension(s).toLowerCase() == base) {
        pick = s;
        break;
      }
    }
    await _applySrt(pick);
  }

  Future<void> _refreshSrtCandidates() async {
    // ✅ 仅对“本地文件路径”做同目录扫描；网络/Emby 播放地址无法可靠映射到本地目录。
    // 这样做是为了避免在 Emby 播放时误报“同目录未找到 .srt”，同时保持逻辑清晰。
    try {
      final p0 = _currentPath.trim();
      if (p0.isEmpty) return;

      // 通过协议判断：http/https/emby 等一律视为非本地文件
      final lower = p0.toLowerCase();
      if (lower.startsWith('http://') ||
          lower.startsWith('https://') ||
          lower.startsWith('emby://')) {
        if (mounted) setState(() => _srtCandidates = <String>[]);
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

      // ✅ 优先同名字幕（用户习惯：视频同名 .srt），其余按字母排序
      srts.sort((a, b) {
        final aa = p.basenameWithoutExtension(a).toLowerCase();
        final bb = p.basenameWithoutExtension(b).toLowerCase();
        final am = (aa == base);
        final bm = (bb == base);
        if (am != bm) return am ? -1 : 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

      if (mounted) setState(() => _srtCandidates = srts);
    } catch (_) {}

    // ✅ Emby：退出时上报 Stopped。
    // 设计原因：
    // - 让服务端及时结束会话（尤其是转码场景），避免后台转码进程长时间占用资源；
    // - 同时确保进度/观看状态能落盘。
    unawaited(_stopEmbyPlaybackCheckIns(reason: 'dispose'));
  }

  Future<void> _applySrt(String? path) async {
    try {
      if (path == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        if (mounted)
          setState(() {
            _srtEnabled = false;
            _srtSelected = null;
            _embySubtitleSelected = null;
          });
      } else {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            File(path).uri.toString(),
            title: p.basename(path),
          ),
        );
        if (mounted)
          setState(() {
            _srtEnabled = true;
            _srtSelected = path;
            _embySubtitleSelected = null;
          });
      }
    } catch (_) {}

    // ✅ Emby：字幕开关/切换属于交互事件，建议即时上报。
    // 说明：本地字幕对 Emby 服务端未必可识别，但上报可以让服务端 UI 与“是否开启字幕”更一致。
    unawaited(_reportEmbyProgress(
        eventName: 'SubtitleTrackChange', interactive: true));
    _pokeUI();
  }

  /// 应用 Emby 字幕轨道（通过 URL 直接交给 media_kit）。
  Future<void> _applyEmbySubtitle(EmbySubtitleTrack? track) async {
    try {
      if (track == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        if (mounted)
          setState(() {
            _srtEnabled = false;
            _srtSelected = null;
            _embySubtitleSelected = null;
          });

        // ✅ Emby：清空字幕选择
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
        if (mounted)
          setState(() {
            _srtEnabled = true;
            _srtSelected = null;
            _embySubtitleSelected = track;
          });

        // ✅ Emby：记录当前选择的字幕流 index，便于后续进度上报。
        if (_embyPlayback != null) {
          _embyPlayback!.subtitleStreamIndex = track.index;
        }
      }
    } catch (_) {}

    // ✅ Emby：字幕切换属于交互事件，按官方事件名上报。
    unawaited(_reportEmbyProgress(
        eventName: 'SubtitleTrackChange', interactive: true));
    _pokeUI();
  }

  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) {
    if (tracks.isEmpty) return null;

    // ✅ 优先规则：
    // 1) 优先 “默认” 字幕（isDefault=true）
    // 2) 其次优先 “外部字幕” 且语言偏中文（chi/zho/zh/中文/chinese）
    // 3) 再次优先 “外部字幕”
    // 4) 最后退回第一条
    final def = tracks.firstWhereOrNull((t) => t.isDefault);
    if (def != null) return def;

    bool _isZh(EmbySubtitleTrack t) {
      final s =
          ('${t.language ?? ''} ${t.title} ${t.codec ?? ''}').toLowerCase();
      return s.contains('chi') ||
          s.contains('zho') ||
          s.contains('zh') ||
          s.contains('中文') ||
          s.contains('chinese') ||
          s.contains('简体') ||
          s.contains('繁体');
    }

    final zhExternal = tracks.firstWhereOrNull((t) => t.isExternal && _isZh(t));
    if (zhExternal != null) return zhExternal;

    final anyExternal = tracks.firstWhereOrNull((t) => t.isExternal);
    if (anyExternal != null) return anyExternal;

    return tracks.first;
  }

  // ============================
  // Emby 字幕：解析/查询
  // ============================

  Future<EmbyAccount?> _getEmbyAccountById(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    try {
      final m = await (_embyAccountMapFuture ??= _loadEmbyAccountMap());
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
  Future<_EmbyNowPlaying?> _resolveEmbyNowPlaying(String source) async {
    // 1) 标准 emby:// 源
    final ref = _parseEmbySourceRef(source);
    if (ref != null) {
      final acc = await _getEmbyAccountById(ref.accountId);
      if (acc == null) return null;
      return _EmbyNowPlaying(account: acc, itemId: ref.itemId);
    }

    // 2) 兼容：历史/外部传入可能是 http(s) 直链
    final info = _parseEmbyStreamInfo(source);
    if (info != null) {
      final acc = await _resolveEmbyAccountForStream(source);
      if (acc == null) return null;
      return _EmbyNowPlaying(account: acc, itemId: info.itemId);
    }

    return null;
  }

  Future<void> _refreshEmbySubtitleCandidatesIfAny() async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) {
      if (mounted)
        setState(() => _embySubtitleCandidates = <EmbySubtitleTrack>[]);
      return;
    }

    try {
      final client = EmbyClient(np.account);
      final tracks = await client.listSubtitleTracks(np.itemId);
      if (mounted) setState(() => _embySubtitleCandidates = tracks);

      // ✅ Emby 外部字幕自动启用（你希望不点图标也能自动加载）
      // 触发条件：
      // - 当前是 Emby 播放源
      // - 当前没有启用任何字幕（本地 SRT/Emby 都没有选中）
      // - 同一个 itemId 只自动一次，避免用户手动切换后被覆盖
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
      if (mounted)
        setState(() => _embySubtitleCandidates = <EmbySubtitleTrack>[]);
    }
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

  _EmbyStreamInfo? _parseEmbyStreamInfo(String url) {
    try {
      final u = Uri.parse(url);
      final segs = u.pathSegments;
      final i = segs.indexWhere((s) => s.toLowerCase() == 'videos');
      if (i < 0 || i + 2 >= segs.length) return null;
      final itemId = segs[i + 1];
      final tail = segs[i + 2].toLowerCase();
      // 兼容：部分 Emby/反代可能返回 stream.mp4 / stream.mkv 等形式
      if (!tail.startsWith('stream')) return null;
      if (itemId.trim().isEmpty) return null;
      return _EmbyStreamInfo(itemId: itemId);
    } catch (_) {
      return null;
    }
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

  // ============================
  // Emby 播放上报：开始/进度/停止
  // ============================

  /// 将 Dart Duration 转为 Emby 需要的 ticks（1 tick = 100ns）。
  int _toEmbyTicks(Duration d) {
    // 1 微秒 = 10 * 100ns
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
      // ✅ 这里按“直连播放”上报；如果未来引入转码/HLS，可改为 Transcode/DirectPlay。
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
    // ✅ 串行化所有上报请求，避免并发导致服务端看到的状态乱序。
    _embyReportQueue = _embyReportQueue.then((_) => job()).catchError((e) {
      debugPrint('Emby 播放上报失败：${redactSensitiveText(e.toString())}');
    });
    return _embyReportQueue;
  }

  void _ensureEmbyProgressTimer() {
    if (_embyPlayback == null) return;
    _embyProgressTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      // ✅ Emby 官方建议：至少每 10 秒上报一次 TimeUpdate。
      // 这里用 best-effort，不影响播放主流程。
      unawaited(_reportEmbyProgress(eventName: 'TimeUpdate'));
    });
  }

  /// 尝试开启 Emby 播放上报（仅 Emby 源生效）。
  Future<void> _startEmbyPlaybackCheckInsIfNeeded({String reason = ''}) async {
    final np = await _resolveEmbyNowPlaying(_currentPath);
    if (np == null) {
      await _stopEmbyPlaybackCheckIns(reason: '非 Emby 源');
      return;
    }

    // 同一个 itemId 不重复创建会话
    final cur = _embyPlayback;
    if (cur != null &&
        cur.account.id == np.account.id &&
        cur.itemId == np.itemId) {
      _ensureEmbyProgressTimer();
      return;
    }

    // 切换条目：先停止旧会话，再建立新会话
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

      // ✅ 上报“开始播放”
      await _enqueueEmbyReport(() async {
        await client.reportPlaybackStarted(
            _buildEmbyCheckInBody(session, isPaused: !_player.state.playing));
      });

      _ensureEmbyProgressTimer();
    } catch (e) {
      debugPrint('Emby 会话创建失败：${redactSensitiveText(e.toString())}');
    }
  }

  Future<void> _reportEmbyProgress(
      {required String eventName, bool interactive = false}) async {
    final s = _embyPlayback;
    if (s == null) return;

    if (interactive) {
      final now = DateTime.now();
      if (now.difference(_embyLastInteractiveReportAt).inMilliseconds < 650) {
        // ✅ 降噪：短时间内连续手势/按钮操作只保留一次上报。
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
        await client
            .reportPlaybackStopped(_buildEmbyCheckInBody(s, isPaused: true));
      });
    } catch (e) {
      debugPrint('Emby 停止上报失败：${redactSensitiveText(e.toString())}');
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
            if (mounted)
              setState(() {
                _srtEnabled = false;
                _srtSelected = null;
                _embySubtitleSelected = null;
              });
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
          // ⚠️ 这里不能用 const：提示文案依赖运行时的当前播放地址
          final tip = _currentPath.toLowerCase().startsWith('http')
              ? '当前来源为网络播放，无法扫描同目录 .srt（请使用 Emby 字幕轨道）'
              : '当前目录未找到 .srt';
          items.add(Padding(
            padding: const EdgeInsets.all(12),
            child: Text(tip, style: const TextStyle(color: Colors.white70)),
          ));
        }

        // ✅ Emby 字幕轨道
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

  // ============================
  // 自动旋转：传感器驱动（画面旋转 + 原生强制旋转）
  // ============================
  void _startAutoRotateIfMobile() {
    if (!_isMobile) return;

    // ✅ 允许所有方向：这是“正常旋转”的基础；即便系统旋转锁开启，后面还会有原生兜底。
    try {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // ✅ 启动传感器驱动自动旋转：不依赖系统自动旋转开关。
    } catch (_) {}

    _nativeOriSub?.cancel();
    _nativeOriSub = NativeDeviceOrientationCommunicator()
        .onOrientationChanged(useSensor: true)
        .listen((ori) {
      if (!_autoRotateEnabled) return;

      // ✅ 当前版本枚举不包含 faceUp/faceDown，平放时通常会给 unknown；忽略 unknown 避免抖动。
      if (ori == NativeDeviceOrientation.unknown) return;

      // ✅ 稳定判定：同一方向连续出现 2 次才应用，避免传感器抖动频繁切换。
      if (_lastOriCandidate == ori) {
        _oriStableCount += 1;
      } else {
        _lastOriCandidate = ori;
        _oriStableCount = 1;
      }
      if (_oriStableCount < 2) return;

      // ✅ 降频：至少间隔 450ms 且方向真的变化才应用（避免连续 setOrientation 造成卡顿/闪屏）。
      final now = DateTime.now();
      if (now.difference(_lastOriApplyAt).inMilliseconds < 450) return;
      if (_appliedNativeOri == ori) return;

      _appliedNativeOri = ori;
      _lastOriApplyAt = now;

      // 1) 先旋转画面（必定生效：即便系统旋转锁开启，也能看到横竖变化）
      _applyVideoQuarterTurnsByNativeOri(ori);

      // 2) 再尝试原生强制旋转（尽量让屏幕也旋转）
      _applyNativeOrientationByChannel(ori);
    });
  }

  void _stopAutoRotateIfAny() {
    _nativeOriSub?.cancel();
    _nativeOriSub = null;
  }

  void _applyVideoQuarterTurnsByNativeOri(NativeDeviceOrientation ori) {
    // ✅ 说明：这里做的是“画面旋转”，不依赖系统是否真的旋转屏幕。
    // portraitUp -> 0
    // landscapeLeft -> 1 (90°)
    // portraitDown -> 2 (180°)
    // landscapeRight -> 3 (270°)
    int turns = 0;
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
      setState(() => _videoQuarterTurns = turns);
    }
  }

  Future<void> _applyNativeOrientationByChannel(
      NativeDeviceOrientation ori) async {
    // ✅ 说明：在系统旋转锁开启时，Flutter 侧 setPreferredOrientations 可能被降级为“建议旋转按钮”。
    // 通过原生 requestedOrientation 兜底，尽量直接切换屏幕方向。
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
      // ✅ 原生兜底失败也不影响播放：至少画面旋转已经生效。
      debugPrint('原生强制旋转失败：$e');
    }
  }

  Future<void> _unlockNativeOrientation() async {
    try {
      await _oriChannel.invokeMethod('unlock');
    } catch (_) {}
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
    _uiHideTimer?.cancel();
    _cursorHideTimer?.cancel();
    _catalogHotspotTimer?.cancel();

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

    _player.dispose();
    super.dispose();
  }

  void _pokeUI() {
    if (!_uiVisible) setState(() => _uiVisible = true);
    if (_isDesktop) {
      if (_cursorHidden) setState(() => _cursorHidden = false);
      _showTitleHint();
    }
    _uiHideTimer?.cancel();
    _uiHideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      setState(() => _uiVisible = false);
    });
    if (_isDesktop) {
      _cursorHideTimer?.cancel();
      _cursorHideTimer = Timer(_cursorDelay, () {
        if (!mounted) return;
        setState(() => _cursorHidden = true);
      });
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
        final items = const <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        final w = 160.0;
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
                                '${v} 倍',
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

  Future<void> _showHotkeysDialog() async {
    _pokeUI();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('快捷键'),
          content: const SingleChildScrollView(
            child: DefaultTextStyle(
              style: TextStyle(fontSize: 13, color: Colors.black),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Space / K：播放暂停'),
                  Text('← / →：后退/前进 5s'),
                  Text('↑ / ↓：音量 +/-5'),
                  Text('F：切换全屏'),
                  Text('L / Ctrl+L：打开目录'),
                  Text('Esc：退出全屏 / 关闭菜单'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))
          ],
        );
      },
    );
  }

  Future<void> _showCatalogPopup({bool fromHotspot = false}) async {
    if (!_hasPlaylist) return;
    if (_isScreenLocked) return;
    if (!_videoCatalogEnabled) return;
    if (_catalogOpen) return;
    _pokeUI();
    setState(() => _catalogOpen = true);

    // ✅ 目录增强：如果当前只有 1 条播放源（常见：从历史打开），尝试补全同目录/同季播放列表。
    // 仅在“第一次打开目录”时触发，避免反复网络请求。
    if (_sources.length <= 1 && !_sourcesExpandedOnce) {
      await _runWithBusyDialog(
        () => _ensureCatalogSourcesReady(),
        message: '正在加载同目录视频...',
      );
    }

    // ✅ 目录封面预热：优先预热“当前集 + 前后各 2 集”，让打开目录时就能看到封面。
    // 说明：移动端边播边拉封面可能抢带宽，因此仅做小范围预热，且并发=1。
    _prefetchCatalogThumbsAround(_index);

    int? picked;
    if (_isMobile) {
      picked = await _showCatalogBottomSheetMobile();
    } else {
      picked = await _showCatalogSidePanelDesktop();
    }

    if (!mounted) return;
    setState(() => _catalogOpen = false);
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
              final lower = q.trim().toLowerCase();
              final indices = <int>[];
              for (int i = 0; i < _sources.length; i++) {
                if (lower.isEmpty) {
                  indices.add(i);
                } else {
                  final nm = _displayName(_sources[i]).toLowerCase();
                  if (nm.contains(lower)) indices.add(i);
                }
              }

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
                                    message: '正在刷新目录...',
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
                              final name = _displayName(src);

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
                                  '${i + 1} / ${_sources.length}',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: Theme.of(ctx2)
                                        .colorScheme
                                        .onSurface
                                        .withOpacity(0.6),
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
            final lower = q.trim().toLowerCase();
            final indices = <int>[];
            for (int i = 0; i < _sources.length; i++) {
              if (lower.isEmpty) {
                indices.add(i);
              } else {
                final nm = _displayName(_sources[i]).toLowerCase();
                if (nm.contains(lower)) indices.add(i);
              }
            }

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
                                      message: '正在刷新目录...',
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
                                final name = _displayName(src);
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

  // ============================
  // 目录封面/缩略图（WebDAV/Emby/本地）
  // ============================

  static const Set<String> _imgExts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  bool _looksLikeImageFile(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) return false;
    return _imgExts.contains(ext);
  }

  /// 目录列表里的封面统一入口。
  ///
  /// ✅ 设计目标：
  /// - Emby：使用 Emby 的 Primary/Thumb 海报（最快、最稳定）
  /// - WebDAV：优先同目录“侧边海报图”（如同名 jpg / poster.jpg 等），否则走“前缀下载 + 抽帧缩略图”
  /// - 本地：复用 VideoThumbImage
  Widget _buildCatalogThumb(String source, {int cacheWidth = 320}) {
    // Emby
    if (_isEmbySource(source)) {
      final ref = _parseEmbySourceRef(source);
      if (ref == null) return _catalogThumbPlaceholder();
      _embyAccountMapFuture ??= _loadEmbyAccountMap();
      return FutureBuilder<Map<String, EmbyAccount>>(
        future: _embyAccountMapFuture,
        builder: (ctx, snap) {
          final m = snap.data;
          final acc = (m == null) ? null : m[ref.accountId];
          if (acc == null) return _catalogThumbPlaceholder();
          final client = EmbyClient(acc);
          final url = client.coverUrl(ref.itemId,
              type: 'Primary', maxWidth: cacheWidth, quality: 85);
          return Image.network(
            url,
            headers: client.imageHeaders(),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            errorBuilder: (_, __, ___) => _catalogThumbPlaceholder(),
          );
        },
      );
    }

    // WebDAV
    if (_isWebDavSource(source)) {
      // 1) 优先：同目录海报图（由 _expandPlaylistFromWebDavDir 构建映射）
      final cover = _webDavSidecarCoverByVideoSource[source];
      if (cover != null && cover.trim().isNotEmpty) {
        return _buildWebDavImageThumb(cover, cacheWidth: cacheWidth);
      }
      // 2) 否则：视频前缀抽帧（较慢，但对“纯视频目录”也能有封面）
      return _buildWebDavVideoThumb(source, cacheWidth: cacheWidth);
    }

    // Local
    return VideoThumbImage(videoPath: source, cacheOnly: false);
  }

  Widget _catalogThumbPlaceholder() {
    return Container(
      color: Colors.black12,
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 20, color: Colors.white54),
      ),
    );
  }

  Future<({String url, Map<String, String> headers})?> _resolveWebDavHttp(
      String source) {
    return _webDavResolveFutureCache.putIfAbsent(source, () async {
      final ref = _parseWebDavSourceForListing(source);
      if (ref == null) return null;
      final accountId = ref.accountId;
      final relDecoded = ref.relPath;
      if (accountId.isEmpty || relDecoded.isEmpty) return null;

      final accs =
          await (_webDavAccountCacheFuture ?? _loadWebDavAccountCache());
      final acc = accs[accountId];
      if (acc == null) return null;
      final baseUrl = (acc['baseUrl'] ?? '').trim();
      final username = (acc['username'] ?? '').toString();
      final password = (acc['password'] ?? '').toString();
      if (baseUrl.isEmpty) return null;

      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final relEncoded = _encodePathPreserveSlash(relDecoded);
      final url = Uri.parse(base).resolve(relEncoded).toString();
      final token = base64Encode(utf8.encode('$username:$password'));
      return (
        url: url,
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Basic $token'
        },
      );
    });
  }

  Widget _buildWebDavImageThumb(String source, {int cacheWidth = 320}) {
    return FutureBuilder<({String url, Map<String, String> headers})?>(
      future: _resolveWebDavHttp(source),
      builder: (ctx, snap) {
        final r = snap.data;
        if (r == null) return _catalogThumbPlaceholder();
        return Image.network(
          r.url,
          headers: r.headers,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          errorBuilder: (_, __, ___) => _catalogThumbPlaceholder(),
        );
      },
    );
  }

  Widget _buildWebDavVideoThumb(String source, {int cacheWidth = 320}) {
    final fut = _webDavVideoThumbFutureCache.putIfAbsent(
        source, () => _getOrCreateWebDavVideoThumb(source));
    return FutureBuilder<File?>(
      future: fut,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f != null && f.existsSync() && f.lengthSync() > 0) {
          return Image.file(
            f,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );
        }
        return _catalogThumbPlaceholder();
      },
    );
  }

  Future<File?> _getOrCreateWebDavVideoThumb(String source) async {
    // ✅ 目录缩略图：对 WebDAV 视频做“前缀下载 + 抽帧”。
    // - 并发限制为 1（见 _catalogThumbSemaphore），避免占用播放带宽
    // - 失败则返回 null（UI 降级占位）
    return _catalogThumbSemaphore.withPermit(() async {
      try {
        final ref = _parseWebDavSourceForListing(source);
        final relExt = ref == null ? '' : p.extension(ref.relPath);
        final resolved = await _resolveWebDavHttp(source);
        if (resolved == null) return null;

        // 生成稳定的前缀缓存文件路径
        final key = PersistentStore.instance
            .makeKey('webdav_prefix|${resolved.url}|6mb');
        final ext = relExt.isNotEmpty ? relExt : '.mp4';
        final part = await PersistentStore.instance.getFile(key, 'media', ext);

        // ✅ 先看“缩略图缓存”是否已存在：
        // 这样即使我们后面删掉前缀文件，也不影响后续直接展示封面。
        final cached = await ThumbCache.getCachedVideoThumb(part.path);
        if (cached != null) return cached;

        if (!await part.exists() || await part.length() <= 0) {
          await _downloadWebDavPrefixToFile(
            resolved.url,
            resolved.headers,
            part,
            maxBytes: 6 * 1024 * 1024,
          );
        }

        if (!await part.exists() || await part.length() <= 0) return null;
        // 抽帧 → 生成永久 thumb
        final thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
            part.path, Duration.zero);

        // ✅ 省空间：前缀文件只用于抽帧，成功后可删除。
        // 说明：缩略图已写入 PersistentStore/thumbnails，后续展示不再依赖前缀。
        if (thumb != null) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
        }
        return thumb;
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> _downloadWebDavPrefixToFile(
    String url,
    Map<String, String> headers,
    File out, {
    required int maxBytes,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Accept', '*/*');
      // Range 优先：尽量只拉前缀
      req.headers.set('Range', 'bytes=0-${maxBytes - 1}');
      final res = await req.close();

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('GET failed: ${res.statusCode}', uri: uri);
      }

      final tmp = File('${out.path}.download');
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      await tmp.create(recursive: true);
      final sink = tmp.openWrite();

      int received = 0;
      await for (final chunk in res) {
        if (received >= maxBytes) break;
        final remain = maxBytes - received;
        if (chunk.length <= remain) {
          sink.add(chunk);
          received += chunk.length;
        } else {
          sink.add(chunk.sublist(0, remain));
          received += remain;
          break;
        }
      }
      await sink.flush();
      await sink.close();

      if (await out.exists()) {
        try {
          await out.delete();
        } catch (_) {}
      }
      await tmp.rename(out.path);
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  void _prefetchCatalogThumbsAround(int index) {
    // 仅预热可见范围，避免移动端压力过大。
    if (!_hasPlaylist) return;
    final start = max(0, index - 2);
    final end = min(_sources.length - 1, index + 2);
    for (int i = start; i <= end; i++) {
      final src = _sources[i];
      // 触发 Future 缓存
      if (_isWebDavSource(src)) {
        // sidecar cover 不需要预热；视频抽帧可以预热
        if ((_webDavSidecarCoverByVideoSource[src] ?? '').trim().isEmpty) {
          _webDavVideoThumbFutureCache.putIfAbsent(
              src, () => _getOrCreateWebDavVideoThumb(src));
        }
      }
    }
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

  Future<void> _adjustVolume(double delta) async {
    _volume = (_volume + delta).clamp(0, 100);
    _player.setVolume(_volume);
    _pokeUI();
    setState(() {});
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
      if (!mounted) return;
      if (!popped && nav.canPop()) {
        popped = true;
        nav.pop();
      }
    }
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromLocalDir(
      String currentPath) async {
    try {
      final f = File(currentPath);
      if (!await f.exists()) return null;
      final dir = f.parent;
      final entries = await dir
          .list(followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();

      final vids = <File>[];
      for (final it in entries) {
        final name = p.basename(it.path);
        if (_looksLikeVideoFile(name)) vids.add(it);
      }
      if (vids.length <= 1) return null;

      vids.sort((a, b) => _naturalCompare(
          p.basename(a.path).toLowerCase(), p.basename(b.path).toLowerCase()));
      final srcs = vids.map((e) => e.path).toList();
      final idx = srcs.indexWhere((s) => p.equals(s, currentPath));
      return _ExpandedPlaylist(sources: srcs, index: idx >= 0 ? idx : 0);
    } catch (_) {
      return null;
    }
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromWebDavDir(
      String currentSource) async {
    // ✅ 目录补全（WebDAV）：通过 PROPFIND(Depth=1) 拉取同目录文件。
    // 注意：视频页会 pauseHard WebDavBackgroundGate，因此不能依赖 WebDavClient.list（会等待 gate），
    // 这里用独立 HTTP 请求绕过 gate，避免死等。

    final parsed = _parseWebDavSourceForListing(currentSource);
    if (parsed == null) return null;
    final accountId = parsed.accountId;
    final relPath = parsed.relPath;
    if (accountId.isEmpty || relPath.isEmpty) return null;

    final parentRel = _parentRelPath(relPath);
    final accountCache = await (_webDavAccountCacheFuture ??
        Future.value(<String, Map<String, String>>{}));
    final acc = accountCache[accountId];
    if (acc == null) return null;

    final baseUrl = acc['baseUrl'] ?? '';
    final username = acc['username'] ?? '';
    final password = acc['password'] ?? '';
    if (baseUrl.trim().isEmpty) return null;

    final list = await _webDavPropfindList(
      baseUrl: baseUrl,
      username: username,
      password: password,
      relFolder: parentRel,
    );
    if (list.isEmpty) return null;

    // ✅ 目录封面（WebDAV）：同目录“侧边海报图”探测
    // 设计：
    // - 优先同名图片：video.mp4 ↔ video.jpg
    // - 其次常见文件名：poster/cover/folder/thumb
    // - 若目录只有 1 张图，则作为兜底
    final imgItems =
        list.where((e) => !e.isDir && _looksLikeImageFile(e.name)).toList();
    final Map<String, _WebDavListItem> imgByBaseLower =
        <String, _WebDavListItem>{};
    for (final it in imgItems) {
      final base = p.basenameWithoutExtension(it.name).toLowerCase();
      // 保留第一个（按 PROPFIND 返回顺序即可），避免抖动
      imgByBaseLower.putIfAbsent(base, () => it);
    }

    _WebDavListItem? commonCover;
    if (imgItems.isNotEmpty) {
      const commonNames = <String>{
        'poster',
        'cover',
        'folder',
        'thumb',
        'fanart'
      };
      for (final it in imgItems) {
        final b = p.basenameWithoutExtension(it.name).toLowerCase();
        if (commonNames.contains(b)) {
          commonCover = it;
          break;
        }
      }
    }
    final singleCover = imgItems.length == 1 ? imgItems.first : null;

    // 过滤为视频文件
    final items =
        list.where((e) => !e.isDir && _looksLikeVideoFile(e.name)).toList();
    if (items.length <= 1) return null;

    items.sort(
        (a, b) => _naturalCompare(a.name.toLowerCase(), b.name.toLowerCase()));

    // 重新构建“视频->封面图”的映射（仅限当前目录），避免旧数据污染。
    final newCoverMap = <String, String>{};

    final srcs = <String>[];
    int idx = 0;
    for (int i = 0; i < items.length; i++) {
      final it = items[i];
      final src = (it.relPath == relPath)
          ? currentSource
          : _buildWebDavSource(accountId, it.relPath);
      srcs.add(src);
      if (it.relPath == relPath) idx = i;

      // ✅ 封面优先级：同名图片 > commonCover > 单图兜底
      final baseLower = p.basenameWithoutExtension(it.name).toLowerCase();
      final img = imgByBaseLower[baseLower] ?? commonCover ?? singleCover;
      if (img != null && img.relPath.trim().isNotEmpty) {
        final coverSrc = _buildWebDavSource(accountId, img.relPath);
        newCoverMap[src] = coverSrc;
      }
    }

    // 替换映射（仅当当前目录确实存在图片/映射时）；避免把空 map 覆盖掉其它播放列表的结果。
    if (newCoverMap.isNotEmpty) {
      _webDavSidecarCoverByVideoSource
        ..removeWhere((k, v) => srcs.contains(k))
        ..addAll(newCoverMap);
    }
    return _ExpandedPlaylist(sources: srcs, index: idx);
  }

  Future<_ExpandedPlaylist?> _expandPlaylistFromEmbyDir(
      String currentSource) async {
    final ref = _parseEmbySourceRef(currentSource);
    if (ref == null) return null;
    final accId = ref.accountId;
    final itemId = ref.itemId;
    if (accId.isEmpty || itemId.isEmpty) return null;

    final accs = await EmbyStore.load();
    EmbyAccount? acc;
    for (final a in accs) {
      if (a.id == accId) {
        acc = a;
        break;
      }
    }
    if (acc == null) return null;
    final client = EmbyClient(acc);

    final parentId = await client.getItemParentId(itemId).timeout(
          const Duration(seconds: 6),
          onTimeout: () => null,
        );
    if (parentId == null || parentId.trim().isEmpty) return null;

    final children = await client.listChildren(parentId: parentId).timeout(
          const Duration(seconds: 10),
          onTimeout: () => <EmbyItem>[],
        );
    if (children.isEmpty) return null;

    bool isPlayableVideo(EmbyItem it) {
      final mt = (it.mediaType ?? '').toLowerCase();
      if (mt == 'video') return true;
      final t = it.type.toLowerCase();
      return t == 'movie' || t == 'episode' || t == 'video';
    }

    final vids =
        children.where((e) => !e.isFolder && isPlayableVideo(e)).toList();
    if (vids.length <= 1) return null;

    vids.sort(
        (a, b) => _naturalCompare(a.name.toLowerCase(), b.name.toLowerCase()));

    final srcs = <String>[];
    int idx = 0;
    for (int i = 0; i < vids.length; i++) {
      final it = vids[i];
      final nm = it.name.trim();
      final src = (it.id == itemId)
          ? currentSource
          : (nm.isEmpty
              ? 'emby://$accId/item:${it.id}'
              : 'emby://$accId/item:${it.id}?name=${Uri.encodeComponent(nm)}');
      srcs.add(src);
      if (it.id == itemId) idx = i;
    }
    return _ExpandedPlaylist(sources: srcs, index: idx);
  }

  Future<void> _ensureCatalogSourcesReady({bool force = false}) async {
    if (!_hasPlaylist) return;
    if (_sourcesExpanding) return;
    if (!force && (_sources.length > 1 || _sourcesExpandedOnce)) return;

    _sourcesExpanding = true;
    try {
      final cur = _currentPath;

      _ExpandedPlaylist? expanded;
      if (_isWebDavSource(cur)) {
        expanded = await _expandPlaylistFromWebDavDir(cur);
      } else if (_isEmbySource(cur)) {
        expanded = await _expandPlaylistFromEmbyDir(cur);
      } else {
        expanded = await _expandPlaylistFromLocalDir(cur);
      }

      if (expanded == null || expanded.sources.length <= 1) {
        _sourcesExpandedOnce = true;
        return;
      }

      final oldPos = _player.state.position;
      final wasPlaying = _player.state.playing;

      setState(() {
        _sources = expanded!.sources;
        _index = expanded.index.clamp(0, _sources.length - 1);
      });

      // ✅ 关键：扩容后必须重建播放器 playlist，否则目录里点选会 jump 失败。
      final medias = await _buildMedias();
      await _player.open(Playlist(medias, index: _index), play: wasPlaying);
      _player.setRate(_rate);
      _player.setVolume(_volume);
      if (oldPos > Duration.zero) {
        await _player.seek(oldPos);
      }
      _autoLoadSrtIfAny();
      _armHistoryRecordForCurrent();
      _sourcesExpandedOnce = true;
    } catch (e) {
      _sourcesExpandedOnce = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录加载失败：${redactSensitiveText(e.toString())}')),
      );
    } finally {
      _sourcesExpanding = false;
    }
  }

  // -------- WebDAV listing helpers (minimal, bypass background gate) --------

  static const Set<String> _videoExts = <String>{
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    'vob',
    'ogv',
    'f4v',
    'ts',
    'm2ts',
    'mts',
    '3gp',
    'rm',
    'rmvb',
  };

  bool _looksLikeVideoFile(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) return false;
    return _videoExts.contains(ext);
  }

  int _naturalCompare(String a, String b) {
    // 与 Folder 页保持一致的“数字自然排序”逻辑（1,2,3,11,21）。
    int aIdx = 0, bIdx = 0;
    final aLen = a.length, bLen = b.length;
    bool isDigit(String c) =>
        c.length == 1 && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

    while (aIdx < aLen && bIdx < bLen) {
      final aChar = a[aIdx];
      final bChar = b[bIdx];

      if (isDigit(aChar) && isDigit(bChar)) {
        String aNum = '', bNum = '';
        while (aIdx < aLen && isDigit(a[aIdx])) aNum += a[aIdx++];
        while (bIdx < bLen && isDigit(b[bIdx])) bNum += b[bIdx++];
        final aVal = int.tryParse(aNum) ?? 0;
        final bVal = int.tryParse(bNum) ?? 0;
        if (aVal != bVal) return aVal.compareTo(bVal);
        final z = aNum.length.compareTo(bNum.length);
        if (z != 0) return z;
      } else {
        if (aChar != bChar) return aChar.compareTo(bChar);
        aIdx++;
        bIdx++;
      }
    }
    return (aLen - aIdx).compareTo(bLen - bIdx);
  }

  String _parentRelPath(String relPath) {
    final s = relPath.trim();
    final idx = s.lastIndexOf('/');
    if (idx <= 0) return '';
    return s.substring(0, idx + 1);
  }

  String _encodePathPreserveSlash(String relDecoded) {
    final segs = relDecoded
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .toList();
    final encoded = segs.join('/');
    return relDecoded.endsWith('/') ? '$encoded/' : encoded;
  }

  String _buildWebDavSource(String accountId, String relDecoded) {
    final encoded = _encodePathPreserveSlash(relDecoded);
    return 'webdav://$accountId/$encoded';
  }

  _WebDavRef? _parseWebDavSourceForListing(String source) {
    // 尝试用 Uri.parse；若存在裸 %，先修复。
    Uri? u;
    try {
      u = Uri.parse(source);
    } catch (_) {
      try {
        u = Uri.parse(source.replaceAll('%', '%25'));
      } catch (_) {
        return null;
      }
    }
    if (u.scheme != 'webdav') return null;
    final accountId = u.host;
    final segs = <String>[];
    for (final s in u.pathSegments.where((s) => s.isNotEmpty)) {
      // pathSegments 在多数情况下已 decode；这里再做一次安全 decode。
      var decoded = s;
      try {
        decoded = safeDecodeUriComponent(s);
      } catch (_) {
        try {
          decoded = safeDecodeUriComponent(s.replaceAll('%', '%25'));
        } catch (_) {
          decoded = s;
        }
      }
      segs.add(decoded);
    }
    final rel = segs.join('/');
    return _WebDavRef(accountId: accountId, relPath: rel);
  }

  Future<List<_WebDavListItem>> _webDavPropfindList({
    required String baseUrl,
    required String username,
    required String password,
    required String relFolder,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final folderEncoded = _encodePathPreserveSlash(relFolder);
      final url =
          Uri.parse(base).resolve(folderEncoded.isEmpty ? '' : folderEncoded);

      final token = base64Encode(utf8.encode('$username:$password'));
      final req = await client.openUrl('PROPFIND', url);
      req.followRedirects = true;
      req.headers.set('Depth', '1');
      req.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/xml; charset="utf-8"');

      const body = '''<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype />
    <D:displayname />
    <D:getcontentlength />
    <D:getlastmodified />
  </D:prop>
</D:propfind>
''';
      req.add(utf8.encode(body));
      final resp = await req.close();
      final text = await utf8.decodeStream(resp);
      if (resp.statusCode != 207 && resp.statusCode != 200) {
        throw Exception('WebDAV PROPFIND 失败：HTTP ${resp.statusCode}');
      }

      final basePath = () {
        final p0 = Uri.parse(base).path;
        if (p0.isEmpty) return '/';
        return p0.endsWith('/') ? p0 : '$p0/';
      }();

      return _parseWebDavPropfind(text, basePath: basePath);
    } finally {
      client.close(force: true);
    }
  }

  List<_WebDavListItem> _parseWebDavPropfind(String xmlText,
      {required String basePath}) {
    // 复用 webdav.dart 的解析思想（正则提取），但做最小实现。
    final items = <_WebDavListItem>[];
    final respRe = RegExp(r'<[^>]*:response\b[\s\S]*?<\/[^>]*:response>',
        caseSensitive: false);
    final hrefRe =
        RegExp(r'<[^>]*:href>([\s\S]*?)<\/[^>]*:href>', caseSensitive: false);
    final displayRe = RegExp(
        r'<[^>]*:displayname>([\s\S]*?)<\/[^>]*:displayname>',
        caseSensitive: false);
    final lenRe = RegExp(
        r'<[^>]*:getcontentlength>([0-9]+)<\/[^>]*:getcontentlength>',
        caseSensitive: false);
    final lmRe = RegExp(
        r'<[^>]*:getlastmodified>([\s\S]*?)<\/[^>]*:getlastmodified>',
        caseSensitive: false);
    final collRe = RegExp(r'<[^>]*:collection\s*\/?>', caseSensitive: false);

    for (final m in respRe.allMatches(xmlText)) {
      final block = m.group(0) ?? '';
      final href = hrefRe.firstMatch(block)?.group(1)?.trim();
      if (href == null || href.isEmpty) continue;

      // href 可能是绝对/相对，统一解析为 path。
      Uri hrefUri;
      try {
        hrefUri = Uri.parse(href);
      } catch (_) {
        continue;
      }
      final path = hrefUri.path;
      if (path.isEmpty) continue;
      if (!path.startsWith(basePath)) continue;
      var rel = path.substring(basePath.length);
      // 忽略当前目录自身那条 response（通常 rel 为空）。
      if (rel.isEmpty) continue;
      if (rel.startsWith('/')) rel = rel.substring(1);
      // href 中的 path 往往是 percent-encoded；这里把 rel 统一解码成“decoded 形式”。
      try {
        rel = Uri.decodeFull(rel);
      } catch (_) {
        // ignore
      }
      final isDir = path.endsWith('/') || collRe.hasMatch(block);

      final dispRaw = displayRe.firstMatch(block)?.group(1)?.trim() ?? '';
      var name = dispRaw;
      if (name.isEmpty) {
        final segs = path.split('/').where((s) => s.isNotEmpty).toList();
        name = segs.isEmpty ? rel : segs.last;
      }
      try {
        name = Uri.decodeFull(name);
      } catch (_) {}

      final sizeStr = lenRe.firstMatch(block)?.group(1);
      final sz = int.tryParse(sizeStr ?? '') ?? 0;
      DateTime? lm;
      final lmStr = lmRe.firstMatch(block)?.group(1)?.trim();
      if (lmStr != null && lmStr.isNotEmpty) {
        try {
          lm = HttpDate.parse(lmStr);
        } catch (_) {}
      }

      items.add(_WebDavListItem(
        name: name,
        relPath: rel,
        isDir: isDir,
        size: sz,
        modified: lm,
      ));
    }
    return items;
  }

  // -------- Emby source parsing helper --------

  _EmbyRef? _parseEmbySourceRef(String source) {
    try {
      final u = Uri.parse(source);
      if (u.scheme != 'emby') return null;
      final accId = u.host;
      final pth = u.path;
      final m = RegExp(r'item:([^/]+)').firstMatch(pth);
      final itemId = (m?.group(1) ?? '').trim();
      if (accId.isEmpty || itemId.isEmpty) return null;
      return _EmbyRef(accountId: accId, itemId: itemId);
    } catch (_) {
      return null;
    }
  }

  // Anime4K 方法
  bool get _canUseAnime4K =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  Future<void> _showAnime4KMenu(
      {required double parentLeft,
      required double parentTop,
      required double parentWidth}) async {/*...*/}
  Future<void> _showRateSubMenu(
      {required double parentLeft,
      required double parentTop,
      required double parentWidth}) async {/*...*/}
  Future<void> _showContextMenu(Offset globalPos) async {
    _pokeUI();
    // 上下文菜单逻辑...
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
      if (!_videoCatalogEnabled) return KeyEventResult.handled;
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

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_ready) return;
    _gestureActive = true;
    _gestureType = 'seek';
    _dragStartPos = _player.state.position;
    _dragTargetPos = _dragStartPos;
    _dragAccumulator = 0.0;
    setState(() {});
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isScreenLocked) return;
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
    setState(() {});
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_ready) return;
    _player.seek(_dragTargetPos);
    // ✅ Emby：手势拖动进度条属于交互行为，立即上报一次。
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
    Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _gestureActive = false);
    });
    _uiVisible ? _pokeUI() : null;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_isScreenLocked) return;
    if (!_ready) return;
    final width = MediaQuery.of(context).size.width;
    _gestureActive = true;

    if (details.globalPosition.dx > width / 2) {
      _gestureType = 'volume';
      _dragStartVal = _volume;
      _gestureIcon = Icons.volume_up;
    } else {
      _gestureType = 'brightness';
      _dragStartVal = _brightness;
      _gestureIcon = Icons.brightness_6;
    }
    setState(() {});
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
      if (_volume == 0)
        _gestureIcon = Icons.volume_mute;
      else if (_volume < 50)
        _gestureIcon = Icons.volume_down;
      else
        _gestureIcon = Icons.volume_up;
    } else {
      final step = delta / 200.0;
      _brightness = (_brightness + step).clamp(0.0, 1.0);
      _gestureText = '${(_brightness * 100).toInt()}%';
    }
    setState(() {});
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _gestureActive = false);
    });
    _uiVisible ? _pokeUI() : null;
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
            onHorizontalDragStart: _isMobile && !_isScreenLocked
                ? _onHorizontalDragStart
                : null, // 锁定状态下稍微限制手势防止误触(可选)
            onHorizontalDragUpdate:
                _isMobile && !_isScreenLocked ? _onHorizontalDragUpdate : null,
            onHorizontalDragEnd:
                _isMobile && !_isScreenLocked ? _onHorizontalDragEnd : null,
            onVerticalDragStart:
                _isMobile && !_isScreenLocked ? _onVerticalDragStart : null,
            onVerticalDragUpdate:
                _isMobile && !_isScreenLocked ? _onVerticalDragUpdate : null,
            onVerticalDragEnd:
                _isMobile && !_isScreenLocked ? _onVerticalDragEnd : null,

            // 若要锁定状态下依然允许手势，将上面的 && !_isScreenLocked 去掉即可。
            // 建议：保留手势，下面的 onHorizontalDragStart: _isMobile ? _onHorizontalDragStart : null, 即可

            onTap: () {
              if (!_isMobile) return;
              if (_isScreenLocked) return;
              setState(() => _uiVisible = !_uiVisible);
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
                    !_isScreenLocked &&
                    _longPressSpeedEnabled
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
            onLongPressEnd:
                _isMobile && !_isScreenLocked && _longPressSpeedEnabled
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
                            // ✅ 字幕设置：支持“字号 + 位置(距底部偏移)”调整。
                            // 设计原因：用户的关注点是“看得清 + 不挡画面关键区域”，用配置完成即可，避免重写字幕渲染。
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
                            controls: (state) => _MobileControlsOverlay(
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
                        color: Colors.black.withOpacity(
                            (1.0 - _brightness).clamp(0.0, 1.0) * 0.75),
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
                          color: Colors.black.withOpacity(0.5),
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

                  // 顶部 HUD：更贴近主流手机播放器（顶部渐变 + 返回 + 标题），并尽量不做动画。
                  if (_uiVisible || _isScreenLocked)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: SafeArea(
                        bottom: false,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.black54, Colors.transparent],
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                    color: Colors.black45,
                                    borderRadius: BorderRadius.circular(999)),
                                child: IconButton(
                                  tooltip: '返回',
                                  icon: const Icon(Icons.arrow_back,
                                      color: Colors.white),
                                  onPressed: () {
                                    Navigator.pop(context);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // ✅ 右侧“锁定横竖屏”按钮（不要做太大）：
                  // - 锁定后：不再跟随传感器自动旋转
                  // - 解锁后：恢复自动旋转
                  if (_isMobile && (_uiVisible || _isScreenLocked))
                    Positioned(
                      right: 10,
                      top: MediaQuery.of(context).size.height * 0.40,
                      child: SafeArea(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: IconButton(
                            tooltip: _isScreenLocked ? '已锁定方向' : '锁定方向',
                            iconSize: 18,
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(
                                minWidth: 34, minHeight: 34),
                            icon: Icon(
                              _isScreenLocked ? Icons.lock : Icons.lock_open,
                              color: Colors.white,
                            ),
                            onPressed: _toggleScreenLock,
                          ),
                        ),
                      ),
                    ),

                  // 右上热区 (仅桌面)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: SafeArea(
                      bottom: false,
                      child: MouseRegion(
                        opaque: false,
                        onEnter: (_) {
                          if (!_isDesktop ||
                              _catalogOpen ||
                              !_videoCatalogEnabled) {
                            return;
                          }
                          _catalogHotspotTimer?.cancel();
                          _catalogHotspotTimer =
                              Timer(const Duration(milliseconds: 300), () {
                            if (!mounted) return;
                            if (_catalogOpen) return;
                            _showCatalogPopup(fromHotspot: true);
                          });
                        },
                        onExit: (_) => _catalogHotspotTimer?.cancel(),
                        child: const SizedBox(width: 36, height: 90),
                      ),
                    ),
                  ),

                  // 手势操作反馈 UI
                  if (_gestureActive)
                    Center(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_gestureIcon, color: Colors.white, size: 32),
                            const SizedBox(height: 8),
                            Text(
                              _gestureText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),

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
/// Controls overlay（只负责“显示/隐藏”与 seekbar 预览）
/// ===============================

// ✅ 仅支持安卓手机：已移除桌面端控制层实现，避免无用代码引入编译问题。
class _MobileControlsOverlay extends StatefulWidget {
  final VideoState state;
  final Player player;
  final String currentVideoPath;

  final bool uiVisible;
  final VoidCallback onUserInteract;

  final double volume;
  final double rate;
  final bool isFullscreen;
  final bool isScreenLocked;

  /// 是否已启用字幕（用于按钮图标状态）
  final bool subtitlesEnabled;

  /// 播放结束行为：是否自动下一集。
  final bool autoNextAfterEnd;

  /// 控制栏隐藏时，是否显示底部细进度条。
  final bool showMiniProgressWhenHidden;

  /// 播放列表/目录
  final bool catalogEnabled;
  final int playlistCount;
  final int playlistIndex;
  final Future<void> Function() onShowCatalog;

  final Future<void> Function() onTogglePlayPause;
  final Future<void> Function() onToggleEndBehavior;
  final Future<void> Function() onShowSubtitles;
  final Future<void> Function(BuildContext buttonContext) onShowRate;

  const _MobileControlsOverlay({
    required this.state,
    required this.player,
    required this.currentVideoPath,
    required this.uiVisible,
    required this.onUserInteract,
    required this.volume,
    required this.rate,
    required this.isFullscreen,
    required this.isScreenLocked,
    required this.subtitlesEnabled,
    required this.autoNextAfterEnd,
    required this.showMiniProgressWhenHidden,
    required this.catalogEnabled,
    required this.playlistCount,
    required this.playlistIndex,
    required this.onShowCatalog,
    required this.onTogglePlayPause,
    required this.onToggleEndBehavior,
    required this.onShowSubtitles,
    required this.onShowRate,
  });

  @override
  State<_MobileControlsOverlay> createState() => _MobileControlsOverlayState();
}

class _MobileControlsOverlayState extends State<_MobileControlsOverlay> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _dragging = false; // 是否正在拖动进度条

  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    // 监听播放器状态流
    _subs.add(widget.player.stream.position.listen((v) {
      if (!_dragging) {
        if (mounted) setState(() => _position = v);
      }
    }));
    _subs.add(widget.player.stream.duration.listen((v) {
      if (mounted) setState(() => _duration = v);
    }));
    _subs.add(widget.player.stream.buffer.listen((v) {
      // ✅ 缓冲进度：用于显示“已加载长度”。
      if (mounted) setState(() => _buffer = v);
    }));
    _subs.add(widget.player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) s.cancel();
    super.dispose();
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
    // ✅ 锁定屏幕后：隐藏所有控制层，避免误触。
    // 解锁入口放在播放器外层（右侧锁按钮）。
    if (widget.isScreenLocked) return const SizedBox.shrink();

    final showControls = widget.uiVisible;

    // 进度：叠加“已缓冲长度”（底层）+ “已播放进度”（上层 Slider）
    final durationMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, max(0, durationMs));
    final bufMs = _buffer.inMilliseconds.clamp(0, max(0, durationMs));
    final bufferedValue = (durationMs > 0) ? (bufMs / durationMs) : 0.0;
    final playedValue = (durationMs > 0) ? (posMs / durationMs) : 0.0;

    final bottomBar = showControls
        ? Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 进度条与时间
                  Row(
                    children: [
                      Text(_fmt(_position),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                      Expanded(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 缓冲条（已加载长度）
                            SizedBox(
                              height: 2,
                              child: LinearProgressIndicator(
                                value: bufferedValue.clamp(0.0, 1.0),
                                backgroundColor: Colors.white12,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Colors.white24),
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: Colors.redAccent,
                                inactiveTrackColor: Colors.transparent,
                                thumbColor: Colors.redAccent,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                                trackShape: const _FullWidthSliderTrackShape(),
                                trackHeight: 2,
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14),
                              ),
                              child: Slider(
                                value: posMs
                                    .toDouble()
                                    .clamp(0, durationMs.toDouble()),
                                min: 0,
                                max: durationMs > 0
                                    ? durationMs.toDouble()
                                    : 1.0,
                                onChangeStart: (_) {
                                  widget.onUserInteract();
                                  setState(() => _dragging = true);
                                },
                                onChanged: (v) {
                                  widget.onUserInteract();
                                  setState(() => _position =
                                      Duration(milliseconds: v.toInt()));
                                },
                                onChangeEnd: (v) {
                                  widget.onUserInteract();
                                  setState(() => _dragging = false);
                                  widget.player
                                      .seek(Duration(milliseconds: v.toInt()));
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(_fmt(_duration),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                  ),

                  // 功能按钮行（尽量精简，贴近手机播放器习惯）
                  Row(
                    children: [
                      IconButton(
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          _playing ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onTogglePlayPause();
                        },
                      ),
                      const SizedBox(width: 6),
                      Builder(
                        builder: (ctx) {
                          return InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              widget.onUserInteract();
                              widget.onShowRate(ctx);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.speed,
                                      color: Colors.white70, size: 18),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${widget.rate}x',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
                      if (widget.catalogEnabled)
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            widget.onUserInteract();
                            widget.onShowCatalog();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.list_alt,
                                    color: Colors.white70, size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  '${(widget.playlistIndex + 1).clamp(1, widget.playlistCount)}/${widget.playlistCount}',
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const Spacer(),
                      IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          widget.autoNextAfterEnd
                              ? Icons.skip_next
                              : Icons.pause_circle_outline,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onToggleEndBehavior();
                        },
                      ),
                      IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          widget.subtitlesEnabled
                              ? Icons.subtitles
                              : Icons.subtitles_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onShowSubtitles();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        : const SizedBox.shrink();

    // 控制栏隐藏时仅保留细进度条，减少遮挡并保留“在播反馈”。
    final miniProgressBar =
        (!showControls && widget.showMiniProgressWhenHidden && durationMs > 0)
            ? Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 2,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(color: Colors.white10),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: bufferedValue.clamp(0.0, 1.0),
                            child: Container(color: Colors.white24),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: playedValue.clamp(0.0, 1.0),
                            child: Container(color: Colors.redAccent),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink();

    return Stack(
      children: [
        miniProgressBar,
        Positioned(left: 0, right: 0, bottom: 0, child: bottomBar),
      ],
    );
  }
}

class _StreamSource {
  final String id;
  final Uri remote;
  final Map<String, String> headers;
  final String? contentTypeHint;
  final int? sizeHint;

  _StreamMeta? meta;
  Future<_StreamCache>? _cacheFuture;
  bool _mp4ProbeStarted = false;
  bool _cancelProbe = false;

  _StreamSource({
    required this.id,
    required this.remote,
    required this.headers,
    required this.contentTypeHint,
    required this.sizeHint,
  });

  void cancelProbe() {
    _cancelProbe = true;
  }

  Future<_StreamCache> get cache async {
    // 1MB is verified to be the sweet spot.
    return _cacheFuture ??= _StreamCache.create(id, blockSize: 1024 * 1024);
  }

  Future<_StreamMeta> ensureMeta(
      HttpClient playbackClient, _FetchScheduler scheduler) async {
    if (meta != null) return meta!;
    try {
      final req = await playbackClient.headUrl(remote);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Accept', '*/*');
      final res = await req.close();
      final len = res.contentLength;
      final ct = res.headers.value(HttpHeaders.contentTypeHeader) ??
          contentTypeHint ??
          '';
      meta = _StreamMeta(
        size: (len > 0) ? len : (sizeHint ?? -1),
        contentType: ct,
      );
      if (!_cancelProbe) unawaited(_kickMp4Probe(playbackClient, scheduler));
      return meta!;
    } catch (_) {
      // fallback
    }

    final tmp = await scheduler.enqueue<_StreamMeta>(
      priority: 0,
      key: '${id}#meta',
      task: () async {
        final req = await playbackClient.getUrl(remote);
        headers.forEach((k, v) => req.headers.set(k, v));
        req.headers.set('Accept', '*/*');
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final res = await req.close();
        final ct = res.headers.value(HttpHeaders.contentTypeHeader) ??
            contentTypeHint ??
            '';
        int size = -1;
        final cr = res.headers.value('Content-Range');
        if (cr != null) {
          final slash = cr.lastIndexOf('/');
          if (slash != -1) {
            size = int.tryParse(cr.substring(slash + 1).trim()) ?? -1;
          }
        }
        await res.drain();
        return _StreamMeta(
            size: (size > 0) ? size : (sizeHint ?? -1), contentType: ct);
      },
    );
    meta = tmp;
    if (!_cancelProbe) unawaited(_kickMp4Probe(playbackClient, scheduler));
    return tmp;
  }

  bool get _looksLikeMp4 {
    final ct = (meta?.contentType ?? contentTypeHint ?? '').toLowerCase();
    if (ct.contains('video/mp4')) return true;
    if (ct.contains('application/mp4')) return true;
    return remote.path.toLowerCase().endsWith('.mp4');
  }

  Future<void> _kickMp4Probe(
      HttpClient playbackClient, _FetchScheduler scheduler) async {
    if (_mp4ProbeStarted || _cancelProbe) return;
    if (!_looksLikeMp4) return;
    final m = meta;
    if (m == null) return;
    final size = m.size;
    if (size <= 0) return;
    _mp4ProbeStarted = true;

    try {
      final head = await scheduler.enqueue<List<int>>(
        priority: 1,
        key: '$id#mp4_head',
        task: () async {
          if (_cancelProbe) return const <int>[];
          final req = await playbackClient.getUrl(remote);
          headers.forEach((k, v) => req.headers.set(k, v));
          req.headers.set('Accept', '*/*');
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
          final res = await req.close();
          if (res.statusCode != 206 && res.statusCode != 200) {
            await res.drain();
            return const <int>[];
          }
          final out = <int>[];
          await for (final chunk in res) {
            out.addAll(chunk);
            if (out.length >= 524288) break;
          }
          return out;
        },
      );
      if (head.isEmpty) return;
      if (_containsAscii(head, 'moov')) return;

      final cache = await this.cache;
      final blockSize = cache.blockSize;
      final lastBlock = (size - 1) ~/ blockSize;
      final startBlock = (lastBlock - 1).clamp(0, lastBlock);
      for (int bi = startBlock; bi <= lastBlock; bi++) {
        if (_cancelProbe) break;
        unawaited(cache.ensureBlock(
          bi,
          fetch: (int start, int end) {
            return scheduler.enqueue<File>(
              priority: 2,
              key: '$id#tail#$bi',
              task: () async {
                final f = cache.blockFile(bi);
                if (await f.exists() && await f.length() > 0) return f;
                return f;
              },
            );
          },
          allowPastEOF: true,
        ));
      }
    } catch (_) {}
  }

  bool _containsAscii(List<int> bytes, String needle) {
    if (needle.isEmpty || bytes.isEmpty) return false;
    final n = needle.codeUnits;
    outer:
    for (int i = 0; i <= bytes.length - n.length; i++) {
      for (int j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}

class _StreamMeta {
  final int size;
  final String contentType;
  _StreamMeta({required this.size, required this.contentType});
}

class _StreamCache {
  final String id;
  final Directory dir;
  final int blockSize;

  _StreamCache._(this.id, this.dir, this.blockSize);

  static Future<_StreamCache> create(String id,
      {required int blockSize}) async {
    final tmp = await getTemporaryDirectory();
    final root = Directory(p.join(tmp.path, 'stream_proxy_cache'));
    final sub = Directory(p.join(root.path, id.substring(0, 2), id));
    if (!await sub.exists()) await sub.create(recursive: true);
    return _StreamCache._(id, sub, blockSize);
  }

  File blockFile(int blockIndex) => File(p.join(dir.path, 'b_$blockIndex.bin'));

  Future<File> ensureBlock(
    int blockIndex, {
    required Future<File> Function(int start, int endInclusive) fetch,
    bool allowPastEOF = false,
  }) async {
    if (blockIndex < 0) throw RangeError('blockIndex < 0');
    final f = blockFile(blockIndex);
    if (await f.exists() && await f.length() > 0) return f;

    final start = blockIndex * blockSize;
    final end = start + blockSize - 1;

    try {
      final got = await fetch(start, end);
      return got;
    } catch (e) {
      if (allowPastEOF) rethrow;
      rethrow;
    }
  }
}

class _FetchScheduler {
  final HeapPriorityQueue<_FetchJob> _q = HeapPriorityQueue<_FetchJob>((a, b) {
    final p = a.priority.compareTo(b.priority);
    if (p != 0) return p;
    return a.seq.compareTo(b.seq);
  });

  int _seq = 0;
  int _activeCount = 0;
  final int maxConcurrency;

  final Map<String, Future<dynamic>> _inflight = <String, Future<dynamic>>{};

  _FetchScheduler({this.maxConcurrency = 3});

  /// NEW: Clears any pending tasks that are low priority (prefetch).
  /// Should be called on seek.
  void clearPendingLowPriority() {
    // We can't cancel running futures, but we can clear the queue so no NEW
    // tasks start.
    final keep = <_FetchJob>[];
    while (_q.isNotEmpty) {
      final job = _q.removeFirst();
      if (job.priority == 0) {
        keep.add(job); // Keep high priority (user waiting)
      } else {
        // Drop low priority
        _inflight.remove(job.key);
      }
    }
    for (final k in keep) _q.add(k);
  }

  Future<T> enqueue<T>({
    required int priority,
    required String key,
    required Future<T> Function() task,
  }) {
    final existing = _inflight[key];
    if (existing != null) return existing as Future<T>;

    final c = Completer<T>();
    _inflight[key] = c.future;
    _q.add(_FetchJob(
      priority: priority,
      seq: _seq++,
      key: key,
      run: () async {
        try {
          final r = await task();
          if (!c.isCompleted) c.complete(r);
        } catch (e, st) {
          if (!c.isCompleted) c.completeError(e, st);
        } finally {
          _inflight.remove(key);
        }
      },
    ));
    _pump();
    return c.future;
  }

  void _pump() {
    while (_activeCount < maxConcurrency && _q.isNotEmpty) {
      _activeCount++;
      final job = _q.removeFirst();
      job.run().whenComplete(() {
        _activeCount--;
        _pump();
      });
    }
  }
}

class _FetchJob {
  final int priority;
  final int seq;
  final String key;
  final Future<void> Function() run;
  _FetchJob(
      {required this.priority,
      required this.seq,
      required this.key,
      required this.run});
}

/// Emby streamUrl 解析结果（仅保留我们需要的字段）。
class _EmbyStreamInfo {
  final String itemId;
  const _EmbyStreamInfo({required this.itemId});
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
  int _index = 0;

  VideoPlayerController? _controller;
  int _openSeq = 0;
  bool _opening = false;
  String? _error;
  String _title = '视频播放';

  bool _controlsVisible = true;
  Timer? _hideTimer;
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
  bool _isScreenLocked = false;
  bool _lockButtonVisible = true;
  double _brightness = 1.0;
  bool _autoRotateEnabled = true;
  StreamSubscription<NativeDeviceOrientation>? _nativeOriSub;
  NativeDeviceOrientation _appliedNativeOri = NativeDeviceOrientation.unknown;
  NativeDeviceOrientation? _lastOriCandidate;
  int _oriStableCount = 0;
  DateTime _lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _gestureActive = false;
  String _gestureType = '';
  String _gestureText = '';
  IconData? _gestureIcon;
  Timer? _gestureHideTimer;
  Timer? _lockButtonHideTimer;
  Timer? _resumeHintForceHideTimer;
  int _resumeHintSerial = 0;
  ScaffoldMessengerState? _resumeHintMessenger;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
      _resumeHintSnackBarController;
  bool _exitCleanupDone = false;
  Offset? _lastDoubleTapPos;
  Duration _dragStartPos = Duration.zero;
  Duration _dragTargetPos = Duration.zero;
  double? _rateBeforeLongPress;

  static const int _historyMinPlayMs = 800;
  int _historyLastCommitAt = 0;
  String _historyLastCommitPath = '';
  String? _historyArmedPath;
  bool _historyArmed = false;

  Map<String, Map<String, String>>? _webDavAccounts;
  Map<String, EmbyAccount>? _embyAccounts;
  Future<Map<String, EmbyAccount>>? _embyAccountMapFuture;
  _EmbyPlaybackSession? _embyPlayback;
  Timer? _embyProgressTimer;
  Future<void> _embyReportQueue = Future.value();
  DateTime _embyLastInteractiveReportAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  List<EmbySubtitleTrack> _embySubtitleCandidates = <EmbySubtitleTrack>[];
  EmbySubtitleTrack? _embySubtitleSelected;
  List<String> _localSubtitleCandidates = <String>[];
  String? _localSubtitleSelected;
  String? _lastAutoSubtitleKey;

  bool get _hasPlaylist => _sources.isNotEmpty;
  String get _currentPath => _hasPlaylist ? _sources[_index] : '';
  bool get _canPrev => _index > 0;
  bool get _canNext => _index < _sources.length - 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sources = List<String>.from(widget.videoPaths);
    if (_sources.isNotEmpty) {
      _index = widget.initialIndex.clamp(0, _sources.length - 1);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(_kLightStatusBarStyle);
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
    }
  }

  @override
  void dispose() {
    unawaited(_stopEmbyPlaybackCheckIns(reason: 'mobile dispose'));
    unawaited(_flushHistoryProgress());
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _gestureHideTimer?.cancel();
    _lockButtonHideTimer?.cancel();
    _dismissResumeHint(clearBinding: true);
    _stopAutoRotateIfAny();
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerTick);
    unawaited(c?.pause());
    unawaited(c?.dispose());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_kDarkStatusBarStyle);
    super.dispose();
  }

  Future<void> _loadMobileSettings() async {
    try {
      final subtitleFont = await AppSettings.getSubtitleFontSize();
      final subtitleBottom = await AppSettings.getSubtitleBottomOffset();
      final lpEnabled = await AppSettings.getLongPressSpeedEnabled();
      final lpMul = await AppSettings.getLongPressSpeedMultiplier();
      final autoNext = await AppSettings.getVideoAutoNextAfterEnd();
      final resumeEnabled = await AppSettings.getVideoResumeEnabled();
      final miniProgress = await AppSettings.getVideoMiniProgressWhenHidden();
      final catalogEnabled = await AppSettings.getVideoCatalogEnabled();
      final episodeNavButtonsEnabled =
          await AppSettings.getVideoEpisodeNavButtonsEnabled();
      final dblTap = await AppSettings.getDoubleTapSeekSeconds();
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

      var title = _displayName(path);
      final ref = _parseEmbyRef(path);
      if (ref != null) {
        _embyAccounts ??= await _loadEmbyAccountMap();
        final acc = _embyAccounts![ref.accountId];
        if (acc != null) {
          final remote = await EmbyClient(acc).getItemName(ref.itemId);
          if (remote != null && remote.trim().isNotEmpty) {
            title = remote.trim();
          }
        }
      }

      await AppHistory.upsert(path: path, title: title, positionMs: positionMs);
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
      await AppHistory.updateProgress(
        path: path,
        positionMs: c.value.position.inMilliseconds.clamp(0, 0x7fffffff),
      );
    } catch (_) {}
  }

  Future<int?> _loadResumePositionMs(String path) async {
    try {
      final p0 = path.trim();
      if (p0.isEmpty) return null;
      if (!await AppSettings.getHistoryEnabled()) return null;
      final list = await AppHistory.load();
      final hit = list.firstWhereOrNull(
        (e) => (e['path'] ?? '').toString().trim() == p0,
      );
      if (hit == null) return null;
      final raw = hit['pos'];
      final ms = (raw is int) ? raw : int.tryParse('$raw');
      if (ms == null || ms <= 0) return null;
      return ms;
    } catch (_) {
      return null;
    }
  }

  void _startAutoRotateIfMobile() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _nativeOriSub?.cancel();
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
      if (_oriStableCount < 2) return;

      final now = DateTime.now();
      if (now.difference(_lastOriApplyAt).inMilliseconds < 450) return;
      if (_appliedNativeOri == ori) return;
      _appliedNativeOri = ori;
      _lastOriApplyAt = now;
      unawaited(_applyPreferredOrientationByOri(ori));
    });
  }

  void _stopAutoRotateIfAny() {
    _nativeOriSub?.cancel();
    _nativeOriSub = null;
  }

  Future<void> _beforeRouteExit({String reason = 'mobile pop'}) async {
    if (_exitCleanupDone) return;
    _exitCleanupDone = true;
    _dismissResumeHint(clearBinding: true);
    final c = _controller;
    if (c != null) {
      try {
        await c.pause();
      } catch (_) {}
    }
    await _flushHistoryProgress();
    unawaited(_stopEmbyPlaybackCheckIns(reason: reason));
  }

  Future<void> _applyPreferredOrientationByOri(
    NativeDeviceOrientation ori,
  ) async {
    try {
      switch (ori) {
        case NativeDeviceOrientation.landscapeLeft:
        case NativeDeviceOrientation.landscapeRight:
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          break;
        case NativeDeviceOrientation.portraitDown:
        case NativeDeviceOrientation.portraitUp:
        default:
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
          break;
      }
    } catch (_) {}
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
    final messenger = ScaffoldMessenger.of(context);
    _resumeHintMessenger = messenger;
    _resumeHintSnackBarController = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        content: Text(
          '从 ${_fmt(Duration(milliseconds: resumedMs))} 继续播放',
          style: const TextStyle(color: Colors.white),
        ),
        action: SnackBarAction(
          label: '从头播放',
          onPressed: () {
            final cur = _controller;
            if (cur == null || !cur.value.isInitialized) return;
            if (_currentPath.trim() != sourcePath.trim()) return;
            _dismissResumeHint();
            unawaited(cur.seekTo(Duration.zero));
            unawaited(
              _reportEmbyProgress(eventName: 'TimeUpdate', interactive: true),
            );
            unawaited(
                AppHistory.updateProgress(path: sourcePath, positionMs: 0));
            _showGestureOverlay('从头播放', Icons.replay);
          },
        ),
      ),
    );
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

    try {
      _resumeHintSnackBarController?.close();
    } catch (_) {}
    _resumeHintSnackBarController = null;

    try {
      _resumeHintMessenger?.hideCurrentSnackBar();
      _resumeHintMessenger?.removeCurrentSnackBar(
        reason: SnackBarClosedReason.remove,
      );
    } catch (_) {}

    if (mounted) {
      try {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.removeCurrentSnackBar(
          reason: SnackBarClosedReason.remove,
        );
      } catch (_) {}
    }

    if (clearBinding) {
      _resumeHintMessenger = null;
    }
  }

  bool _isWebDavSource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'webdav' && u.host.isNotEmpty;
    } catch (_) {}
    return false;
  }

  bool _isEmbySource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'emby' && u.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, Map<String, String>>> _loadWebDavAccountCache() async {
    final out = <String, Map<String, String>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('webdav_accounts_v1');
      if (raw == null || raw.trim().isEmpty) return out;
      final list = jsonDecode(raw);
      if (list is! List) return out;
      for (final e in list) {
        if (e is! Map) continue;
        final id = (e['id'] ?? '').toString().trim();
        final baseUrl = (e['baseUrl'] ?? '').toString().trim();
        final username = (e['username'] ?? '').toString();
        final password = (e['password'] ?? '').toString();
        if (id.isEmpty || baseUrl.isEmpty) continue;
        out[id] = <String, String>{
          'baseUrl': baseUrl,
          'username': username,
          'password': password,
        };
      }
    } catch (_) {}
    return out;
  }

  Future<Map<String, EmbyAccount>> _loadEmbyAccountMap() async {
    final out = <String, EmbyAccount>{};
    try {
      final list = await EmbyStore.load();
      for (final a in list) {
        final id = a.id.trim();
        if (id.isEmpty) continue;
        out[id] = a;
      }
    } catch (_) {}
    return out;
  }

  Future<Map<String, EmbyAccount>> _ensureEmbyAccounts() async {
    final cached = _embyAccounts;
    if (cached != null) return cached;
    final loaded = await (_embyAccountMapFuture ??= _loadEmbyAccountMap());
    _embyAccounts = loaded;
    return loaded;
  }

  String _displayName(String source) {
    if (_isEmbySource(source)) {
      try {
        final u = Uri.parse(source);
        final name = (u.queryParameters['name'] ?? '').trim();
        if (name.isNotEmpty) return safeDecodeUriComponent(name);
      } catch (_) {}
      return 'Emby 媒体';
    }
    if (_isWebDavSource(source)) {
      try {
        final u = Uri.parse(source);
        final rel = u.path.startsWith('/') ? u.path.substring(1) : u.path;
        final base = rel.split('/').isEmpty ? rel : rel.split('/').last;
        return safeDecodeUriComponent(base);
      } catch (_) {}
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      try {
        final u = Uri.parse(source);
        final qName = (u.queryParameters['name'] ?? '').trim();
        if (qName.isNotEmpty) return safeDecodeUriComponent(qName);
        if (u.pathSegments.isNotEmpty) {
          return safeDecodeUriComponent(u.pathSegments.last);
        }
      } catch (_) {}
    }
    return p.basename(source);
  }

  _EmbyRef? _parseEmbyRef(String source) {
    try {
      final u = Uri.parse(source);
      if (u.scheme.toLowerCase() != 'emby') return null;
      final accountId = u.host.trim();
      final raw = u.path.startsWith('/') ? u.path.substring(1) : u.path;
      final m = RegExp(r'^item:([^/?#]+)').firstMatch(raw);
      final itemId = (m?.group(1) ?? '').trim();
      if (accountId.isEmpty || itemId.isEmpty) return null;
      return _EmbyRef(accountId: accountId, itemId: itemId);
    } catch (_) {
      return null;
    }
  }

  Future<_MobileResolvedSource> _resolveEmbySource(String source) async {
    final ref = _parseEmbyRef(source);
    if (ref == null) {
      throw Exception('不支持的 Emby 源：$source');
    }

    _embyAccounts ??= await _loadEmbyAccountMap();
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
      title: _displayName(source),
    );
  }

  Future<_MobileResolvedSource> _resolveWebDavSource(String source) async {
    String accountId = '';
    String relEncoded = '';
    try {
      final u = Uri.parse(source);
      accountId = u.host.trim();
      final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
      relEncoded = segs.map(Uri.encodeComponent).join('/');
    } catch (_) {
      const prefix = 'webdav://';
      if (!source.startsWith(prefix)) {
        throw Exception('无效的 WebDAV 源：$source');
      }
      final raw = source.substring(prefix.length);
      final slash = raw.indexOf('/');
      if (slash == -1) throw Exception('无效的 WebDAV 源：$source');
      accountId = raw.substring(0, slash).trim();
      var relRaw = raw.substring(slash + 1);
      relRaw = relRaw.split('?').first.split('#').first;
      final segs = relRaw.split('/').where((s) => s.isNotEmpty).map((seg) {
        var decoded = seg;
        try {
          decoded = safeDecodeUriComponent(seg);
        } catch (_) {}
        return Uri.encodeComponent(decoded);
      }).toList();
      relEncoded = segs.join('/');
    }

    _webDavAccounts ??= await _loadWebDavAccountCache();
    final acc = _webDavAccounts![accountId];
    if (acc == null) {
      throw Exception('WebDAV 账号不存在：$accountId');
    }
    final baseUrl = (acc['baseUrl'] ?? '').trim();
    final username = (acc['username'] ?? '');
    final password = (acc['password'] ?? '');
    if (baseUrl.isEmpty) {
      throw Exception('WebDAV 账号缺少 baseUrl：$accountId');
    }
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final resolvedUrl = Uri.parse(base).resolve(relEncoded);
    final token = base64Encode(utf8.encode('$username:$password'));
    return _MobileResolvedSource.network(
      resolvedUrl,
      title: _displayName(source),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Basic $token',
      },
    );
  }

  Future<_MobileResolvedSource> _resolveSource(String source) async {
    if (_isEmbySource(source)) return _resolveEmbySource(source);
    if (_isWebDavSource(source)) return _resolveWebDavSource(source);
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return _MobileResolvedSource.network(
        Uri.parse(source),
        title: _displayName(source),
      );
    }
    return _MobileResolvedSource.local(source, title: _displayName(source));
  }

  _EmbyStreamInfo? _parseEmbyStreamInfo(String url) {
    try {
      final u = Uri.parse(url);
      final segs = u.pathSegments;
      final i = segs.indexWhere((s) => s.toLowerCase() == 'videos');
      if (i < 0 || i + 2 >= segs.length) return null;
      final itemId = segs[i + 1].trim();
      final tail = segs[i + 2].toLowerCase();
      if (!tail.startsWith('stream')) return null;
      if (itemId.isEmpty) return null;
      return _EmbyStreamInfo(itemId: itemId);
    } catch (_) {
      return null;
    }
  }

  Future<EmbyAccount?> _resolveEmbyAccountForStream(String url) async {
    try {
      final u = Uri.parse(url);
      final key = (u.queryParameters['api_key'] ??
              u.queryParameters['X-Emby-Token'] ??
              '')
          .trim();
      if (key.isEmpty) return null;
      _embyAccounts ??= await _loadEmbyAccountMap();
      for (final a in _embyAccounts!.values) {
        if (a.apiKey.trim() == key) return a;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<_EmbyNowPlaying?> _resolveEmbyNowPlaying(String source) async {
    final ref = _parseEmbyRef(source);
    if (ref != null) {
      _embyAccounts ??= await _loadEmbyAccountMap();
      final acc = _embyAccounts![ref.accountId];
      if (acc == null) return null;
      return _EmbyNowPlaying(account: acc, itemId: ref.itemId);
    }

    final info = _parseEmbyStreamInfo(source);
    if (info != null) {
      final acc = await _resolveEmbyAccountForStream(source);
      if (acc == null) return null;
      return _EmbyNowPlaying(account: acc, itemId: info.itemId);
    }
    return null;
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

  EmbySubtitleTrack? _pickBestEmbySubtitle(List<EmbySubtitleTrack> tracks) {
    if (tracks.isEmpty) return null;
    final def = tracks.firstWhereOrNull((t) => t.isDefault);
    if (def != null) return def;

    bool isZh(EmbySubtitleTrack t) {
      final s =
          ('${t.language ?? ''} ${t.title} ${t.codec ?? ''}').toLowerCase();
      return s.contains('chi') ||
          s.contains('zho') ||
          s.contains('zh') ||
          s.contains('中文') ||
          s.contains('chinese') ||
          s.contains('简体') ||
          s.contains('繁体');
    }

    final zhExternal = tracks.firstWhereOrNull((t) => t.isExternal && isZh(t));
    if (zhExternal != null) return zhExternal;

    final anyExternal = tracks.firstWhereOrNull((t) => t.isExternal);
    if (anyExternal != null) return anyExternal;

    return tracks.first;
  }

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

  bool _looksLikeLocalFilePath(String s) {
    if (s.startsWith('http://') || s.startsWith('https://')) return false;
    if (_isWebDavSource(s) || _isEmbySource(s)) return false;
    return true;
  }

  Future<void> _refreshLocalSubtitleCandidatesIfAny() async {
    if (!_looksLikeLocalFilePath(_currentPath)) {
      _localSubtitleCandidates = <String>[];
      _localSubtitleSelected = null;
      if (mounted) setState(() {});
      return;
    }
    try {
      final cur = File(_currentPath);
      if (!await cur.exists()) {
        _localSubtitleCandidates = <String>[];
        _localSubtitleSelected = null;
        if (mounted) setState(() {});
        return;
      }
      final dir = cur.parent;
      final entries = await dir
          .list(followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      final subs = <String>[];
      for (final f in entries) {
        final ext = p.extension(f.path).toLowerCase();
        if (ext == '.srt' || ext == '.vtt') {
          subs.add(f.path);
        }
      }
      subs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers.set('Accept', '*/*');
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('GET failed: ${res.statusCode}', uri: uri);
      }
      final bytes = await consolidateHttpClientResponseBytes(res);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
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
    if (mounted) setState(() {});
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
      if (mounted) setState(() {});
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
      if (mounted) setState(() {});
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
      return 'path:${_currentPath}';
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
      String pick = _localSubtitleCandidates.first;
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

  Future<void> _showCatalogMenu() async {
    if (!_hasPlaylist || !_videoCatalogEnabled) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: min(MediaQuery.of(ctx).size.height * 0.78, 540),
            child: ListView.builder(
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
                    _displayName(source),
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
            ),
          ),
        );
      },
    );
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

    final stream = _parseEmbyStreamInfo(source);
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

  void _showGestureOverlay(
    String text,
    IconData icon, {
    Duration ttl = const Duration(milliseconds: 650),
  }) {
    _gestureHideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _gestureActive = true;
      _gestureText = text;
      _gestureIcon = icon;
    });
    _gestureHideTimer = Timer(ttl, () {
      if (!mounted) return;
      setState(() => _gestureActive = false);
    });
  }

  void _beginGestureOverlay(String text, IconData icon) {
    _gestureHideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _gestureActive = true;
      _gestureText = text;
      _gestureIcon = icon;
    });
  }

  void _endGestureOverlay() {
    _gestureHideTimer?.cancel();
    _gestureHideTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _gestureActive = false);
    });
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _lastDoubleTapPos = details.localPosition;
  }

  Future<void> _onDoubleTap() async {
    if (_isScreenLocked) return;
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
    if (_isScreenLocked) return;
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
    const maxJumpMs = 180000.0; // one full-screen drag maps to 3 minutes
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
    if (_isScreenLocked) return;
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
    if (mounted) setState(() {});
    _endGestureOverlay();
    if (wasVolume) {
      unawaited(
        _reportEmbyProgress(eventName: 'TimeUpdate', interactive: true),
      );
    }
  }

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    if (_isScreenLocked || !_longPressSpeedEnabled) return;
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
      setState(() => _lockButtonVisible = false);
    });
  }

  void _toggleScreenLock() {
    if (!mounted) return;
    final nextLocked = !_isScreenLocked;
    setState(() {
      _isScreenLocked = nextLocked;
      _lockButtonVisible = true;
      if (nextLocked) {
        _controlsVisible = false;
      }
    });
    if (_isScreenLocked) {
      _hideTimer?.cancel();
      _autoRotateEnabled = false;
      _stopAutoRotateIfAny();
      final isLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;
      unawaited(
        SystemChrome.setPreferredOrientations(
          isLandscape
              ? const [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]
              : const [
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                ],
        ),
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
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    Future<void>.delayed(const Duration(milliseconds: 220), () async {
      if (!mounted || _isScreenLocked) return;
      _startAutoRotateIfMobile();
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
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_isScreenLocked) {
      setState(() => _lockButtonVisible = !_lockButtonVisible);
      _scheduleLockButtonAutoHide();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleAutoHide();
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
          setState(() => _controlsVisible = true);
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
      if (mounted) setState(() => _error = '没有可播放视频');
      return;
    }

    final seq = ++_openSeq;
    _dismissResumeHint();
    setState(() {
      _opening = true;
      _error = null;
      _title = _displayName(_currentPath);
      _draggingSeek = false;
      _dragSeekMs = 0;
    });

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
      if (mounted) setState(() {});

      if (autoPlay) {
        await _controller?.play();
      }
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
    }
  }

  Future<void> _togglePlayPause() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
      setState(() => _controlsVisible = true);
      _hideTimer?.cancel();
      unawaited(_reportEmbyProgress(eventName: 'Pause'));
    } else {
      await c.play();
      _scheduleAutoHide();
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
    setState(() => _index = newIndex);
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
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        unawaited(_beforeRouteExit(reason: 'mobile system back'));
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
          onHorizontalDragStart:
              initialized && !_isScreenLocked ? _onHorizontalDragStart : null,
          onHorizontalDragUpdate:
              initialized && !_isScreenLocked ? _onHorizontalDragUpdate : null,
          onHorizontalDragEnd:
              initialized && !_isScreenLocked ? _onHorizontalDragEnd : null,
          onVerticalDragStart:
              initialized && !_isScreenLocked ? _onVerticalDragStart : null,
          onVerticalDragUpdate:
              initialized && !_isScreenLocked ? _onVerticalDragUpdate : null,
          onVerticalDragEnd:
              initialized && !_isScreenLocked ? _onVerticalDragEnd : null,
          onLongPressStart:
              initialized && !_isScreenLocked ? _onLongPressStart : null,
          onLongPressEnd:
              initialized && !_isScreenLocked ? _onLongPressEnd : null,
          child: Stack(
            children: [
              Center(
                child: (initialized && c != null)
                    ? AspectRatio(
                        aspectRatio:
                            value!.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                        child: VideoPlayer(c),
                      )
                    : const CircularProgressIndicator(color: Colors.white),
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
                const Center(
                  child: CircularProgressIndicator(color: Colors.white70),
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
              if (_controlsVisible && !_isScreenLocked) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 4, 10, 6),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x88000000), Color(0x00000000)],
                        ),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () async {
                              final navigator = Navigator.of(context);
                              await _beforeRouteExit(
                                reason: 'mobile back button',
                              );
                              if (!mounted) return;
                              final popped = await navigator.maybePop();
                              if (!popped && mounted) {
                                _exitCleanupDone = false;
                              }
                            },
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white),
                          ),
                          Expanded(
                            child: Text(
                              _title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: initialized ? _showSubtitleMenu : null,
                            icon: const Icon(Icons.closed_caption,
                                color: Colors.white),
                          ),
                          IconButton(
                            onPressed: (_hasPlaylist && _videoCatalogEnabled)
                                ? _showCatalogMenu
                                : null,
                            icon: const Icon(Icons.playlist_play,
                                color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0x99000000), Color(0x00000000)],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                _fmt(Duration(milliseconds: currentMs.round())),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2.6,
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white24,
                                    secondaryActiveTrackColor: Colors.white38,
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.white24,
                                  ),
                                  child: Slider(
                                    value: currentMs,
                                    secondaryTrackValue:
                                        max(currentMs, bufferedMs)
                                            .clamp(0.0, maxMs.toDouble()),
                                    min: 0,
                                    max: maxMs.toDouble(),
                                    onChanged: initialized
                                        ? (v) {
                                            setState(() {
                                              _draggingSeek = true;
                                              _dragSeekMs = v;
                                            });
                                          }
                                        : null,
                                    onChangeEnd: initialized
                                        ? (v) async {
                                            _draggingSeek = false;
                                            await c?.seekTo(
                                              Duration(milliseconds: v.round()),
                                            );
                                            _scheduleAutoHide();
                                            unawaited(_reportEmbyProgress(
                                              eventName: 'TimeUpdate',
                                              interactive: true,
                                            ));
                                          }
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _fmt(duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const SizedBox(width: 42, height: 42),
                              Expanded(
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (showEpisodeNavButtons)
                                        SizedBox(
                                          width: 42,
                                          height: 42,
                                          child: IconButton(
                                            onPressed: _canPrev ? _prev : null,
                                            iconSize: 22,
                                            color: Colors.white,
                                            padding: EdgeInsets.zero,
                                            icon:
                                                const Icon(Icons.skip_previous),
                                          ),
                                        ),
                                      SizedBox(
                                        width: 42,
                                        height: 42,
                                        child: IconButton(
                                          onPressed: initialized
                                              ? _togglePlayPause
                                              : null,
                                          iconSize: 22,
                                          color: Colors.white,
                                          padding: EdgeInsets.zero,
                                          icon: Icon(
                                            playing
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                          ),
                                        ),
                                      ),
                                      if (showEpisodeNavButtons)
                                        SizedBox(
                                          width: 42,
                                          height: 42,
                                          child: IconButton(
                                            onPressed: _canNext ? _next : null,
                                            iconSize: 22,
                                            color: Colors.white,
                                            padding: EdgeInsets.zero,
                                            icon: const Icon(Icons.skip_next),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 42,
                                height: 42,
                                child: TextButton(
                                  onPressed:
                                      initialized ? _showSpeedMenu : null,
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    padding: EdgeInsets.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Text(
                                    '${_rate.toStringAsFixed((_rate % 1) == 0 ? 0 : 2)}x',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
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
              if (_gestureActive && (_gestureIcon != null))
                Center(
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
                            Icon(_gestureIcon, color: Colors.white, size: 30),
                            const SizedBox(height: 8),
                            Text(
                              _gestureText,
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
