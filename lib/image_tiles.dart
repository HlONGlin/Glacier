part of 'image.dart';

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
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 2.0);
    final thumbW = (110 * dpr).round().clamp(110, 440);
    final thumbH = (90 * dpr).round().clamp(90, 360);

    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 110,
          height: 90,
          child: _isImage
              ? LocalImageThumb(
                  filePath: filePath,
                  cacheWidth: thumbW,
                  cacheHeight: thumbH,
                  fit: BoxFit.cover,
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
            try {
              await onBeforeOpenImage?.call();
            } catch (_) {}
            if (!context.mounted) return;
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
                      color: fg.withValues(alpha: 0.55), size: 52),
                  const SizedBox(height: 12),
                  if (progress != null) ...[
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 10),
                    Text(
                      '${(progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          color: fg.withValues(alpha: 0.75), fontSize: 13),
                    ),
                  ] else ...[
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg.withValues(alpha: 0.4),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '加载中...',
                      style: TextStyle(
                          color: fg.withValues(alpha: 0.75), fontSize: 13),
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

class _IndexBadge extends StatelessWidget {
  final String text;
  const _IndexBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
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
