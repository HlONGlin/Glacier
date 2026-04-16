import 'package:flutter/material.dart';

import 'provider_helpers.dart';
import 'source_resolver.dart';

class ImageViewerRenderHelpers {
  ImageViewerRenderHelpers._();

  static Widget buildAlbumImageFrame({
    required ImageProvider provider,
    required bool lightText,
    required Widget Function(double? progress, bool lightText) loadingBuilder,
    FilterQuality filterQuality = FilterQuality.medium,
  }) {
    return _AlbumImageFrame(
      provider: provider,
      lightText: lightText,
      loadingBuilder: loadingBuilder,
      filterQuality: filterQuality,
    );
  }

  static Widget buildWebDavImage({
    required BuildContext context,
    required Future<ResolvedImageSource?> future,
    required int cacheWidth,
    required int cacheHeight,
    required bool lightText,
    required Widget Function(double? progress, bool lightText) loadingBuilder,
  }) {
    return FutureBuilder(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(child: loadingBuilder(null, lightText));
        }
        final resolved = snap.data;
        if (resolved == null) {
          return const Center(
            child: Text('无法解析', style: TextStyle(color: Colors.white54)),
          );
        }
        return Image(
          image: SharedImageProviderCache.network(
            resolved.url,
            headers: resolved.headers,
            width: cacheWidth,
            height: cacheHeight,
          ),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54)),
          loadingBuilder: (ctx, child, loading) {
            if (loading == null) return child;
            final expected = loading.expectedTotalBytes;
            final loaded = loading.cumulativeBytesLoaded;
            final progress = (expected != null && expected > 0)
                ? (loaded / expected).clamp(0.0, 1.0)
                : null;
            return Center(child: loadingBuilder(progress, lightText));
          },
        );
      },
    );
  }

  static Widget buildEmbyImage({
    required BuildContext context,
    required Future<ResolvedEmbyImageSource?> future,
    required int cacheWidth,
    required int cacheHeight,
    required bool lightText,
    required Widget Function(double? progress, bool lightText) loadingBuilder,
  }) {
    return FutureBuilder(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(child: loadingBuilder(null, lightText));
        }
        final resolved = snap.data;
        if (resolved == null) {
          return const Center(
            child: Text('无法解析', style: TextStyle(color: Colors.white54)),
          );
        }
        return Image(
          image: SharedImageProviderCache.network(
            resolved.url,
            headers: resolved.headers,
            width: cacheWidth,
            height: cacheHeight,
          ),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54)),
          loadingBuilder: (ctx, child, loading) {
            if (loading == null) return child;
            final expected = loading.expectedTotalBytes;
            final loaded = loading.cumulativeBytesLoaded;
            final progress = (expected != null && expected > 0)
                ? (loaded / expected).clamp(0.0, 1.0)
                : null;
            return Center(child: loadingBuilder(progress, lightText));
          },
        );
      },
    );
  }

  static Widget buildNetworkImage({
    required String source,
    required int cacheWidth,
    required int cacheHeight,
    required bool lightText,
    required Widget Function(double? progress, bool lightText) loadingBuilder,
  }) {
    return Image(
      image: SharedImageProviderCache.network(
        source,
        width: cacheWidth,
        height: cacheHeight,
      ),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
      loadingBuilder: (ctx, child, loading) {
        if (loading == null) return child;
        final expected = loading.expectedTotalBytes;
        final loaded = loading.cumulativeBytesLoaded;
        final progress = (expected != null && expected > 0)
            ? (loaded / expected).clamp(0.0, 1.0)
            : null;
        return Center(child: loadingBuilder(progress, lightText));
      },
    );
  }

  static Widget buildLocalImage({
    required String source,
    required int cacheWidth,
    required int cacheHeight,
    required bool lightText,
    required Widget Function(double? progress, bool lightText) loadingBuilder,
  }) {
    return Image(
      image: SharedImageProviderCache.local(
        source,
        width: cacheWidth,
        height: cacheHeight,
      ),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
      frameBuilder: (ctx, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded || frame != null) return child;
        return Center(child: loadingBuilder(null, lightText));
      },
    );
  }
}

class _AlbumImageFrame extends StatefulWidget {
  final ImageProvider provider;
  final bool lightText;
  final Widget Function(double? progress, bool lightText) loadingBuilder;
  final FilterQuality filterQuality;

  const _AlbumImageFrame({
    required this.provider,
    required this.lightText,
    required this.loadingBuilder,
    required this.filterQuality,
  });

  @override
  State<_AlbumImageFrame> createState() => _AlbumImageFrameState();
}

class _AlbumImageFrameState extends State<_AlbumImageFrame> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant _AlbumImageFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _detach();
      _aspectRatio = null;
      _attach();
    }
  }

  void _attach() {
    final stream = widget.provider.resolve(const ImageConfiguration());
    _stream = stream;
    _listener = ImageStreamListener(
      (ImageInfo info, bool syncCall) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (!mounted || w <= 0 || h <= 0) return;
        final next = w / h;
        if (_aspectRatio == next) return;
        setState(() => _aspectRatio = next);
      },
      onError: (_, __) {},
    );
    stream.addListener(_listener!);
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatio;
    if (ratio == null || ratio <= 0 || !ratio.isFinite) {
      return Center(child: widget.loadingBuilder(null, widget.lightText));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        final viewportRatio = maxWidth / maxHeight;
        late final double width;
        late final double height;

        if (ratio >= viewportRatio) {
          width = maxWidth;
          height = width / ratio;
        } else {
          height = maxHeight;
          width = height * ratio;
        }

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: Image(
              image: widget.provider,
              fit: BoxFit.fill,
              filterQuality: widget.filterQuality,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white54),
              ),
              loadingBuilder: (ctx, child, loading) {
                if (loading == null) return child;
                final expected = loading.expectedTotalBytes;
                final loaded = loading.cumulativeBytesLoaded;
                final progress = (expected != null && expected > 0)
                    ? (loaded / expected).clamp(0.0, 1.0)
                    : null;
                return Center(
                  child: widget.loadingBuilder(progress, widget.lightText),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
