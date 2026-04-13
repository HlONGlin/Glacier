part of 'emby_exclusive_ui.dart';

List<Widget> _buildMovieFactChips(_EmbyPalette palette, EmbyItem movie) {
  final out = <Widget>[];
  final rating = movie.communityRating;
  if (rating != null && rating > 0) {
    out.add(_detailFactChip(
      palette,
      icon: Icons.star_rounded,
      label: rating.toStringAsFixed(1),
      highlight: true,
    ));
  }
  final year = movie.productionYear;
  if (year != null && year > 0) {
    out.add(_detailFactChip(
      palette,
      icon: Icons.calendar_today_outlined,
      label: '$year',
    ));
  }
  final duration = embyMovieDurationLabel(movie.runTimeTicks);
  if (duration.isNotEmpty) {
    out.add(_detailFactChip(
      palette,
      icon: Icons.schedule_rounded,
      label: duration,
    ));
  }
  out.add(_detailFactChip(
    palette,
    icon: Icons.movie_outlined,
    label: '电影',
  ));
  return out;
}

Widget _buildMovieSummaryPanel(
  _EmbyPalette palette,
  EmbyItem movie, {
  required String poster,
  required Map<String, String>? headers,
  required String statusText,
}) {
  return Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: palette.panel,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 104,
            height: 156,
            child: poster.isEmpty
                ? ColoredBox(
                    color: palette.coverPlaceholderBg,
                    child: Center(
                      child: Icon(Icons.movie_outlined,
                          color: palette.sub, size: 28),
                    ),
                  )
                : Image.network(
                    poster,
                    headers: headers,
                    fit: BoxFit.cover,
                    cacheWidth: 520,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => ColoredBox(
                      color: palette.coverPlaceholderBg,
                      child: Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: palette.sub, size: 24),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                movie.name.trim().isEmpty ? '未命名电影' : movie.name.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _buildMovieFactChips(palette, movie),
              ),
              const SizedBox(height: 10),
              Text(
                statusText,
                style: TextStyle(
                  color: palette.sub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (movie.genres.isNotEmpty) ...[
                const SizedBox(height: 10),
                _detailGenreWrap(palette, movie.genres),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _buildMovieHero(
  BuildContext context,
  _EmbyPalette palette,
  EmbyItem movie, {
  required String backdrop,
  required Map<String, String>? headers,
}) {
  return SizedBox(
    height: 286,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop.isNotEmpty)
          Image.network(
            backdrop,
            headers: headers,
            fit: BoxFit.cover,
            cacheWidth: 1400,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) =>
                ColoredBox(color: palette.coverPlaceholderBg),
          )
        else
          ColoredBox(color: palette.coverPlaceholderBg),
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
              ],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: Text(
            movie.name.trim().isEmpty ? '未命名电影' : movie.name.trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
