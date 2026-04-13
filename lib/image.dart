import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'image/provider_helpers.dart';
import 'image/preload_windows.dart';
import 'image/overlay_layout_helpers.dart';
import 'image/source_resolver.dart';
import 'image/ratio_cache.dart';
import 'image/strip_sync_helpers.dart';
import 'image/strip_layout_helpers.dart';
import 'image/viewer_render_helpers.dart';
import 'video.dart';
import 'core/utils/app_shared.dart';
part 'image/tiles.dart';
part 'image/strip_item.dart';

// ===== media_image.dart =====

/// ===============================
/// Image Viewer
/// ===============================
class ImageViewerPage extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;
  // 用于退出时回传“稳定定位键”；为空时默认回传 imagePaths[index]。
  final List<String>? sourceKeys;
  final List<double?>? sourceAspectRatios;

  const ImageViewerPage({
    super.key,
    required this.imagePaths,
    required this.initialIndex,
    this.sourceKeys,
    this.sourceAspectRatios,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _controller;
  late int _index;

  // 是否显示角标
  bool _showIndexBadge = false;

  // 拼接模式
  bool _stripMode = false;
  double _stripScale = 1.0;
  final ScrollController _stripController = ScrollController();
  late final List<GlobalKey> _stripKeys;

  // 平台判定
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get _canRotate => _isMobile;
  bool _landscape = false;

  // 视图状态
  final Color _bg = Colors.black;
  bool _uiVisible = true;
  bool _topHover = false;
  bool _disposed = false;
  bool _viewerPrefsLoaded = false;

  // ✅ 图片查看器：是否启用“音量键翻页”。
  // 说明：这是用户可选功能，避免与系统音量调节冲突。
  bool _volumeKeyPagingEnabled = false;
  final FocusNode _keyFocusNode = FocusNode(debugLabel: 'ImageViewerKeyFocus');
  static const EventChannel _hardwareKeyEventChannel =
      EventChannel('glacier/hardware_keys');
  StreamSubscription<dynamic>? _hardwareKeySub;
  DateTime _lastVolumeHardwareKeyAt = DateTime.fromMillisecondsSinceEpoch(0);

  // 右键菜单
  OverlayEntry? _contextMenuEntry;
  OverlayEntry? _sizeMenuEntry;

  // 节流
  DateTime _lastWheelAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStripSyncAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Prefs Keys
  static const _kStripModeKey = 'img_view_strip_mode_v1';
  static const _kStripScaleKey = 'img_view_strip_scale_v1';
  static const _kIndexBadgeKey = 'img_view_index_badge_v1';
  static const _kRatioCacheKey = 'img_view_ratio_cache_v1';

  // WebDAV 解析缓存
  late final ImageSourceResolver _sourceResolver;
  static final AsyncLimiter _precacheLimiter = AsyncLimiter(maxConcurrent: 2);

  // 预加载控制
  final Set<int> _preloadedIndices = {};
  final Queue<int> _preloadedOrder = Queue<int>();
  int _preloadGeneration = 0;
  int _lastPreloadCenter = -1;
  static const int _kMaxPreloadedEntries = 240;
  int _stripActiveRadiusCurrent = ImagePreloadWindows.stripActiveRadius;
  late final ValueNotifier<int> _stripActiveRadiusVN;
  static const int _kStripDecodeWarmForward = 3;
  static const int _kStripDecodeWarmBackward = 1;

  late final ValueNotifier<int> _indexVN;

  String _sourceKeyAt(int index) {
    final i = index.clamp(0, widget.imagePaths.length - 1);
    final keys = widget.sourceKeys;
    if (keys != null && keys.length == widget.imagePaths.length) {
      final key = keys[i].trim();
      if (key.isNotEmpty) return key;
    }
    return widget.imagePaths[i].trim();
  }

  void _ensureKeyFocus() {
    if (!_isMobile || !mounted) return;
    if (_keyFocusNode.hasFocus) return;
    _keyFocusNode.requestFocus();
  }

  void _popWithCurrentSource() {
    if (!mounted) return;
    if (widget.imagePaths.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    final key = _sourceKeyAt(_index);
    Navigator.of(context).pop<String>(key);
  }

  bool _isWebDavSource(String s) => _sourceResolver.isWebDavSource(s);
  bool _isEmbySource(String s) => _sourceResolver.isEmbySource(s);

  Future<ResolvedImageSource?> _webdavFutureFor(String source) =>
      _sourceResolver.webdavFutureFor(source);

  Future<ResolvedEmbyImageSource?> _embyFutureFor(String source) =>
      _sourceResolver.embyFutureFor(source);

  int _targetCacheWidth() {
    if (!mounted) return 1920;
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio.clamp(1.0, 2.0);
    return max(512, (mq.size.width * dpr).round());
  }

  int _targetCacheHeight() {
    if (!mounted) return 1920;
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio.clamp(1.0, 2.0);
    return max(512, (mq.size.height * dpr).round());
  }

  void _markPreloaded(int index) {
    _preloadedIndices.remove(index);
    _preloadedIndices.add(index);
    _preloadedOrder.remove(index);
    _preloadedOrder.add(index);
    while (_preloadedOrder.length > _kMaxPreloadedEntries) {
      final oldest = _preloadedOrder.removeFirst();
      _preloadedIndices.remove(oldest);
    }
  }

  // ============================
  // 预加载
  // ============================
  Future<void> _precacheIndex(int i, {required int generation}) async {
    if (_disposed) return;
    if (generation != _preloadGeneration) return;
    if (i < 0 || i >= widget.imagePaths.length) return;
    if (_preloadedIndices.contains(i)) return;

    final src = widget.imagePaths[i];
    ImageProvider? provider;
    final cacheWidth = _targetCacheWidth();
    final cacheHeight = _targetCacheHeight();

    try {
      if (_isWebDavSource(src)) {
        final r = await _webdavFutureFor(src);
        if (generation != _preloadGeneration) return;
        if (r == null || _disposed) return;
        provider = SharedImageProviderCache.network(
          r.url,
          headers: r.headers,
          width: cacheWidth,
          height: cacheHeight,
        );
      } else if (_isEmbySource(src)) {
        final r = await _embyFutureFor(src);
        if (generation != _preloadGeneration) return;
        if (r == null || _disposed) return;
        provider = SharedImageProviderCache.network(
          r.url,
          headers: r.headers,
          width: cacheWidth,
          height: cacheHeight,
        );
      } else if (src.startsWith('http://') || src.startsWith('https://')) {
        provider = SharedImageProviderCache.network(
          src,
          width: cacheWidth,
          height: cacheHeight,
        );
      } else {
        final f = File(src);
        if (await f.exists()) {
          provider = SharedImageProviderCache.local(
            src,
            width: cacheWidth,
            height: cacheHeight,
          );
        }
      }

      if (provider != null && mounted) {
        await _precacheLimiter.run(() => precacheImage(provider!, context));
        if (generation != _preloadGeneration) return;
        _markPreloaded(i);
      }
    } catch (_) {}
  }

  void _updatePreloadWindow(int centerIndex) async {
    if (_disposed) return;
    _preloadGeneration++;
    final gen = _preloadGeneration;
    final deltaRaw =
        _lastPreloadCenter == -1 ? 0 : (centerIndex - _lastPreloadCenter).abs();
    final direction =
        _lastPreloadCenter == -1 ? 0 : (centerIndex - _lastPreloadCenter).sign;
    _lastPreloadCenter = centerIndex;
    final window = ImagePreloadWindows.pagedWindowForDelta(deltaRaw, direction);
    _warmPagedSourcesAround(centerIndex,
        deltaRaw: deltaRaw, direction: direction);
    final plan = <int>[centerIndex];
    if (direction >= 0) {
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex + i);
      }
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex - i);
      }
    } else {
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex - i);
      }
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex + i);
      }
    }
    for (final idx in plan) {
      unawaited(_precacheIndex(idx, generation: gen));
    }
  }

  void _warmPagedSourcesAround(int centerIndex,
      {required int deltaRaw, required int direction}) {
    final window = ImagePreloadWindows.pagedSourceWarmWindowForDelta(
      deltaRaw,
      direction,
    );
    final plan = <int>[centerIndex];
    if (direction >= 0) {
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex + i);
      }
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex - i);
      }
    } else {
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex - i);
      }
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex + i);
      }
    }
    for (final idx in plan) {
      if (idx < 0 || idx >= widget.imagePaths.length) continue;
      final src = widget.imagePaths[idx];
      if (_isWebDavSource(src)) {
        unawaited(_webdavFutureFor(src));
      } else if (_isEmbySource(src)) {
        unawaited(_embyFutureFor(src));
      }
    }
  }

  void _warmStripSourcesAround(int centerIndex) {
    final deltaRaw =
        _lastPreloadCenter == -1 ? 0 : (centerIndex - _lastPreloadCenter).abs();
    final direction =
        _lastPreloadCenter == -1 ? 0 : (centerIndex - _lastPreloadCenter).sign;
    final window = ImagePreloadWindows.warmWindowForDelta(deltaRaw);
    final nextRadius = ImagePreloadWindows.activeRadiusForDelta(deltaRaw);
    _stripActiveRadiusCurrent = nextRadius;
    if (_stripActiveRadiusVN.value != nextRadius) {
      _stripActiveRadiusVN.value = nextRadius;
    }
    final plan = <int>[centerIndex];
    if (direction >= 0) {
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex + i);
      }
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex - i);
      }
    } else {
      for (int i = 1; i <= window.forward; i++) {
        plan.add(centerIndex - i);
      }
      for (int i = 1; i <= window.backward; i++) {
        plan.add(centerIndex + i);
      }
    }
    for (final idx in plan) {
      if (idx < 0 || idx >= widget.imagePaths.length) continue;
      final src = widget.imagePaths[idx];
      if (_isWebDavSource(src)) {
        unawaited(_webdavFutureFor(src));
      } else if (_isEmbySource(src)) {
        unawaited(_embyFutureFor(src));
      }
    }
    _warmStripDecodeAround(centerIndex, direction: direction);
  }

  void _warmStripDecodeAround(int centerIndex, {required int direction}) {
    _preloadGeneration++;
    final gen = _preloadGeneration;
    final plan = <int>[centerIndex];
    if (direction >= 0) {
      for (int i = 1; i <= _kStripDecodeWarmForward; i++) {
        plan.add(centerIndex + i);
      }
      for (int i = 1; i <= _kStripDecodeWarmBackward; i++) {
        plan.add(centerIndex - i);
      }
    } else {
      for (int i = 1; i <= _kStripDecodeWarmForward; i++) {
        plan.add(centerIndex - i);
      }
      for (int i = 1; i <= _kStripDecodeWarmBackward; i++) {
        plan.add(centerIndex + i);
      }
    }
    for (final idx in plan) {
      unawaited(_precacheIndex(idx, generation: gen));
    }
  }

  // ============================
  // 单张模式：构建图片（带加载/进度/角标）
  // ============================
  Widget _wrapWithIndexBadge({required Widget child, required int index}) {
    if (!_showIndexBadge) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(left: 10, top: 10, child: _IndexBadge(text: '${index + 1}')),
      ],
    );
  }

  Widget _buildSingleImage(String source, {required int index}) {
    final isLightBg = _bg == Colors.white;
    final cacheWidth = _targetCacheWidth();
    final cacheHeight = _targetCacheHeight();

    Widget imageWidget;

    if (_isWebDavSource(source)) {
      imageWidget = ImageViewerRenderHelpers.buildWebDavImage(
        context: context,
        future: _webdavFutureFor(source),
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        lightText: !isLightBg,
        loadingBuilder: (progress, lightText) =>
            _LoadingThumb(progress: progress, lightText: lightText),
      );
    } else if (_isEmbySource(source)) {
      imageWidget = ImageViewerRenderHelpers.buildEmbyImage(
        context: context,
        future: _embyFutureFor(source),
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        lightText: !isLightBg,
        loadingBuilder: (progress, lightText) =>
            _LoadingThumb(progress: progress, lightText: lightText),
      );
    } else if (source.startsWith('http://') || source.startsWith('https://')) {
      imageWidget = ImageViewerRenderHelpers.buildNetworkImage(
        source: source,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        lightText: !isLightBg,
        loadingBuilder: (progress, lightText) =>
            _LoadingThumb(progress: progress, lightText: lightText),
      );
    } else {
      imageWidget = ImageViewerRenderHelpers.buildLocalImage(
        source: source,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        lightText: !isLightBg,
        loadingBuilder: (progress, lightText) =>
            _LoadingThumb(progress: progress, lightText: lightText),
      );
    }

    // ✅ 修复：偶发出现“图片叠在一起/需要点击一下才展开”的问题。
    // 主要原因是 PageView 在快速滑动/高并发解码时可能复用 Element，
    // 而 InteractiveViewer 内部又有变换状态，导致旧帧残留。
    // 这里用 ValueKey 强制每张图的 Viewer 组件独立，避免状态串页。
    final result = KeyedSubtree(
      key: ValueKey<String>('img_view_$source'),
      child: InteractiveViewer(
        transformationController: TransformationController(),
        minScale: 1.0,
        maxScale: 5.0,
        child: Center(child: imageWidget),
      ),
    );

    return _wrapWithIndexBadge(child: result, index: index);
  }

  // ============================
  // UI prefs / 旋转
  // ============================
  Future<void> _loadViewerPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      ImageRatioCache.restoreFromJson(
        prefs.getString(_kRatioCacheKey),
      );
      final sm = prefs.getBool(_kStripModeKey);
      final ss = prefs.getDouble(_kStripScaleKey);
      final ib = prefs.getBool(_kIndexBadgeKey); // ✅ 角标

      if (!mounted) return;
      setState(() {
        if (sm != null) _stripMode = sm;
        if (ss != null) _stripScale = ss;

        // ✅ 如果没存过，就保持默认 false（无角标）
        if (ib != null) _showIndexBadge = ib;
      });
      if (_stripMode) {
        // ✅ 修复：上下拼接模式打开后，初始定位经常失败（会停在顶部，看起来像“回到第一张”）。
        // 原因：ListView 只 build 可视区，目标 index 对应的 ctx 可能为空，ensureVisible 不生效。
        // 方案：先用“估算高度”把滚动条跳到大致位置，再在下一帧用 ensureVisible 精准定位。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _jumpStripNearIndex(_index);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _ensureStripVisible(_index));
        });
      }
    } catch (_) {}
    _viewerPrefsLoaded = true;
    if (!mounted) return;
    if (_stripMode) {
      _warmStripSourcesAround(_index);
    } else {
      _updatePreloadWindow(_index);
    }
  }

  /// 在上下拼接模式下，先用“默认占位高度”粗略跳转到目标索引附近。
  /// 这样可以确保目标项尽快进入 build 区间，随后 ensureVisible 才能生效。
  void _jumpStripNearIndex(int idx) {
    if (!_stripMode) return;
    if (!_stripController.hasClients) return;
    final total = widget.imagePaths.length;
    if (total == 0) return;
    final safeIdx = idx.clamp(0, total - 1);

    final est = ImageStripLayoutHelpers.estimateOffsetForIndex(safeIdx);

    try {
      final max = _stripController.position.maxScrollExtent;
      final target = est.clamp(0.0, max);
      // 使用 jumpTo 更稳（避免第一次进入时动画/回弹导致 offset 回到 0）。
      _stripController.jumpTo(target);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveViewerPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kStripModeKey, _stripMode);
      await prefs.setDouble(_kStripScaleKey, _stripScale);

      // ✅ 保存角标状态
      await prefs.setBool(_kIndexBadgeKey, _showIndexBadge);
    } catch (_) {}
  }

  Future<void> _persistRatioCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = ImageRatioCache.exportJson(maxEntries: 400);
      if (raw.isEmpty) {
        await prefs.remove(_kRatioCacheKey);
      } else {
        await prefs.setString(_kRatioCacheKey, raw);
      }
    } catch (_) {}
  }

  Future<void> _applyImmersiveAndOrientation({required bool landscape}) async {
    if (!_isMobile) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    } catch (_) {}
  }

  Future<void> _toggleLandscape() async {
    if (!_canRotate) return;
    _landscape = !_landscape;
    await _applyImmersiveAndOrientation(landscape: _landscape);
    if (mounted) setState(() {});
  }

  Future<void> _restoreSystemUI() async {
    if (!_isMobile) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    } catch (_) {}
  }

  // ============================
  // init / dispose
  // ============================
  @override
  void initState() {
    super.initState();
    _sourceResolver = ImageSourceResolver();

    // 进入看图模式时中断后台任务
    // WebDavBackgroundHttpPool.instance.abortAll();

    // 排序并修正 initialIndex
    String? currentPath;
    if (widget.initialIndex >= 0 &&
        widget.initialIndex < widget.imagePaths.length) {
      currentPath = widget.imagePaths[widget.initialIndex];
    }

    int newIndex = 0;
    if (currentPath != null) {
      newIndex = widget.imagePaths.indexOf(currentPath);
      if (newIndex == -1) newIndex = 0;
    } else {
      newIndex = widget.initialIndex.clamp(0, widget.imagePaths.length - 1);
    }

    _index = newIndex;
    _indexVN = ValueNotifier<int>(_index);
    _stripActiveRadiusVN = ValueNotifier<int>(_stripActiveRadiusCurrent);
    _controller = PageController(initialPage: _index);

    _stripKeys =
        List<GlobalKey>.generate(widget.imagePaths.length, (_) => GlobalKey());

    _loadViewerPrefs();
    _loadImageSettings();
    _stripController.addListener(_onStripScroll);
    _applyImmersiveAndOrientation(landscape: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureKeyFocus();
    });
  }

  Future<void> _loadImageSettings() async {
    try {
      final v = await AppSettings.getImageVolumeKeyPaging();
      if (!mounted) return;
      setState(() => _volumeKeyPagingEnabled = v);
      _syncHardwareVolumeKeyPagingListener();
    } catch (_) {
      // 设置读取失败不影响看图：保持默认关闭。
    }
  }

  void _syncHardwareVolumeKeyPagingListener() {
    if (!_isMobile || !Platform.isAndroid || !_volumeKeyPagingEnabled) {
      _hardwareKeySub?.cancel();
      _hardwareKeySub = null;
      return;
    }
    _hardwareKeySub ??= _hardwareKeyEventChannel
        .receiveBroadcastStream()
        .listen(_onHardwareKeyEvent, onError: (_) {});
  }

  void _onHardwareKeyEvent(dynamic event) {
    if (!mounted || !_volumeKeyPagingEnabled) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    final now = DateTime.now();
    if (now.difference(_lastVolumeHardwareKeyAt).inMilliseconds < 90) return;

    final type = (event ?? '').toString().trim().toLowerCase();
    if (type == 'volume_up') {
      _lastVolumeHardwareKeyAt = now;
      _jumpToIndex(_index - 1);
      _ensureKeyFocus();
      return;
    }
    if (type == 'volume_down') {
      _lastVolumeHardwareKeyAt = now;
      _jumpToIndex(_index + 1);
      _ensureKeyFocus();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_persistRatioCache());
    _removeContextMenu();
    _restoreSystemUI();
    _hardwareKeySub?.cancel();
    _hardwareKeySub = null;
    _controller.dispose();
    _stripController.dispose();
    _indexVN.dispose();
    _stripActiveRadiusVN.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  // ============================
  // 交互：滚轮/同步index
  // ============================
  void _jumpToIndex(int newIndex) {
    final total = widget.imagePaths.length;
    if (total == 0) return;
    final idx = newIndex.clamp(0, total - 1);
    if (idx == _index) return;

    final oldIndex = _index;
    setState(() => _index = idx);
    _indexVN.value = idx;
    if (_stripMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_stripMode) return;
        final ctx = _stripKeys[idx].currentContext;
        if (ctx != null) {
          _ensureStripVisible(idx);
          return;
        }
        if (!_stripController.hasClients) return;
        final direction = idx > oldIndex ? 1.0 : -1.0;
        final delta = ImageStripLayoutHelpers.pageJumpDelta(context);
        final min = _stripController.position.minScrollExtent;
        final max = _stripController.position.maxScrollExtent;
        final target =
            (_stripController.offset + direction * delta).clamp(min, max);
        if ((target - _stripController.offset).abs() < 1) return;
        _stripController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    } else if (_controller.hasClients) {
      _controller.jumpToPage(idx);
    }
    if (_viewerPrefsLoaded) {
      if (_stripMode) {
        _warmStripSourcesAround(idx);
      } else {
        _updatePreloadWindow(idx);
      }
    }
  }

  void _onMouseWheel(PointerScrollEvent e) {
    if (_stripMode) return;
    final now = DateTime.now();
    if (now.difference(_lastWheelAt).inMilliseconds < 120) return;
    _lastWheelAt = now;
    _removeContextMenu();
    final dy = e.scrollDelta.dy;
    if (dy > 0) {
      _jumpToIndex(_index + 1);
    } else if (dy < 0) {
      _jumpToIndex(_index - 1);
    }
  }

  void _onStripScroll() {
    if (!_stripMode) return;
    final now = DateTime.now();
    if (now.difference(_lastStripSyncAt).inMilliseconds < 90) return;
    _lastStripSyncAt = now;
    _syncIndexFromStripViewport();
  }

  void _syncIndexFromStripViewport() {
    final total = widget.imagePaths.length;
    if (total == 0 || !mounted) return;
    final safeTop = ImageStripLayoutHelpers.safeTopOffset(context);

    int bestIndex = _index;
    double bestScore = double.infinity;
    final window = ImageStripSyncHelpers.scanWindow(
      currentIndex: _index,
      total: total,
    );

    for (int i = window.start; i <= window.end; i++) {
      final ctx = _stripKeys[i].currentContext;
      if (ctx == null) continue;
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.hasSize) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      final score = ImageStripSyncHelpers.scoreForDy(dy: dy, safeTop: safeTop);
      if (score < bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }

    if (ImageStripSyncHelpers.shouldCommitBestIndex(
      currentIndex: _index,
      bestIndex: bestIndex,
    )) {
      _index = bestIndex;
      _indexVN.value = bestIndex;
      if (_viewerPrefsLoaded) {
        if (_stripMode) {
          _warmStripSourcesAround(bestIndex);
        } else {
          _updatePreloadWindow(bestIndex);
        }
      }
    }
  }

  void _ensureStripVisible(int idx) {
    if (!_stripMode) return;
    if (idx < 0 || idx >= _stripKeys.length) return;
    final ctx = _stripKeys[idx].currentContext;
    if (ctx == null) return;
    // 尽量把当前图片滚到视窗中间附近，解决“上下拼接模式无法定位到当前图片”
    Scrollable.ensureVisible(
      ctx,
      alignment: ImageStripLayoutHelpers.visibleAlignment,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  // ============================
  // 菜单（保留：模式、宽度、旋转、角标、背景）
  // ============================
  BoxDecoration _pillDecoration() {
    final isLight = _bg == Colors.white;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      color: (isLight ? Colors.white : Colors.black).withValues(alpha: 0.6),
      border: Border.all(color: Colors.white24, width: 0.5),
    );
  }

  BoxDecoration _pageIndicatorDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      color: Colors.black45,
    );
  }

  Future<void> _showSizeSubMenu({
    required Offset globalPos,
    required Size overlaySize,
    required double parentLeft,
    required double parentTop,
    required double parentWidth,
  }) async {
    _sizeMenuEntry?.remove();
    _sizeMenuEntry = null;

    const menuWidth = ImageOverlayLayoutHelpers.sizeMenuWidth;
    final isLight = _bg == Colors.white;
    final fg = isLight ? Colors.black : Colors.white;

    Widget item(
        {required String label, required double value, IconData? icon}) {
      final selected = (_stripScale - value).abs() < 0.0001;
      return InkWell(
        onTap: () {
          setState(() => _stripScale = value);
          _saveViewerPrefs();
          _removeContextMenu();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(selected ? Icons.check : (icon ?? Icons.tune),
                  size: 18, color: fg),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: TextStyle(color: fg))),
            ],
          ),
        ),
      );
    }

    final left = ImageOverlayLayoutHelpers.sizeMenuLeft(
      parentLeft: parentLeft,
      parentWidth: parentWidth,
      overlaySize: overlaySize,
    );
    final top = ImageOverlayLayoutHelpers.sizeMenuTop(
      parentTop: parentTop,
      overlaySize: overlaySize,
    );

    _sizeMenuEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        child: Material(
          type: MaterialType.card,
          color: isLight ? Colors.white : const Color(0xFF111111),
          elevation: 10,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: menuWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                item(
                    label: '拼接宽度：80%',
                    value: 0.80,
                    icon: Icons.photo_size_select_small),
                item(
                    label: '拼接宽度：90%',
                    value: 0.90,
                    icon: Icons.photo_size_select_small),
                item(label: '拼接宽度：100%', value: 1.00, icon: Icons.fullscreen),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(_sizeMenuEntry!);
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    _removeContextMenu();
    final overlayState = Overlay.of(context, rootOverlay: true);

    void insert(Size overlaySize) {
      if (!mounted) return;
      if (_contextMenuEntry != null) return;

      const menuWidth = ImageOverlayLayoutHelpers.contextMenuWidth;
      final dx =
          ImageOverlayLayoutHelpers.clampPointX(globalPos.dx, overlaySize);
      final dy =
          ImageOverlayLayoutHelpers.clampPointY(globalPos.dy, overlaySize);

      final isLight = _bg == Colors.white;
      final fg = isLight ? Colors.black : Colors.white;

      Widget item(
          {required String label,
          required VoidCallback onTap,
          IconData? icon}) {
        return InkWell(
          onTap: () {
            _removeContextMenu();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 10),
                ],
                Expanded(child: Text(label, style: TextStyle(color: fg))),
              ],
            ),
          ),
        );
      }

      final itemCount = 1 + (_stripMode ? 1 : 0) + (_canRotate ? 1 : 0) + 1 + 1;
      final left = ImageOverlayLayoutHelpers.contextMenuLeft(dx, overlaySize);
      final top = ImageOverlayLayoutHelpers.contextMenuTop(
        dy: dy,
        overlaySize: overlaySize,
        itemCount: itemCount,
      );

      _contextMenuEntry = OverlayEntry(
        builder: (_) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _removeContextMenu,
                child: const SizedBox(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                type: MaterialType.card,
                color: isLight ? Colors.white : const Color(0xFF111111),
                elevation: 10,
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: menuWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      item(
                        label: _stripMode ? '模式：连续浏览' : '模式：分页浏览',
                        icon: _stripMode
                            ? Icons.view_stream
                            : Icons.view_carousel,
                        onTap: () {
                          final wasStripMode = _stripMode;
                          setState(() => _stripMode = !_stripMode);
                          if (wasStripMode && _controller.hasClients) {
                            _controller.jumpToPage(_index);
                          }
                          _saveViewerPrefs();
                        },
                      ),
                      if (_stripMode)
                        item(
                          label: '图片宽度 ▶ (${(_stripScale * 100).round()}%)',
                          icon: Icons.tune,
                          onTap: () => _showSizeSubMenu(
                            globalPos: globalPos,
                            overlaySize: overlaySize,
                            parentLeft: left,
                            parentTop: top,
                            parentWidth: menuWidth,
                          ),
                        ),
                      if (_canRotate)
                        item(
                          label: _landscape ? '切换竖屏' : '切换横屏',
                          icon: Icons.screen_rotation,
                          onTap: _toggleLandscape,
                        ),
                      item(
                        label: _showIndexBadge ? '角标：开启' : '角标：关闭',
                        icon: _showIndexBadge
                            ? Icons.filter_1
                            : Icons.filter_1_outlined,
                        onTap: () {
                          setState(() => _showIndexBadge = !_showIndexBadge);
                          _saveViewerPrefs();
                        },
                      ),
                      item(
                        label:
                            _volumeKeyPagingEnabled ? '音量键翻页：开启' : '音量键翻页：关闭',
                        icon: _volumeKeyPagingEnabled
                            ? Icons.volume_up
                            : Icons.volume_off,
                        onTap: () async {
                          final next = !_volumeKeyPagingEnabled;
                          setState(() => _volumeKeyPagingEnabled = next);
                          _syncHardwareVolumeKeyPagingListener();
                          try {
                            await AppSettings.setImageVolumeKeyPaging(next);
                          } catch (_) {
                            // 持久化失败不应影响本次看图。
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      overlayState.insert(_contextMenuEntry!);
    }

    final box = overlayState.context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      insert(box.size);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final b = overlayState.context.findRenderObject() as RenderBox?;
        insert((b != null && b.hasSize) ? b.size : MediaQuery.of(context).size);
      });
    }
  }

  void _removeContextMenu() {
    _sizeMenuEntry?.remove();
    _sizeMenuEntry = null;
    _contextMenuEntry?.remove();
    _contextMenuEntry = null;
    _ensureKeyFocus();
  }

  void _showContextMenuFromToolbar() {
    final media = MediaQuery.of(context);
    final pos = Offset(media.size.width - 14, media.padding.top + 14);
    _showContextMenu(pos);
  }

  // ============================
  // build
  // ============================
  @override
  Widget build(BuildContext context) {
    final total = widget.imagePaths.length;
    const fg = Colors.white;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _popWithCurrentSource();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          color: _bg,
          child: total == 0
              ? const Center(
                  child: Text('没有图片', style: TextStyle(color: Colors.white)))
              : Focus(
                  autofocus: true,
                  focusNode: _keyFocusNode,
                  onKeyEvent: (node, event) {
                    // ✅ 音量键翻页：同时支持“单张模式”和“拼接模式”。
                    // 说明：部分设备上音量键事件可能仍会调节系统音量，这是系统层行为；
                    // 我们在 Flutter 侧尽量捕获并执行翻页。
                    if (!_isMobile) return KeyEventResult.ignored;
                    if (!_volumeKeyPagingEnabled) return KeyEventResult.ignored;
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;

                    final key = event.logicalKey;
                    final label = key.keyLabel.trim().toLowerCase();

                    if (key == LogicalKeyboardKey.audioVolumeUp ||
                        label == 'volume up' ||
                        label == 'audio volume up') {
                      _jumpToIndex(_index - 1);
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.audioVolumeDown ||
                        label == 'volume down' ||
                        label == 'audio volume down') {
                      _jumpToIndex(_index + 1);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Listener(
                    onPointerSignal: (ps) {
                      if (ps is PointerScrollEvent) _onMouseWheel(ps);
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _uiVisible = !_uiVisible);
                        _ensureKeyFocus();
                      },
                      onSecondaryTapDown: (d) =>
                          _showContextMenu(d.globalPosition),
                      onLongPressStart: (d) =>
                          _showContextMenu(d.globalPosition),
                      child: Stack(
                        children: [
                          // ===== 单张模式 =====
                          if (!_stripMode)
                            PageView.builder(
                              controller: _controller,
                              physics: const BouncingScrollPhysics(),
                              itemCount: total,
                              onPageChanged: (i) {
                                setState(() => _index = i);
                                _indexVN.value = i;
                                _updatePreloadWindow(i);
                              },
                              itemBuilder: (_, i) {
                                final path = widget.imagePaths[i];
                                return Center(
                                  child: RepaintBoundary(
                                    child: _buildSingleImage(path, index: i),
                                  ),
                                );
                              },
                            )
                          // ===== 拼接模式（关键实现：占位高度 -> 真实高度动画）=====
                          else
                            ListView.builder(
                              controller: _stripController,
                              padding: EdgeInsets.zero,
                              itemCount: total,
                              cacheExtent:
                                  MediaQuery.of(context).size.height * 2,
                              itemBuilder: (_, i) {
                                final path = widget.imagePaths[i];
                                final screenW =
                                    MediaQuery.of(context).size.width;
                                final targetW =
                                    (screenW * _stripScale).clamp(1.0, screenW);

                                return RepaintBoundary(
                                  child: KeyedSubtree(
                                    key: _stripKeys[i],
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if (_index != i) {
                                          _index = i;
                                          _indexVN.value = i;
                                        }
                                        // ✅ 点击条目时主动滚到当前项附近，避免“点击后跳回第一张/找不到当前位置”。
                                        _ensureStripVisible(i);
                                        setState(
                                            () => _uiVisible = !_uiVisible);
                                      },
                                      child: Center(
                                        child: StripImageItem(
                                          source: path,
                                          targetW: targetW,
                                          bg: _bg,
                                          showIndexBadge: _showIndexBadge,
                                          index: i,
                                          initialRatio: (widget
                                                          .sourceAspectRatios !=
                                                      null &&
                                                  i <
                                                      widget.sourceAspectRatios!
                                                          .length)
                                              ? widget.sourceAspectRatios![i]
                                              : null,
                                          isWebDavSource: _isWebDavSource,
                                          webdavFutureFor: _webdavFutureFor,
                                          isEmbySource: _isEmbySource,
                                          embyFutureFor: _embyFutureFor,
                                          centerListenable: _indexVN,
                                          activeRadiusListenable:
                                              _stripActiveRadiusVN,
                                          placeholderH: 220, // ✅ 你要的“默认高度”
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),

                          // 桌面端左右按钮
                          if (!_stripMode && !_isMobile)
                            Positioned.fill(
                              child: IgnorePointer(
                                ignoring: !_uiVisible,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 80,
                                      child: IconButton(
                                        icon: Icon(Icons.chevron_left,
                                            size: 48,
                                            color: fg.withValues(alpha: 0.5)),
                                        onPressed: _index <= 0
                                            ? null
                                            : () => _jumpToIndex(_index - 1),
                                      ),
                                    ),
                                    const Spacer(),
                                    SizedBox(
                                      width: 80,
                                      child: IconButton(
                                        icon: Icon(Icons.chevron_right,
                                            size: 48,
                                            color: fg.withValues(alpha: 0.5)),
                                        onPressed: _index >= total - 1
                                            ? null
                                            : () => _jumpToIndex(_index + 1),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          // 顶部工具栏
                          Positioned(
                            left: 0,
                            top: 0,
                            child: SafeArea(
                              child: MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _topHover = true),
                                onExit: (_) =>
                                    setState(() => _topHover = false),
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 200),
                                  opacity: _uiVisible || _topHover ? 1.0 : 0.0,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      children: [
                                        DecoratedBox(
                                          decoration: _pillDecoration(),
                                          child: IconButton(
                                            tooltip: '返回',
                                            icon: const Icon(Icons.arrow_back,
                                                color: Colors.white),
                                            onPressed: _popWithCurrentSource,
                                          ),
                                        ),
                                        if (_canRotate) ...[
                                          const SizedBox(width: 8),
                                          DecoratedBox(
                                            decoration: _pillDecoration(),
                                            child: IconButton(
                                              tooltip: '旋转屏幕',
                                              icon: const Icon(
                                                  Icons.screen_rotation,
                                                  color: Colors.white),
                                              onPressed: _toggleLandscape,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(width: 8),
                                        DecoratedBox(
                                          decoration: _pillDecoration(),
                                          child: IconButton(
                                            tooltip: '菜单',
                                            icon: const Icon(Icons.more_vert,
                                                color: Colors.white),
                                            onPressed:
                                                _showContextMenuFromToolbar,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // 底部页码
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 20,
                            child: SafeArea(
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                opacity: _uiVisible ? 1.0 : 0.0,
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: DecoratedBox(
                                    decoration: _pageIndicatorDecoration(),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_isMobile)
                                            IconButton(
                                              onPressed: _index <= 0
                                                  ? null
                                                  : () =>
                                                      _jumpToIndex(_index - 1),
                                              iconSize: 20,
                                              color: Colors.white,
                                              icon: const Icon(
                                                  Icons.chevron_left),
                                              tooltip: '上一张',
                                            ),
                                          ValueListenableBuilder<int>(
                                            valueListenable: _indexVN,
                                            builder: (_, idx, __) {
                                              return Text(
                                                '${idx + 1} / $total',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  shadows: [
                                                    Shadow(
                                                        blurRadius: 2,
                                                        color: Colors.black)
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                          if (_isMobile)
                                            IconButton(
                                              onPressed: _index >= total - 1
                                                  ? null
                                                  : () =>
                                                      _jumpToIndex(_index + 1),
                                              iconSize: 20,
                                              color: Colors.white,
                                              icon: const Icon(
                                                  Icons.chevron_right),
                                              tooltip: '下一张',
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
