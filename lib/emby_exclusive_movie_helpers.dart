import 'emby.dart';

String embyMovieDurationLabel(int? runTimeTicks) {
  final ticks = runTimeTicks ?? 0;
  if (ticks <= 0) return '';
  const ticksPerMinute = 600000000;
  final totalMinutes = ticks ~/ ticksPerMinute;
  if (totalMinutes <= 0) return '';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours <= 0) return '${totalMinutes}m';
  if (minutes <= 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

String embyMovieMetaLine(EmbyItem movie) {
  final parts = <String>[];
  final rating = movie.communityRating;
  if (rating != null && rating > 0) {
    parts.add('评分 ${rating.toStringAsFixed(1)}');
  }
  final year = movie.productionYear;
  if (year != null && year > 0) {
    parts.add('$year');
  }
  final duration = embyMovieDurationLabel(movie.runTimeTicks);
  if (duration.isNotEmpty) {
    parts.add(duration);
  }
  return parts.join('  ·  ');
}

bool embyMovieIsResumable(EmbyItem movie) {
  final played = movie.playedPercentage ?? 0;
  if (movie.playbackPositionTicks > 0 && played < 95) return true;
  return movie.playbackPositionTicks > 0 && !movie.isPlayed;
}

String embyMovieStatusText(EmbyItem movie) {
  if (movie.isPlayed) return '已看完';
  if (embyMovieIsResumable(movie)) return '继续播放';
  return '未开始';
}
