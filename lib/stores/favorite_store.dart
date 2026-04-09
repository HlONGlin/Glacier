import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_models.dart';

class FavoriteStore {
  static const _kV2 = 'favorite_collections_v2';
  static const _kV1 = 'favorite_folders_v1';

  static Future<List<FavoriteCollection>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kV2);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          final out = list
              .whereType<Map>()
              .map(
                  (m) => FavoriteCollection.fromJson(m.cast<String, dynamic>()))
              .toList();

          for (final c in out) {
            for (var i = 0; i < c.sources.length; i++) {
              c.sources[i] = c.sources[i].replaceAllMapped(
                RegExp(r'%(?![0-9A-Fa-f]{2})'),
                (_) => '%25',
              );
            }
          }
          await save(out);
          return out;
        }
      } catch (_) {}
    }

    final legacy = prefs.getStringList(_kV1);
    if (legacy != null && legacy.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <FavoriteCollection>[];
      for (var i = 0; i < legacy.length; i++) {
        final src = p.normalize(legacy[i]);
        out.add(
          FavoriteCollection(
            id: '${now}_$i',
            name: p.basename(src).isEmpty ? '收藏夹${i + 1}' : p.basename(src),
            sources: [src],
            coverPath: null,
            layer1: LayerSettings(
              viewMode: ViewMode.gallery,
              sortKey: SortKey.name,
              asc: true,
            ),
            layer2: LayerSettings(
              viewMode: ViewMode.list,
              sortKey: SortKey.name,
              asc: true,
            ),
          ),
        );
      }
      await save(out);
      return out;
    }
    return <FavoriteCollection>[];
  }

  static Future<void> save(List<FavoriteCollection> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kV2, jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}
