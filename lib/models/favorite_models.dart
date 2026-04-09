import 'package:path/path.dart' as p;

enum ViewMode { list, gallery, grid }

enum SortKey { name, date, size, type }

class LayerSettings {
  ViewMode viewMode;
  SortKey sortKey;
  bool asc;

  LayerSettings({
    this.viewMode = ViewMode.gallery,
    this.sortKey = SortKey.name,
    this.asc = true,
  });

  Map<String, dynamic> toJson() => {
        'v': viewMode.index,
        's': sortKey.index,
        'a': asc,
      };

  static LayerSettings fromJson(dynamic j) {
    if (j is! Map) return LayerSettings();
    final v = (j['v'] is int) ? (j['v'] as int) : 1;
    final s = (j['s'] is int) ? (j['s'] as int) : 0;
    final a = (j['a'] is bool) ? (j['a'] as bool) : true;
    return LayerSettings(
      viewMode: ViewMode.values[v.clamp(0, ViewMode.values.length - 1)],
      sortKey: SortKey.values[s.clamp(0, SortKey.values.length - 1)],
      asc: a,
    );
  }

  LayerSettings copy() =>
      LayerSettings(viewMode: viewMode, sortKey: sortKey, asc: asc);
}

class FavoriteCollection {
  final String id;
  String name;
  List<String> sources;
  String? coverPath;
  LayerSettings layer1;
  LayerSettings layer2;

  FavoriteCollection({
    required this.id,
    required this.name,
    required this.sources,
    required this.layer1,
    required this.layer2,
    this.coverPath,
  });

  FavoriteCollection copy() => FavoriteCollection(
        id: id,
        name: name,
        sources: [...sources],
        coverPath: coverPath,
        layer1: layer1.copy(),
        layer2: layer2.copy(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sources': sources,
        'cover': coverPath,
        'l1': layer1.toJson(),
        'l2': layer2.toJson(),
      };

  static FavoriteCollection fromJson(Map<String, dynamic> j) =>
      FavoriteCollection(
        id: (j['id'] ?? '').toString().isEmpty
            ? DateTime.now().millisecondsSinceEpoch.toString()
            : (j['id'] ?? '').toString(),
        name: ((j['name'] ?? '').toString().trim().isEmpty)
            ? '未命名收藏夹'
            : (j['name'] ?? '').toString(),
        sources: (j['sources'] is List)
            ? (j['sources'] as List).map((e) => e.toString()).toList()
            : <String>[],
        coverPath:
            j['cover'] == null ? null : p.normalize(j['cover'].toString()),
        layer1: LayerSettings.fromJson(j['l1']),
        layer2: LayerSettings.fromJson(j['l2']),
      );
}
