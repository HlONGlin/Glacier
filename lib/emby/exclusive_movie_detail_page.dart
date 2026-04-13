part of 'exclusive_ui.dart';

class _EmbyMovieDetailPage extends StatefulWidget {
  final EmbyAccount account;
  final String movieId;
  final EmbyItem seedMovie;
  final _EmbyPaletteMode paletteMode;

  const _EmbyMovieDetailPage({
    required this.account,
    required this.movieId,
    required this.seedMovie,
    required this.paletteMode,
  });

  @override
  State<_EmbyMovieDetailPage> createState() => _EmbyMovieDetailPageState();
}
