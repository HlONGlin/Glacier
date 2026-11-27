import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class OfflineDownload {
  const OfflineDownload({
    required this.path,
    required this.name,
    required this.size,
    required this.downloadedAt,
  });

  final String path;
  final String name;
  final int size;
  final DateTime downloadedAt;

  Map<String, Object> toJson() => <String, Object>{
        'path': path,
        'name': name,
        'size': size,
        'downloadedAt': downloadedAt.toIso8601String(),
      };

  static OfflineDownload? fromJson(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final name = value['name'];
    final size = value['size'];
    final downloadedAt = DateTime.tryParse('${value['downloadedAt'] ?? ''}');
    if (path is! String || path.isEmpty || name is! String || size is! int) {
      return null;
    }
    if (downloadedAt == null) return null;
    return OfflineDownload(
      path: path,
      name: name,
      size: size,
      downloadedAt: downloadedAt,
    );
  }
}

class OfflineDownloadStore {
  static const String _key = 'glacier_offline_downloads_v1';

  static Future<List<OfflineDownload>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <OfflineDownload>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <OfflineDownload>[];
      return decoded
          .map(OfflineDownload.fromJson)
          .whereType<OfflineDownload>()
          .toList(growable: false);
    } on FormatException {
      return <OfflineDownload>[];
    }
  }

  static Future<void> record(File file) async {
    final stat = await file.stat();
    final entries = await load();
    final next = <OfflineDownload>[
      OfflineDownload(
        path: file.absolute.path,
        name: file.uri.pathSegments.isEmpty
            ? file.path
            : file.uri.pathSegments.last,
        size: stat.size,
        downloadedAt: stat.modified,
      ),
      ...entries.where((entry) => entry.path != file.absolute.path),
    ];
    await _save(next);
  }

  static Future<void> remove(String path, {bool deleteFile = false}) async {
    if (deleteFile) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    final entries = await load();
    await _save(entries.where((entry) => entry.path != path).toList());
  }

  static Future<void> _save(List<OfflineDownload> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }
}
