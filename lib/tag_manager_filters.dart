import 'tag_models.dart';

enum TagManagerSortMode { kind, name, tagCount }

class TagManagerFilters {
  TagManagerFilters._();

  static List<Tag> filterTags(
    List<Tag> tags, {
    required String query,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? tags.toList()
        : tags
            .where((tag) => tag.name.toLowerCase().contains(normalizedQuery))
            .toList();
    filtered.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return filtered;
  }

  static List<TagTargetMeta> filterTargets({
    required Iterable<Tag> allTags,
    required Set<String> selectedTagIds,
    required List<TagTargetMeta> Function(String tagId) targetsOfTag,
    required Set<String> Function(String targetKey) tagsOfTarget,
    required String query,
    required TagManagerSortMode sortMode,
    required bool sortAsc,
  }) {
    final seen = <String>{};
    final out = <TagTargetMeta>[];

    final sourceTagIds =
        selectedTagIds.isEmpty ? allTags.map((tag) => tag.id) : selectedTagIds;
    for (final tagId in sourceTagIds) {
      for (final item in targetsOfTag(tagId)) {
        if (seen.add(item.key)) out.add(item);
      }
    }

    final normalizedQuery = query.trim().toLowerCase();
    var items = normalizedQuery.isEmpty
        ? out
        : out
            .where((item) => item.name.toLowerCase().contains(normalizedQuery))
            .toList();

    items.sort((left, right) {
      int result;
      switch (sortMode) {
        case TagManagerSortMode.name:
          result = left.name.toLowerCase().compareTo(right.name.toLowerCase());
          break;
        case TagManagerSortMode.tagCount:
          final leftCount = tagsOfTarget(left.key).length;
          final rightCount = tagsOfTarget(right.key).length;
          final compare = leftCount.compareTo(rightCount);
          result = compare == 0
              ? left.name.toLowerCase().compareTo(right.name.toLowerCase())
              : compare;
          break;
        case TagManagerSortMode.kind:
          final compare = left.kind.index.compareTo(right.kind.index);
          result = compare == 0
              ? left.name.toLowerCase().compareTo(right.name.toLowerCase())
              : compare;
          break;
      }
      return sortAsc ? result : -result;
    });

    return items;
  }
}
