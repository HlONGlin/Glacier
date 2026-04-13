import 'tag_models.dart';

class TagStoreAlgorithms {
  TagStoreAlgorithms._();

  static List<Tag> sortedTags(Iterable<Tag> tags) {
    final list = tags.toList();
    list.sort((left, right) =>
        left.name.toLowerCase().compareTo(right.name.toLowerCase()));
    return list;
  }

  static List<TagTargetMeta> sortedTargetsForTag(
    String tagId, {
    required Map<String, Set<String>> targetToTagIds,
    required Map<String, TagTargetMeta> targetsByKey,
  }) {
    final out = <TagTargetMeta>[];
    for (final entry in targetToTagIds.entries) {
      if (entry.value.contains(tagId)) {
        final meta = targetsByKey[entry.key];
        if (meta != null) out.add(meta);
      }
    }
    out.sort((left, right) =>
        left.name.toLowerCase().compareTo(right.name.toLowerCase()));
    return out;
  }

  static void removeTag(
    String tagId, {
    required Map<String, Tag> tagsById,
    required Map<String, Set<String>> targetToTagIds,
    required Map<String, TagTargetMeta> targetsByKey,
  }) {
    tagsById.remove(tagId);
    final orphanTargets = <String>[];
    for (final entry in targetToTagIds.entries) {
      entry.value.remove(tagId);
      if (entry.value.isEmpty) orphanTargets.add(entry.key);
    }
    for (final key in orphanTargets) {
      targetToTagIds.remove(key);
      targetsByKey.remove(key);
    }
  }

  static void setTagsForTarget(
    TagTargetMeta target,
    Set<String> tagIds, {
    required Map<String, Set<String>> targetToTagIds,
    required Map<String, TagTargetMeta> targetsByKey,
  }) {
    if (tagIds.isEmpty) {
      targetToTagIds.remove(target.key);
      targetsByKey.remove(target.key);
      return;
    }
    targetToTagIds[target.key] = Set<String>.from(tagIds);
    targetsByKey[target.key] = target;
  }

  static Set<String> toggledTags(Set<String> existing, String tagId) {
    final next = Set<String>.from(existing);
    if (next.contains(tagId)) {
      next.remove(tagId);
    } else {
      next.add(tagId);
    }
    return next;
  }
}
