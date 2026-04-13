import 'package:flutter/material.dart';

import 'provider_helpers.dart';
import 'source_resolver.dart';

class ImageViewerRenderHelpers {
  ImageViewerRenderHelpers._();

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
        final screenSize = MediaQuery.of(context).size;
        final screenWidth = screenSize.width;
        double imageHeight = screenSize.height;
        if (resolved.aspectRatio != null && resolved.aspectRatio! > 0) {
          imageHeight = screenWidth / resolved.aspectRatio!;
        }
        return SizedBox(
          width: screenWidth,
          height: imageHeight,
          child: Image(
            image: SharedImageProviderCache.network(
              resolved.url,
              headers: resolved.headers,
              width: cacheWidth,
              height: cacheHeight,
            ),
            fit: BoxFit.fill,
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
          ),
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
