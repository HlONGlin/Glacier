part of 'tag.dart';

class _TagsView extends StatelessWidget {
  final List<Tag> tags;
  final ValueChanged<Tag> onRename;
  final ValueChanged<Tag> onDelete;

  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;
  final TagDirectoryOpenCallback? onOpenTagDirectory;

  const _TagsView({
    required this.tags,
    required this.onRename,
    required this.onDelete,
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    this.onOpenTagDirectory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showSearch = searchExpanded || query.trim().isNotEmpty;

    return Column(children: [
      Material(
        color: theme.colorScheme.surface,
        elevation: 0.6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.sell_outlined, size: 18),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '标签列表',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('${tags.length} 项'),
                ],
              ),
              if (showSearch) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  width: double.infinity,
                  child: TextField(
                    onChanged: onQueryChanged,
                    controller: TextEditingController(text: query)
                      ..selection =
                          TextSelection.collapsed(offset: query.length),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索标签',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: query.trim().isEmpty
                          ? IconButton(
                              tooltip: '收起',
                              icon: const Icon(Icons.expand_less, size: 18),
                              onPressed: () => onSearchExpandedChanged(false),
                            )
                          : IconButton(
                              tooltip: '清除',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => onQueryChanged(''),
                            ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      Expanded(
        child: tags.isEmpty
            ? const Center(child: Text('没有匹配的标签'))
            : ListView.separated(
                itemCount: tags.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = tags[i];
                  final count = TagStore.I.targetsOfTag(t.id).length;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Color(t.colorValue),
                      child: const Icon(Icons.sell_outlined,
                          color: Colors.white, size: 20),
                    ),
                    title: Text(t.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$count 个文件'),
                        if (t.localPath != null)
                          Text('物理存放：${p.basename(t.localPath!)}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.primary)),
                      ],
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '标签操作',
                      onSelected: (v) async {
                        if (v == 'rename') onRename(t);
                        if (v == 'delete') onDelete(t);
                        if (v == 'bind_path') {
                          final path =
                              await FilePicker.platform.getDirectoryPath(
                            dialogTitle: '选择标签「${t.name}」的本地存放目录',
                          );
                          if (path != null) {
                            await TagStore.I.bindPathToTag(t.id, path);
                          }
                        }
                        if (v == 'import_files' && t.localPath != null) {
                          final result = await FilePicker.platform
                              .pickFiles(allowMultiple: true);
                          if (result != null && result.files.isNotEmpty) {
                            int count = 0;
                            final targetDir = Directory(t.localPath!);
                            if (!await targetDir.exists()) {
                              await targetDir.create(recursive: true);
                            }

                            for (final file in result.files) {
                              if (file.path == null) continue;
                              try {
                                final src = File(file.path!);
                                final dst = File(p.join(
                                    t.localPath!, p.basename(file.path!)));
                                await src.copy(dst.path);
                                count++;
                              } catch (e) {
                                debugPrint('Import failed: $e');
                              }
                            }
                            if (context.mounted && count > 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        '已导入 $count 个文件到：${p.basename(t.localPath!)}')),
                              );
                            }
                          }
                        }
                        if (v == 'open_path' &&
                            t.localPath != null &&
                            onOpenTagDirectory != null) {
                          if (!context.mounted) return;
                          await onOpenTagDirectory!(context, t);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'rename', child: Text('重命名')),
                        const PopupMenuItem(
                            value: 'bind_path', child: Text('设置本地存放目录')),
                        if (t.localPath != null) ...[
                          const PopupMenuItem(
                              value: 'import_files', child: Text('导入文件到此目录')),
                          if (onOpenTagDirectory != null)
                            const PopupMenuItem(
                                value: 'open_path', child: Text('浏览物理目录内容')),
                        ],
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

class _FileCard extends StatelessWidget {
  final TagTargetMeta meta;
  final List<Tag> tags;
  final Map<String, WebDavAccount> accountsMap;
  final VoidCallback onTap;
  final VoidCallback onEditTags;
  final VoidCallback? onLocate;

  const _FileCard({
    required this.meta,
    required this.tags,
    required this.accountsMap,
    required this.onTap,
    required this.onEditTags,
    this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(14);

    final showTags = tags.take(2).toList();
    final rest = tags.length - showTags.length;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: radius,
      elevation: 0.4,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _TagCover(meta: meta, accountsMap: accountsMap),
                    if (meta.kind == TagKind.video)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.42),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _KindBadge(kind: meta.kind),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                meta.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                children: [
                  for (final t in showTags) ...[
                    _TagPill(tag: t),
                    const SizedBox(width: 6),
                  ],
                  if (rest > 0) _MorePill(count: rest),
                  const Spacer(),
                  if (onLocate != null)
                    IconButton(
                      tooltip: 'Locate',
                      icon: const Icon(Icons.my_location_outlined, size: 18),
                      onPressed: onLocate,
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    tooltip: '编辑/去除标签',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: onEditTags,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final TagKind kind;
  const _KindBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    IconData icon;
    String text;
    switch (kind) {
      case TagKind.image:
        icon = Icons.image_outlined;
        text = '图片';
        break;
      case TagKind.video:
        icon = Icons.videocam_outlined;
        text = '视频';
        break;
      default:
        icon = Icons.insert_drive_file_outlined;
        text = '文件';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  final Tag tag;
  const _TagPill({required this.tag});

  @override
  Widget build(BuildContext context) {
    final c = Color(tag.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(tag.name, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _MorePill extends StatelessWidget {
  final int count;
  const _MorePill({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.8)),
      ),
      child: Text('+$count', style: const TextStyle(fontSize: 11)),
    );
  }
}

class _TagCover extends StatelessWidget {
  final TagTargetMeta meta;
  final Map<String, WebDavAccount> accountsMap;

  const _TagCover({required this.meta, required this.accountsMap});

  @override
  Widget build(BuildContext context) {
    final embyUrl = _resolveEmbyCoverUrl();
    if (embyUrl.isNotEmpty) {
      return Image.network(
        embyUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _CoverPlaceholder(
          icon: Icons.image_not_supported_outlined,
        ),
      );
    }
    if (meta.kind == TagKind.image) {
      return _imageCover();
    }
    if (meta.kind == TagKind.video) {
      return _videoCover();
    }
    return const _CoverPlaceholder(icon: Icons.insert_drive_file_outlined);
  }

  String _resolveEmbyCoverUrl() {
    final fromMeta = (meta.embyCoverUrl ?? '').trim();
    if (fromMeta.isNotEmpty) return fromMeta;
    final key = meta.key.trim();
    if (key.isEmpty) return '';
    if (!(meta.isEmby || key.toLowerCase().startsWith('emby://'))) return '';
    return '';
  }

  Widget _imageCover() {
    if (meta.isWebDav) {
      final acc =
          meta.wdAccountId != null ? accountsMap[meta.wdAccountId!] : null;
      final href = meta.wdHref;
      if (acc == null || href == null || href.trim().isEmpty) {
        return const _CoverPlaceholder(
            icon: Icons.image_not_supported_outlined);
      }

      return FutureBuilder<File>(
        future:
            WebDavClient(acc).coverFileForHref(href, suggestedName: meta.name),
        builder: (_, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return Image.file(f,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const _CoverPlaceholder(icon: Icons.broken_image_outlined));
          }
          return const _CoverPlaceholder(icon: Icons.image_outlined);
        },
      );
    }

    final lp = meta.localPath;
    if (lp == null || lp.isEmpty) {
      return const _CoverPlaceholder(icon: Icons.image_not_supported_outlined);
    }
    final f = File(lp);
    if (!f.existsSync()) {
      return const _CoverPlaceholder(icon: Icons.image_not_supported_outlined);
    }
    return Image.file(f,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const _CoverPlaceholder(icon: Icons.broken_image_outlined));
  }

  Widget _videoCover() {
    if (meta.isWebDav) {
      final acc =
          meta.wdAccountId != null ? accountsMap[meta.wdAccountId!] : null;
      final href = meta.wdHref;
      if (acc == null || href == null || href.trim().isEmpty) {
        return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
      }
      return FutureBuilder<File>(
        future:
            WebDavClient(acc).cacheFileForHref(href, suggestedName: meta.name),
        builder: (_, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return VideoThumbImage(videoPath: f.path, cacheOnly: true);
          }
          return const _CoverPlaceholder(icon: Icons.videocam_outlined);
        },
      );
    }

    final lp = meta.localPath;
    if (lp == null || lp.isEmpty) {
      return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
    }
    final f = File(lp);
    if (!f.existsSync()) {
      return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
    }
    return VideoThumbImage(videoPath: f.path, cacheOnly: true);
  }
}

class _CoverPlaceholder extends StatelessWidget {
  final IconData icon;
  const _CoverPlaceholder({required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      alignment: Alignment.center,
      child: Icon(icon,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
          size: 28),
    );
  }
}
