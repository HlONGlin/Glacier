part of 'emby_exclusive_ui.dart';

extension _EmbySeriesDetailUi on _EmbySeriesDetailPageState {
  Widget _metaChip({required IconData icon, required String text}) {
    final p = _palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.chipBg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: p.text),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: p.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeProgressBar(_UiItem ep) {
    final ratio = EmbyExclusiveSeriesHelpers.progressRatio(ep.item);
    if (ratio <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 4,
        color: Colors.black.withValues(alpha: 0.34),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio,
          child: Container(color: _palette.progress),
        ),
      ),
    );
  }

  Widget _episodeStatusBadge(_UiItem ep) {
    final label = ep.item.isPlayed
        ? '已看'
        : _isResumableEpisode(ep.item)
            ? '继续播放'
            : '未看';
    return Positioned(
      left: 8,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.46),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _episodeThumbUrl(_UiItem ep) {
    final tag = ep.item.thumbTag;
    if (tag != null && tag.trim().isNotEmpty) {
      return _client.coverUrl(
        ep.item.id,
        type: 'Thumb',
        maxWidth: 640,
        quality: 85,
        tag: tag,
      );
    }
    return ep.coverUrl;
  }

  Widget _nextUpCard(_UiItem ep, {required List<_UiItem> playlist}) {
    final p = _palette;
    final thumb = _episodeThumbUrl(ep).trim();
    final code = _episodeCode(ep.item);
    final title = code.isEmpty ? ep.title : '$code · ${ep.title}';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _playEpisode(ep, pool: playlist),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 156,
                height: 88,
                child: thumb.isEmpty
                    ? ColoredBox(
                        color: p.coverPlaceholderBg,
                        child: Center(
                          child: Icon(Icons.movie_outlined, color: p.sub),
                        ),
                      )
                    : Image.network(
                        thumb,
                        headers: _headers,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        filterQuality: FilterQuality.low,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => ColoredBox(
                          color: p.coverPlaceholderBg,
                          child: Center(
                            child:
                                Icon(Icons.broken_image_outlined, color: p.sub),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '下一集',
                    style: TextStyle(
                      color: p.sub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.chipSelectedBg,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.play_arrow_rounded, color: p.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(EmbyItem series) {
    final p = _palette;
    final backdrop = _backdropUrl(series).trim();
    return SizedBox(
      height: 286,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            Image.network(
              backdrop,
              headers: _headers,
              fit: BoxFit.cover,
              cacheWidth: 1400,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: p.coverPlaceholderBg),
            )
          else
            ColoredBox(color: p.coverPlaceholderBg),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.68),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '收藏',
                    onPressed: () => showAppToast(
                      context,
                      '暂不支持收藏',
                    ),
                    icon: const Icon(Icons.favorite_border_rounded,
                        color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 18,
            child: Text(
              series.name.trim().isEmpty ? '未命名剧集' : series.name.trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 14, color: Colors.black54)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeShelf(List<_UiItem> items) {
    final p = _palette;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('暂无内容', style: TextStyle(color: p.sub)),
      );
    }
    final shelf = items.take(20).toList(growable: false);
    final playlist = _episodePlaylist();
    final numberById = _episodeNumberById(playlist);
    return SizedBox(
      height: 138,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: shelf.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final ep = shelf[i];
          final code = _episodeCode(ep.item);
          final no = numberById[ep.item.id.trim()];
          final title = code.isNotEmpty
              ? '$code · ${ep.title}'
              : (no == null ? ep.title : '$no. ${ep.title}');
          final thumb = _episodeThumbUrl(ep).trim();
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _playEpisode(ep, pool: playlist),
            child: SizedBox(
              width: 182,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          thumb.isEmpty
                              ? ColoredBox(
                                  color: p.coverPlaceholderBg,
                                  child: Center(
                                    child: Icon(Icons.movie_outlined,
                                        color: p.sub),
                                  ),
                                )
                              : Image.network(
                                  thumb,
                                  headers: _headers,
                                  fit: BoxFit.cover,
                                  cacheWidth: 640,
                                  filterQuality: FilterQuality.low,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) => ColoredBox(
                                    color: p.coverPlaceholderBg,
                                    child: Center(
                                      child: Icon(Icons.broken_image_outlined,
                                          color: p.sub),
                                    ),
                                  ),
                                ),
                          _episodeStatusBadge(ep),
                          _episodeProgressBar(ep),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _seasonShelf(List<_UiItem> items) {
    final p = _palette;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('暂无分季信息', style: TextStyle(color: p.sub)),
      );
    }
    return SizedBox(
      height: 216,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final season = items[i];
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openSeason(season),
            child: SizedBox(
              width: 112,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 0.67,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: season.coverUrl.trim().isEmpty
                          ? ColoredBox(
                              color: p.coverPlaceholderBg,
                              child: Center(
                                child: Icon(Icons.video_collection_outlined,
                                    color: p.sub),
                              ),
                            )
                          : Image.network(
                              season.coverUrl,
                              headers: _headers,
                              fit: BoxFit.cover,
                              cacheWidth: 420,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                color: p.coverPlaceholderBg,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: p.sub),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    season.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    EmbyExclusiveSeriesHelpers.seasonSubtitle(season),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.sub, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
