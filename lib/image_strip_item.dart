part of 'image.dart';

class StripImageItem extends StatefulWidget {
  final String source;
  final double targetW;
  final Color bg;
  final bool showIndexBadge;
  final int index;
  final double? initialRatio;
  final double placeholderH;

  final Future<ResolvedImageSource?> Function(String) webdavFutureFor;
  final Future<ResolvedEmbyImageSource?> Function(String) embyFutureFor;
  final bool Function(String) isWebDavSource;
  final bool Function(String) isEmbySource;
  final ValueListenable<int> centerListenable;
  final ValueListenable<int> activeRadiusListenable;

  const StripImageItem({
    super.key,
    required this.source,
    required this.targetW,
    required this.bg,
    required this.showIndexBadge,
    required this.index,
    this.initialRatio,
    required this.webdavFutureFor,
    required this.embyFutureFor,
    required this.isWebDavSource,
    required this.isEmbySource,
    required this.centerListenable,
    required this.activeRadiusListenable,
    this.placeholderH = 220,
  });

  @override
  State<StripImageItem> createState() => _StripImageItemState();
}

class _StripImageItemState extends State<StripImageItem>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  double? _ratio;
  bool _listening = false;
  bool _hasEverLoaded = false;
  bool _ratioProbeStarted = false;
  late bool _eagerLoad;
  Future<ResolvedImageSource?>? _webdavFuture;
  Future<ResolvedEmbyImageSource?>? _embyFuture;

  String get _sourceKey => widget.source.trim();

  bool get _lightText => widget.bg != Colors.white;
  BoxFit get _stripFit => _ratio == null ? BoxFit.contain : BoxFit.fitWidth;

  double get _currentHeight {
    if (_ratio == null || _ratio! <= 0) return widget.placeholderH;
    final h = widget.targetW / _ratio!;
    final maxH = MediaQuery.of(context).size.height * 2;
    return h.clamp(80.0, maxH);
  }

  int _decodeWidth() {
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 2.0);
    return max(256, (widget.targetW * dpr).round());
  }

  int _decodeHeight() {
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 2.0);
    return max(256, (_currentHeight * dpr).round());
  }

  void _rememberRatio(double ratio) {
    ImageRatioCache.remember(_sourceKey, ratio);
  }

  bool _applyCachedRatio() {
    final cached = ImageRatioCache.lookup(_sourceKey);
    if (cached == null) return false;
    _ratio = cached;
    return true;
  }

  bool _computeEagerLoad() {
    return (widget.index - widget.centerListenable.value).abs() <=
        widget.activeRadiusListenable.value;
  }

  void _handleEagerInputsChanged() {
    final next = _computeEagerLoad();
    if (next == _eagerLoad) return;
    _eagerLoad = next;
    if (_eagerLoad) {
      _ensureRatioProbeStarted();
    }
    updateKeepAlive();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    _eagerLoad = _computeEagerLoad();
    super.initState();
    widget.centerListenable.addListener(_handleEagerInputsChanged);
    widget.activeRadiusListenable.addListener(_handleEagerInputsChanged);
    final seeded = widget.initialRatio;
    if (seeded != null && seeded > 0 && seeded.isFinite) {
      _ratio = seeded;
      _rememberRatio(seeded);
    }
    _applyCachedRatio();
    if (_ratio == null && widget.isEmbySource(widget.source)) {
      _fetchEmbyAspectRatio();
    }
    if (_eagerLoad) {
      _ensureRatioProbeStarted();
    }
  }

  Future<void> _fetchEmbyAspectRatio() async {
    try {
      final result = await widget.embyFutureFor(widget.source);
      if (result != null &&
          result.aspectRatio != null &&
          result.aspectRatio! > 0 &&
          result.aspectRatio!.isFinite) {
        if (mounted) {
          setState(() {
            _ratio = result.aspectRatio;
            _rememberRatio(result.aspectRatio!);
          });
        }
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant StripImageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.centerListenable != widget.centerListenable) {
      oldWidget.centerListenable.removeListener(_handleEagerInputsChanged);
      widget.centerListenable.addListener(_handleEagerInputsChanged);
    }
    if (oldWidget.activeRadiusListenable != widget.activeRadiusListenable) {
      oldWidget.activeRadiusListenable
          .removeListener(_handleEagerInputsChanged);
      widget.activeRadiusListenable.addListener(_handleEagerInputsChanged);
    }
    _handleEagerInputsChanged();
    if (oldWidget.source != widget.source) {
      _ratio = null;
      _listening = false;
      _hasEverLoaded = false;
      _ratioProbeStarted = false;
      _webdavFuture = null;
      _embyFuture = null;
      final seeded = widget.initialRatio;
      if (seeded != null && seeded > 0 && seeded.isFinite) {
        _ratio = seeded;
        _rememberRatio(seeded);
      }
      _applyCachedRatio();
      if (_ratio == null && widget.isEmbySource(widget.source)) {
        _fetchEmbyAspectRatio();
      }
      if (_eagerLoad) {
        _ensureRatioProbeStarted();
      }
    }
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
    if (_ratio != null && _ratio! > 0) return;
    if (_applyCachedRatio()) {
      return;
    }
    if (_listening) return;
    _listening = true;

    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;

    listener = ImageStreamListener((ImageInfo info, bool sync) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if (mounted && w > 0 && h > 0) {
        final next = w / h;
        _rememberRatio(next);
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
      _listening = false;
    });

    stream.addListener(listener);
  }

  void _ensureRatioProbeStarted() {
    if (_ratio != null && _ratio! > 0) return;
    if (_applyCachedRatio()) return;
    if (_ratioProbeStarted) return;
    _ratioProbeStarted = true;
    unawaited(_probeRatioAsync());
  }

  Future<void> _probeRatioAsync() async {
    try {
      final src = widget.source;
      if (widget.isWebDavSource(src)) {
        final future = _webdavFuture ??= widget.webdavFutureFor(src);
        final resolved = await future;
        if (!mounted || resolved == null) return;
        _resolveSizeOnce(NetworkImage(resolved.url, headers: resolved.headers));
        return;
      }
      if (widget.isEmbySource(src)) {
        final future = _embyFuture ??= widget.embyFutureFor(src);
        final resolved = await future;
        if (!mounted || resolved == null) return;
        _resolveSizeOnce(NetworkImage(resolved.url, headers: resolved.headers));
        return;
      }
      if (src.startsWith('http://') || src.startsWith('https://')) {
        _resolveSizeOnce(NetworkImage(src));
        return;
      }
      _resolveSizeOnce(FileImage(File(src)));
    } catch (_) {
      _ratioProbeStarted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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

  @override
  bool get wantKeepAlive => _eagerLoad;

  Widget _buildImage() {
    if (!_eagerLoad && !_hasEverLoaded) {
      return _LoadingThumb(progress: null, lightText: _lightText);
    }

    if (_eagerLoad) {
      _ensureRatioProbeStarted();
    }

    final src = widget.source;
    final decodeW = _decodeWidth();
    final decodeH = _decodeHeight();

    if (widget.isWebDavSource(src)) {
      final future = _webdavFuture ??= widget.webdavFutureFor(src);
      return FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _LoadingThumb(progress: null, lightText: _lightText);
          }
          final resolved = snap.data;
          if (resolved == null) {
            return const Center(
                child: Icon(Icons.broken_image, color: Colors.white54));
          }
          _hasEverLoaded = true;

          final provider = SharedImageProviderCache.network(
            resolved.url,
            headers: resolved.headers,
            width: decodeW,
            height: decodeH,
          );
          if (_ratio == null) {
            return _LoadingThumb(progress: null, lightText: _lightText);
          }

          return Image(
            image: provider,
            fit: _stripFit,
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

    if (widget.isEmbySource(src)) {
      final future = _embyFuture ??= widget.embyFutureFor(src);
      return FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _LoadingThumb(progress: null, lightText: _lightText);
          }
          final resolved = snap.data;
          if (resolved == null) {
            return const Center(
                child: Icon(Icons.broken_image, color: Colors.white54));
          }
          _hasEverLoaded = true;

          final provider = SharedImageProviderCache.network(
            resolved.url,
            headers: resolved.headers,
            width: decodeW,
            height: decodeH,
          );
          if (_ratio == null) {
            return _LoadingThumb(progress: null, lightText: _lightText);
          }

          return Image(
            image: provider,
            fit: _stripFit,
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

    if (src.startsWith('http://') || src.startsWith('https://')) {
      _hasEverLoaded = true;
      final provider = SharedImageProviderCache.network(
        src,
        width: decodeW,
        height: decodeH,
      );
      if (_ratio == null) {
        return _LoadingThumb(progress: null, lightText: _lightText);
      }

      return Image(
        image: provider,
        fit: _stripFit,
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

    _hasEverLoaded = true;
    final provider = SharedImageProviderCache.local(
      src,
      width: decodeW,
      height: decodeH,
    );
    if (_ratio == null) {
      return _LoadingThumb(progress: null, lightText: _lightText);
    }

    return Image(
      image: provider,
      fit: _stripFit,
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

  @override
  void dispose() {
    widget.centerListenable.removeListener(_handleEagerInputsChanged);
    widget.activeRadiusListenable.removeListener(_handleEagerInputsChanged);
    super.dispose();
  }
}
