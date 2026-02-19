import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'video.dart';
import 'utils.dart';

// ===== media_image.dart =====

/// ===============================
/// Media Tile (List Item)
/// ===============================
/// ===============================
/// 视频缩略图（列表/封面通用）
/// ===============================
///
/// 设计目标：
/// - “最小改动”下补回缺失的 VideoThumbImage，避免全项目编译失败。
/// - 仅在需要时生成缩略图，避免滚动列表频繁抽帧造成卡顿。
/// - 生成/读取失败时给出稳定占位图（不影响主功能）。
class VideoThumbImage extends StatelessWidget {
  final String videoPath;
  final BoxFit fit;
  final bool cacheOnly;

  const VideoThumbImage({
    super.key,
    required this.videoPath,
    this.fit = BoxFit.cover,
    this.cacheOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = videoPath.trim();
    if (p.isEmpty) return const _ThumbPlaceholder();

    // ✅ 这里用永久缩略图缓存（utils.dart: ThumbCache），避免每次滚动都重新抽帧。

    // ✅ cacheOnly=true：只读缓存，不触发抽帧生成，避免在列表快速滚动时造成卡顿。
    // 说明：某些页面（例如 WebDAV/标签列表）只想“有就显示，没有就占位”，因此提供此开关兼容旧调用。
    if (cacheOnly) {
      return FutureBuilder<File?>(
        future: ThumbCache.getCachedVideoThumb(p),
        builder: (context, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.file(f,
                    fit: fit,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true),
                const Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.play_circle_fill,
                        size: 18, color: Colors.white70),
                  ),
                ),
              ],
            );
          }
          return const _ThumbPlaceholder();
        },
      );
    }

    // ✅ 这里用永久缩略图缓存（utils.dart: ThumbCache），避免每次滚动都重新抽帧。
    return FutureBuilder<File?>(
      future: ThumbCache.getOrCreateVideoThumb(p),
      builder: (context, snap) {
        final f = snap.data;
        if (f != null && f.existsSync() && f.lengthSync() > 0) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                f,
                fit: fit,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
              ),
              // ✅ 叠加一个轻量的“播放”角标，便于区分图片/视频
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.play_circle_fill,
                      size: 18, color: Colors.white70),
                ),
              ),
            ],
          );
        }

        // 生成中/失败：显示占位，保证列表稳定渲染
        return const _ThumbPlaceholder();
      },
    );
  }
}

class MediaTile extends StatelessWidget {
  final String filePath;
  final String? subtitleText;
  final List<String> imagePaths;
  final List<String> videoPaths;
  final int initialImageIndex;
  final int initialVideoIndex;
  final Future<void> Function()? onBeforeOpenImage;

  const MediaTile({
    super.key,
    required this.filePath,
    this.subtitleText,
    required this.imagePaths,
    required this.videoPaths,
    required this.initialImageIndex,
    required this.initialVideoIndex,
    this.onBeforeOpenImage,
  });

  bool get _isImage => ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp']
      .contains(p.extension(filePath).toLowerCase());

  bool get _isVideo => [
        '.mp4',
        '.mkv',
        '.mov',
        '.avi',
        '.wmv',
        '.flv',
        '.webm',
        '.m4v'
      ].contains(p.extension(filePath).toLowerCase());

  @override
  Widget build(BuildContext context) {
    final name = p.basename(filePath);

    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 110,
          height: 90,
          child: _isImage
              ? Image.file(
                  File(filePath),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
                )
              : _isVideo
                  ? VideoThumbImage(videoPath: filePath)
                  : const _ThumbPlaceholder(),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitleText ?? filePath,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing:
            Icon(_isImage ? Icons.image_outlined : Icons.play_circle_outline),
        onTap: () async {
          if (_isImage && imagePaths.isNotEmpty && initialImageIndex >= 0) {
            // ✅ 允许外部在“打开图片前”做一些附加逻辑（例如：记录所在目录到历史）。
            // 设计原因：MediaTile 组件本身不应该关心“收藏夹/目录”概念，因此通过回调注入。
            try {
              await onBeforeOpenImage?.call();
            } catch (_) {}
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageViewerPage(
                  imagePaths: imagePaths,
                  initialIndex: initialImageIndex,
                ),
              ),
            );
          } else if (_isVideo &&
              videoPaths.isNotEmpty &&
              initialVideoIndex >= 0) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VideoPlayerPage(
                  videoPaths: videoPaths,
                  initialIndex: initialVideoIndex,
                ),
              ),
            );
          }
        },
      ),
    );
  }
}

/// ===============================
/// Image Viewer
/// ===============================
class ImageViewerPage extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;
  // 用于退出时回传“稳定定位键”；为空时默认回传 imagePaths[index]。
  final List<String>? sourceKeys;

  const ImageViewerPage({
    super.key,
    required this.imagePaths,
    required this.initialIndex,
    this.sourceKeys,
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
  Color _bg = Colors.black;
  bool _uiVisible = true;
  bool _topHover = false;
  bool _disposed = false;

  // ✅ 图片查看器：是否启用“音量键翻页”。
  // 说明：这是用户可选功能，避免与系统音量调节冲突。
  bool _volumeKeyPagingEnabled = false;
  final FocusNode _keyFocusNode = FocusNode(debugLabel: 'ImageViewerKeyFocus');

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

  // WebDAV 解析缓存
  final Map<String, Future<({String url, Map<String, String> headers})?>>
      _webdavResolveFutureCache = {};

  // 预加载控制
  final Set<int> _preloadedIndices = {};
  int _preloadGeneration = 0;

  // ============================
  // 自然排序
  // ============================
  static int _naturalCompare(String a, String b) {
    final reg = RegExp(r'(\d+)|(\D+)');
    final ma = reg.allMatches(a).iterator;
    final mb = reg.allMatches(b).iterator;

    while (ma.moveNext() && mb.moveNext()) {
      final partA = ma.current.group(0)!;
      final partB = mb.current.group(0)!;

      final isNumA = int.tryParse(partA);
      final isNumB = int.tryParse(partB);

      if (isNumA != null && isNumB != null) {
        final cmp = isNumA.compareTo(isNumB);
        if (cmp != 0) return cmp;
      } else {
        final cmp = partA.compareTo(partB);
        if (cmp != 0) return cmp;
      }
    }
    return a.length.compareTo(b.length);
  }

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

  bool _isWebDavSource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'webdav' && u.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _loadWebDavAccountJson(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('webdav_accounts_v1');
      if (raw == null || raw.trim().isEmpty) return null;
      final List list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is Map && (e['id'] ?? '').toString() == accountId) {
          return Map<String, dynamic>.from(e as Map);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<({String url, Map<String, String> headers})?> _resolveWebDav(
      String source) async {
    try {
      final u = Uri.parse(source);
      final accountId = u.host;
      final rel =
          Uri.decodeFull(u.path.startsWith('/') ? u.path.substring(1) : u.path);
      final j = await _loadWebDavAccountJson(accountId);
      if (j == null) return null;

      final baseUrl = (j['baseUrl'] ?? '').toString();
      final username = (j['username'] ?? '').toString();
      final password = (j['password'] ?? '').toString();
      if (baseUrl.isEmpty) return null;

      final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final url = Uri.parse(base).resolve(rel).toString();
      final token = base64Encode(utf8.encode('$username:$password'));
      final headers = <String, String>{
        HttpHeaders.authorizationHeader: 'Basic $token'
      };
      return (url: url, headers: headers);
    } catch (_) {
      return null;
    }
  }

  Future<({String url, Map<String, String> headers})?> _webdavFutureFor(
      String source) {
    return _webdavResolveFutureCache.putIfAbsent(
        source, () => _resolveWebDav(source));
  }

  // ============================
  // 预加载
  // ============================
  Future<void> _precacheIndex(int i) async {
    if (_disposed) return;
    if (i < 0 || i >= widget.imagePaths.length) return;
    if (_preloadedIndices.contains(i)) return;

    final src = widget.imagePaths[i];
    ImageProvider? provider;

    try {
      if (_isWebDavSource(src)) {
        final r = await _webdavFutureFor(src);
        if (r == null || _disposed) return;
        provider = NetworkImage(r.url, headers: r.headers);
      } else if (src.startsWith('http://') || src.startsWith('https://')) {
        provider = NetworkImage(src);
      } else {
        final f = File(src);
        if (await f.exists()) provider = FileImage(f);
      }

      if (provider != null && mounted) {
        await precacheImage(provider, context);
        _preloadedIndices.add(i);
        if (_preloadedIndices.length > 200) _preloadedIndices.clear();
      }
    } catch (_) {}
  }

  void _updatePreloadWindow(int centerIndex) async {
    if (_disposed) return;
    _preloadGeneration++;
    final myGen = _preloadGeneration;

    _precacheIndex(centerIndex);
    await _precacheIndex(centerIndex + 1);
    if (myGen != _preloadGeneration || _disposed) return;

    _precacheIndex(centerIndex - 1);

    const preloadCount = 10;
    for (int i = 2; i <= preloadCount; i++) {
      if (myGen != _preloadGeneration || _disposed) return;
      await _precacheIndex(centerIndex + i);
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

    Widget imageWidget;

    if (_isWebDavSource(source)) {
      imageWidget = FutureBuilder(
        future: _webdavFutureFor(source),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
                child: _LoadingThumb(progress: null, lightText: !isLightBg));
          }
          final resolved = snap.data;
          if (resolved == null) {
            return const Center(
                child: Text('无法解析', style: TextStyle(color: Colors.white54)));
          }
          return Image.network(
            resolved.url,
            headers: resolved.headers,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54),
            ),
            loadingBuilder: (ctx, child, loading) {
              if (loading == null) return child;
              final expected = loading.expectedTotalBytes;
              final loaded = loading.cumulativeBytesLoaded;
              final p = (expected != null && expected > 0)
                  ? (loaded / expected).clamp(0.0, 1.0)
                  : null;
              return Center(
                  child: _LoadingThumb(progress: p, lightText: !isLightBg));
            },
          );
        },
      );
    } else if (source.startsWith('http://') || source.startsWith('https://')) {
      imageWidget = Image.network(
        source,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, color: Colors.white54),
        ),
        loadingBuilder: (ctx, child, loading) {
          if (loading == null) return child;
          final expected = loading.expectedTotalBytes;
          final loaded = loading.cumulativeBytesLoaded;
          final p = (expected != null && expected > 0)
              ? (loaded / expected).clamp(0.0, 1.0)
              : null;
          return Center(
              child: _LoadingThumb(progress: p, lightText: !isLightBg));
        },
      );
    } else {
      imageWidget = Image.file(
        File(source),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, color: Colors.white54),
        ),
        frameBuilder: (ctx, child, frame, wasSyncLoaded) {
          if (wasSyncLoaded || frame != null) return child;
          return Center(
              child: _LoadingThumb(progress: null, lightText: !isLightBg));
        },
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
        child: Container(
          width: double.infinity,
          height: double.infinity,
          alignment: Alignment.center,
          child: imageWidget,
        ),
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
  }

  /// 在上下拼接模式下，先用“默认占位高度”粗略跳转到目标索引附近。
  /// 这样可以确保目标项尽快进入 build 区间，随后 ensureVisible 才能生效。
  void _jumpStripNearIndex(int idx) {
    if (!_stripMode) return;
    if (!_stripController.hasClients) return;
    final total = widget.imagePaths.length;
    if (total == 0) return;
    final safeIdx = idx.clamp(0, total - 1);

    // 与 StripImageItem.placeholderH 保持一致的估算高度。
    // 这里不追求精准，只要能把目标拉进可视区附近即可。
    const placeholderH = 220.0;
    const gap = 12.0;
    final est = safeIdx * (placeholderH + gap);

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
    _controller = PageController(initialPage: _index);

    _stripKeys =
        List<GlobalKey>.generate(widget.imagePaths.length, (_) => GlobalKey());

    _loadViewerPrefs();
    _loadImageSettings();
    _stripController.addListener(_onStripScroll);
    _applyImmersiveAndOrientation(landscape: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updatePreloadWindow(_index);
      _ensureKeyFocus();
    });
  }

  Future<void> _loadImageSettings() async {
    try {
      final v = await AppSettings.getImageVolumeKeyPaging();
      if (!mounted) return;
      setState(() => _volumeKeyPagingEnabled = v);
    } catch (_) {
      // 设置读取失败不影响看图：保持默认关闭。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _removeContextMenu();
    _restoreSystemUI();
    _controller.dispose();
    _stripController.dispose();
    _indexVN.dispose();
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

    setState(() => _index = idx);
    _indexVN.value = idx;
    _controller.jumpToPage(idx);
    _updatePreloadWindow(idx);
  }

  void _onMouseWheel(PointerScrollEvent e) {
    if (_stripMode) return;
    final now = DateTime.now();
    if (now.difference(_lastWheelAt).inMilliseconds < 120) return;
    _lastWheelAt = now;
    _removeContextMenu();
    final dy = e.scrollDelta.dy;
    if (dy > 0)
      _jumpToIndex(_index + 1);
    else if (dy < 0) _jumpToIndex(_index - 1);
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
    final safeTop = MediaQuery.of(context).padding.top + 8.0;

    int bestIndex = _index;
    double bestScore = double.infinity;
    final start = (_index - 10).clamp(0, total - 1);
    final end = (_index + 10).clamp(0, total - 1);

    for (int i = start; i <= end; i++) {
      final ctx = _stripKeys[i].currentContext;
      if (ctx == null) continue;
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.hasSize) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      final score = (dy - safeTop).abs();
      if (score < bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }

    if (bestIndex != _index) {
      _index = bestIndex;
      _indexVN.value = bestIndex;
      _updatePreloadWindow(bestIndex);
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
      alignment: 0.15,
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
      color: (isLight ? Colors.white : Colors.black).withOpacity(0.6),
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

    const menuWidth = 240.0;
    const pad = 8.0;
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

    final left = (parentLeft + parentWidth + 6.0)
        .clamp(pad, overlaySize.width - menuWidth - pad);
    final top = parentTop.clamp(pad, overlaySize.height - pad);

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

    Overlay.of(context, rootOverlay: true)?.insert(_sizeMenuEntry!);
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    _removeContextMenu();
    final overlayState = Overlay.of(context, rootOverlay: true);
    if (overlayState == null) return;

    void insert(Size overlaySize) {
      if (!mounted) return;
      if (_contextMenuEntry != null) return;

      const menuWidth = 220.0;
      const pad = 8.0;
      final dx = globalPos.dx.clamp(pad, overlaySize.width - pad);
      final dy = globalPos.dy.clamp(pad, overlaySize.height - pad);

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

      final left = (dx + menuWidth <= overlaySize.width - pad)
          ? dx
          : (dx - menuWidth).clamp(pad, overlaySize.width - menuWidth - pad);

      // ✅ 菜单项数量：用于估算高度，避免弹窗跑出屏幕。
      final itemCount = 1 + (_stripMode ? 1 : 0) + (_canRotate ? 1 : 0) + 1 + 1;
      final estH = itemCount * 44.0;

      final top = (dy + estH <= overlaySize.height - pad)
          ? dy
          : (dy - estH).clamp(pad, overlaySize.height - estH - pad);

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
                          setState(() => _stripMode = !_stripMode);
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
    final fg = Colors.white;

    return WillPopScope(
      onWillPop: () async {
        _popWithCurrentSource();
        return false;
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
                      _jumpToIndex(_index + 1);
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.audioVolumeDown ||
                        label == 'volume down' ||
                        label == 'audio volume down') {
                      _jumpToIndex(_index - 1);
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
                              cacheExtent: 1200,
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
                                          isWebDavSource: _isWebDavSource,
                                          webdavFutureFor: _webdavFutureFor,
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
                                            color: fg.withOpacity(0.5)),
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
                                            color: fg.withOpacity(0.5)),
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

/// ===============================
/// ✅ 拼接模式专用：占位高度 -> 真实高度 AnimatedSize
/// ===============================
class StripImageItem extends StatefulWidget {
  final String source;
  final double targetW;
  final Color bg;
  final bool showIndexBadge;
  final int index;
  final double placeholderH;

  final Future<({String url, Map<String, String> headers})?> Function(String)
      webdavFutureFor;
  final bool Function(String) isWebDavSource;

  const StripImageItem({
    super.key,
    required this.source,
    required this.targetW,
    required this.bg,
    required this.showIndexBadge,
    required this.index,
    required this.webdavFutureFor,
    required this.isWebDavSource,
    this.placeholderH = 220,
  });

  @override
  State<StripImageItem> createState() => _StripImageItemState();
}

class _StripImageItemState extends State<StripImageItem>
    with TickerProviderStateMixin {
  double? _ratio; // w/h
  bool _listening = false;

  bool get _lightText => widget.bg != Colors.white;

  double get _currentHeight {
    if (_ratio == null || _ratio! <= 0) return widget.placeholderH;
    final h = widget.targetW / _ratio!;
    return h.clamp(80.0, 20000.0);
  }

  Widget _badgeWrap(Widget child) {
    if (!widget.showIndexBadge) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
            left: 10, top: 10, child: _IndexBadge(text: '${widget.index + 1}')),
      ],
    );
  }

  void _resolveSizeOnce(ImageProvider provider) {
    if (_listening) return;
    _listening = true;

    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;

    listener = ImageStreamListener((ImageInfo info, bool sync) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if (mounted && w > 0 && h > 0) {
        final next = w / h;

        // ✅ 关键修复：拼接模式下，图片可能“同步命中缓存”（sync=true）。
        // 如果在 build()/FutureBuilder builder 过程中立刻 setState，
        // Flutter 会报错：setState() called during build，并诱发偶发“叠图/需要点击才恢复”。
        // 因此同步命中时延迟到下一帧更新高度，保证布局稳定。
        if (sync) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _ratio = next);
          });
        } else {
          setState(() => _ratio = next);
        }
      }
      stream.removeListener(listener);
    }, onError: (e, s) {
      stream.removeListener(listener);
    });

    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: widget.targetW,
        height: _currentHeight,
        child: ClipRect(
          child: _badgeWrap(_buildImage()),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final src = widget.source;

    // WebDAV
    if (widget.isWebDavSource(src)) {
      return FutureBuilder(
        future: widget.webdavFutureFor(src),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _LoadingThumb(progress: null, lightText: _lightText);
          }
          final resolved = snap.data;
          if (resolved == null) {
            return const Center(
                child: Icon(Icons.broken_image, color: Colors.white54));
          }

          final provider =
              NetworkImage(resolved.url, headers: resolved.headers);
          _resolveSizeOnce(provider);

          return Image(
            image: provider,
            fit: BoxFit.fitWidth,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white54)),
            loadingBuilder: (ctx, child, loading) {
              if (loading == null) return child;
              final expected = loading.expectedTotalBytes;
              final loaded = loading.cumulativeBytesLoaded;
              final p = (expected != null && expected > 0)
                  ? (loaded / expected).clamp(0.0, 1.0)
                  : null;
              return _LoadingThumb(progress: p, lightText: _lightText);
            },
          );
        },
      );
    }

    // Network
    if (src.startsWith('http://') || src.startsWith('https://')) {
      final provider = NetworkImage(src);
      _resolveSizeOnce(provider);

      return Image(
        image: provider,
        fit: BoxFit.fitWidth,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
            child: Icon(Icons.broken_image, color: Colors.white54)),
        loadingBuilder: (ctx, child, loading) {
          if (loading == null) return child;
          final expected = loading.expectedTotalBytes;
          final loaded = loading.cumulativeBytesLoaded;
          final p = (expected != null && expected > 0)
              ? (loaded / expected).clamp(0.0, 1.0)
              : null;
          return _LoadingThumb(progress: p, lightText: _lightText);
        },
      );
    }

    // Local
    final provider = FileImage(File(src));
    _resolveSizeOnce(provider);

    return Image(
      image: provider,
      fit: BoxFit.fitWidth,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
      frameBuilder: (ctx, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded || frame != null) return child;
        return _LoadingThumb(progress: null, lightText: _lightText);
      },
    );
  }
}

/// ===============================
/// 缩略图占位（图片损坏/缩略图失败）
/// ===============================
class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined),
    );
  }
}

/// ===============================
/// 加载占位 + 进度条
/// ===============================
class _LoadingThumb extends StatelessWidget {
  final double? progress;
  final bool lightText;

  const _LoadingThumb({
    required this.progress,
    required this.lightText,
  });

  @override
  Widget build(BuildContext context) {
    final fg = lightText ? Colors.white : Colors.black;

    // ✅ 必须给“安全高度”，避免 ListView 子项高度无穷导致 viewport 崩
    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedH =
            constraints.hasBoundedHeight && constraints.maxHeight.isFinite;
        final safeH = boundedH ? constraints.maxHeight : 220.0;

        return SizedBox(
          width: double.infinity,
          height: safeH,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined,
                      color: fg.withOpacity(0.55), size: 52),
                  const SizedBox(height: 12),
                  if (progress != null) ...[
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 10),
                    Text(
                      '${(progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                      style:
                          TextStyle(color: fg.withOpacity(0.75), fontSize: 13),
                    ),
                  ] else ...[
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg.withOpacity(0.4),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '加载中...',
                      style:
                          TextStyle(color: fg.withOpacity(0.75), fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// ===============================
/// 左上角数字角标（1/2/3...）
/// ===============================
class _IndexBadge extends StatelessWidget {
  final String text;
  const _IndexBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
            shadows: [Shadow(blurRadius: 2, color: Colors.black)],
          ),
        ),
      ),
    );
  }
}
