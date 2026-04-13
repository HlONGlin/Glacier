import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'tag_models.dart';

class TagInteractionHelpers {
  TagInteractionHelpers._();

  static Future<Set<String>?> showEditTargetTagsDialog(
    BuildContext context, {
    required TagTargetMeta meta,
    required List<Tag> allTags,
    required Set<String> initialSelected,
  }) {
    return showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        final selected = Set<String>.from(initialSelected);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text('编辑标签：${meta.name}'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in allTags)
                        FilterChip(
                          label: Text(tag.name),
                          selected: selected.contains(tag.id),
                          onSelected: (enabled) => setDialogState(() {
                            if (enabled) {
                              selected.add(tag.id);
                            } else {
                              selected.remove(tag.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => setDialogState(() => selected.clear()),
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(selected),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<Tag?> showStoreToTagMenu(
    BuildContext context, {
    required Offset globalPosition,
    required List<Tag> tagsForItem,
  }) async {
    final tagsWithDirectory =
        tagsForItem.where((tag) => tag.localPath != null).toList();
    if (tagsWithDirectory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标签未绑定目录')),
      );
      return null;
    }

    return showMenu<Tag>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: tagsWithDirectory.map((tag) {
        return PopupMenuItem<Tag>(
          value: tag,
          child: Text('存入：${tag.name}'),
        );
      }).toList(),
    );
  }

  static Future<Set<String>?> showTagFilterBottomSheet(
    BuildContext context, {
    required List<Tag> tags,
    required Set<String> initialSelected,
  }) {
    return showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final temp = Set<String>.from(initialSelected);
        var query = '';
        return StatefulBuilder(
          builder: (ctx2, setSheetState) {
            final filtered = query.trim().isEmpty
                ? tags
                : tags
                    .where((tag) => tag.name
                        .toLowerCase()
                        .contains(query.trim().toLowerCase()))
                    .toList();
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx2).size.height * 0.72,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Tag 筛选',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton(
                            onPressed: () => setSheetState(() => temp.clear()),
                            child: const Text('全部'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        onChanged: (value) =>
                            setSheetState(() => query = value),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '搜索标签',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: query.trim().isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除',
                                  onPressed: () =>
                                      setSheetState(() => query = ''),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('没有匹配的标签'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (_, index) {
                                final tag = filtered[index];
                                return CheckboxListTile(
                                  value: temp.contains(tag.id),
                                  onChanged: (enabled) => setSheetState(() {
                                    if (enabled == true) {
                                      temp.add(tag.id);
                                    } else {
                                      temp.remove(tag.id);
                                    }
                                  }),
                                  title: Text(tag.name),
                                  secondary: CircleAvatar(
                                    radius: 8,
                                    backgroundColor: Color(tag.colorValue),
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.trailing,
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              temp.isEmpty
                                  ? '当前：全部文件'
                                  : '当前：已选 ${temp.length} 个 Tag',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx2, temp),
                            child: const Text('应用'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String storedPathLabel(Tag tag) {
    return p.basename(tag.localPath ?? '');
  }
}
