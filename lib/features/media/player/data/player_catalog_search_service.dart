import 'play_source_resolver.dart';

class PlayerCatalogSearchService {
  PlayerCatalogSearchService._();

  static List<int> filterIndices(
    List<String> sources, {
    required String query,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return List<int>.generate(sources.length, (index) => index);
    }

    final indices = <int>[];
    for (var index = 0; index < sources.length; index++) {
      final name =
          PlayerSourceResolver.displayName(sources[index]).toLowerCase();
      if (name.contains(normalizedQuery)) {
        indices.add(index);
      }
    }
    return indices;
  }
}
