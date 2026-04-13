import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../sources/refs.dart';

class PlayerLocalSubtitleService {
  PlayerLocalSubtitleService._();

  static bool looksLikeLocalFilePath(String source) {
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return false;
    }
    if (isWebDavSource(source) || isEmbySource(source)) {
      return false;
    }
    return true;
  }

  static Future<List<String>> listSubtitleCandidates(String sourcePath) async {
    final normalizedPath = sourcePath.trim();
    if (!looksLikeLocalFilePath(normalizedPath)) return const <String>[];

    final currentFile = File(normalizedPath);
    if (!await currentFile.exists()) return const <String>[];

    final entries = await currentFile.parent
        .list(followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();

    final subtitles = <String>[];
    for (final file in entries) {
      final ext = p.extension(file.path).toLowerCase();
      if (ext == '.srt' || ext == '.vtt') {
        subtitles.add(file.path);
      }
    }

    subtitles.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return subtitles;
  }
}
