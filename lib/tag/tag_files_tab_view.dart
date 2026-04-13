part of '../tag.dart';

class _FilesTabView extends StatefulWidget {
  final List<Tag> tags;
  final Set<String> selectedTagIds;
  final ValueChanged<Set<String>> onSelectedTagIdsChanged;

  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  final _TagSortMode sort;
  final bool sortAsc;
  final ValueChanged<_TagSortMode> onSortChanged;
  final VoidCallback onToggleSortOrder;
  final _TagFilesViewMode viewMode;
  final ValueChanged<_TagFilesViewMode> onViewModeChanged;

  final List<TagTargetMeta> items;
  final Map<String, Tag> tagsById;
  final Map<String, WebDavAccount> accountsMap;
  final Set<String> Function(String targetKey) tagChipsForTarget;
  final TagItemOpenCallback onTapItem;
  final TagItemLocateCallback? onLocateItem;

  const _FilesTabView({
    required this.tags,
    required this.selectedTagIds,
    required this.onSelectedTagIdsChanged,
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.sort,
    required this.sortAsc,
    required this.onSortChanged,
    required this.onToggleSortOrder,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.items,
    required this.tagsById,
    required this.accountsMap,
    required this.tagChipsForTarget,
    required this.onTapItem,
    this.onLocateItem,
  });

  @override
  State<_FilesTabView> createState() => _FilesTabViewState();
}

class _FilesTabViewState extends State<_FilesTabView> {
  @override
  void initState() {
    super.initState();
    _trySyncCurrentTag();
  }

  @override
  void didUpdateWidget(covariant _FilesTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameTagSelection(widget.selectedTagIds, oldWidget.selectedTagIds)) {
      _trySyncCurrentTag();
    }
  }

  bool _sameTagSelection(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final id in a) {
      if (!b.contains(id)) return false;
    }
    return true;
  }

  void _trySyncCurrentTag() {
    for (final id in widget.selectedTagIds) {
      final tag = widget.tagsById[id];
      if (tag != null && tag.localPath != null) {
        TagStore.I.syncLocalTagDir(tag);
      }
    }
  }

  Future<void> _editTagsForTarget(
      BuildContext context, TagTargetMeta meta) async {
    await TagStore.I.ensureLoaded();
    if (!context.mounted) return;
    final allTags = widget.tags;
    if (allTags.isEmpty) return;

    final result = await TagInteractionHelpers.showEditTargetTagsDialog(
      context,
      meta: meta,
      allTags: allTags,
      initialSelected: TagStore.I.tagsOfTarget(meta.key).toSet(),
    );

    if (result == null) return;

    await TagStore.I.setTagsForTarget(meta, result);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('标签已更新')),
    );
  }

  List<Tag> _tagsForTarget(TagTargetMeta it) {
    final tagIds = widget.tagChipsForTarget(it.key);
    return tagIds.map((id) => widget.tagsById[id]).whereType<Tag>().toList();
  }

  Future<void> _showStoreToTagMenu({
    required BuildContext context,
    required Offset globalPosition,
    required TagTargetMeta item,
    required List<Tag> tagsForItem,
  }) async {
    final selectedTag = await TagInteractionHelpers.showStoreToTagMenu(
      context,
      globalPosition: globalPosition,
      tagsForItem: tagsForItem,
    );

    if (selectedTag == null) return;
    await TagStore.I.copyFileToTagDir(item, selectedTag);
    await TagStore.I.syncLocalTagDir(selectedTag);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('已保存到 ${TagInteractionHelpers.storedPathLabel(selectedTag)}'),
      ),
    );
  }

  Future<void> _openTagFilterPanel() async {
    final picked = await TagInteractionHelpers.showTagFilterBottomSheet(
      context,
      tags: widget.tags,
      initialSelected: widget.selectedTagIds,
    );

    if (picked != null) {
      widget.onSelectedTagIdsChanged(picked);
    }
  }

  Widget _buildGridItem(TagTargetMeta it, List<Tag> tagsForItem) {
    return GestureDetector(
      onSecondaryTapDown: (details) => _showStoreToTagMenu(
        context: context,
        globalPosition: details.globalPosition,
        item: it,
        tagsForItem: tagsForItem,
      ),
      child: _FileCard(
        meta: it,
        tags: tagsForItem,
        accountsMap: widget.accountsMap,
        onTap: () => widget.onTapItem(it),
        onEditTags: () => _editTagsForTarget(context, it),
        onLocate: widget.onLocateItem == null
            ? null
            : () => unawaited(widget.onLocateItem!(it)),
      ),
    );
  }

  Widget _buildListItem(TagTargetMeta it, List<Tag> tagsForItem) {
    final showTags = tagsForItem.take(2).toList(growable: false);
    final rest = tagsForItem.length - showTags.length;

    return GestureDetector(
      onSecondaryTapDown: (details) => _showStoreToTagMenu(
        context: context,
        globalPosition: details.globalPosition,
        item: it,
        tagsForItem: tagsForItem,
      ),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        elevation: 0.3,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onTapItem(it),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 110,
                    height: 66,
                    child: _TagCover(meta: it, accountsMap: widget.accountsMap),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _KindBadge(kind: it.kind),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final t in showTags) _TagPill(tag: t),
                          if (rest > 0) _MorePill(count: rest),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '编辑/去除标签',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _editTagsForTarget(context, it),
                  visualDensity: VisualDensity.compact,
                ),
                if (widget.onLocateItem != null)
                  IconButton(
                    tooltip: 'Locate',
                    icon: const Icon(Icons.my_location_outlined, size: 18),
                    onPressed: () => unawaited(widget.onLocateItem!(it)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _TagFilterHeader(
            query: widget.query,
            onQueryChanged: widget.onQueryChanged,
            searchExpanded: widget.searchExpanded,
            onSearchExpandedChanged: widget.onSearchExpandedChanged,
            sort: widget.sort,
            sortAsc: widget.sortAsc,
            onSortChanged: widget.onSortChanged,
            onToggleSortOrder: widget.onToggleSortOrder,
            selectedTagCount: widget.selectedTagIds.length,
            onOpenTagFilter: _openTagFilterPanel,
            viewMode: widget.viewMode,
            onViewModeChanged: widget.onViewModeChanged,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        if (widget.items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('没有文件')),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
            sliver: widget.viewMode == _TagFilesViewMode.grid
                ? SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.crossAxisExtent;
                      int cols;
                      if (w >= 1400) {
                        cols = 6;
                      } else if (w >= 1100) {
                        cols = 5;
                      } else if (w >= 860) {
                        cols = 4;
                      } else if (w >= 620) {
                        cols = 3;
                      } else if (w >= 430) {
                        cols = 2;
                      } else {
                        cols = 1;
                      }

                      return SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.05,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final it = widget.items[i];
                            final tagsForItem = _tagsForTarget(it);
                            return _buildGridItem(it, tagsForItem);
                          },
                          childCount: widget.items.length,
                        ),
                      );
                    },
                  )
                : SliverList.separated(
                    itemCount: widget.items.length,
                    itemBuilder: (context, i) {
                      final it = widget.items[i];
                      final tagsForItem = _tagsForTarget(it);
                      return _buildListItem(it, tagsForItem);
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                  ),
          ),
      ],
    );
  }
}

class _TagFilterHeader extends StatelessWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  final _TagSortMode sort;
  final bool sortAsc;
  final ValueChanged<_TagSortMode> onSortChanged;
  final VoidCallback onToggleSortOrder;
  final int selectedTagCount;
  final VoidCallback onOpenTagFilter;
  final _TagFilesViewMode viewMode;
  final ValueChanged<_TagFilesViewMode> onViewModeChanged;

  const _TagFilterHeader({
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.sort,
    required this.sortAsc,
    required this.onSortChanged,
    required this.onToggleSortOrder,
    required this.selectedTagCount,
    required this.onOpenTagFilter,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  String _sortLabel(_TagSortMode s) {
    switch (s) {
      case _TagSortMode.kind:
        return '类型';
      case _TagSortMode.name:
        return '名称';
      case _TagSortMode.tagCount:
        return '热度';
    }
  }

  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<_TagSortMode>(
          tooltip: '排序依据',
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _TagSortMode.kind,
              child: Row(children: [
                Icon(Icons.category_outlined, size: 16),
                SizedBox(width: 8),
                Text('按类型 (图片/视频/文件)')
              ]),
            ),
            PopupMenuItem(
              value: _TagSortMode.name,
              child: Row(children: [
                Icon(Icons.sort_by_alpha, size: 16),
                SizedBox(width: 8),
                Text('按名称')
              ]),
            ),
            PopupMenuItem(
              value: _TagSortMode.tagCount,
              child: Row(children: [
                Icon(Icons.local_offer_outlined, size: 16),
                SizedBox(width: 8),
                Text('按标签数量 (热度)')
              ]),
            ),
          ],
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 18),
                const SizedBox(width: 6),
                Text(_sortLabel(sort)),
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggleSortOrder,
          child: Container(
            height: 40,
            width: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            alignment: Alignment.center,
            child: Icon(
              sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 18,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tagFilterButton(BuildContext context) {
    final theme = Theme.of(context);
    final active = selectedTagCount > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpenTagFilter,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? theme.colorScheme.primary : theme.dividerColor),
          color:
              active ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.sell : Icons.sell_outlined, size: 18),
            const SizedBox(width: 6),
            Text(active ? 'Tag($selectedTagCount)' : 'Tag选择'),
          ],
        ),
      ),
    );
  }

  String _viewModeLabel(_TagFilesViewMode m) =>
      m == _TagFilesViewMode.grid ? '卡片' : '列表';

  IconData _viewModeIcon(_TagFilesViewMode m) => m == _TagFilesViewMode.grid
      ? Icons.grid_view_outlined
      : Icons.view_list_outlined;

  Widget _viewModeButton(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<_TagFilesViewMode>(
      tooltip: '视图模式',
      initialValue: viewMode,
      onSelected: onViewModeChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _TagFilesViewMode.grid,
          child: Row(
            children: [
              Icon(Icons.grid_view_outlined, size: 16),
              SizedBox(width: 8),
              Text('卡片视图'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _TagFilesViewMode.list,
          child: Row(
            children: [
              Icon(Icons.view_list_outlined, size: 16),
              SizedBox(width: 8),
              Text('列表视图'),
            ],
          ),
        ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_viewModeIcon(viewMode), size: 18),
            const SizedBox(width: 6),
            Text(_viewModeLabel(viewMode)),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showSearch = searchExpanded || query.trim().isNotEmpty;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0.6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _sortButton(context),
                  const SizedBox(width: 8),
                  _tagFilterButton(context),
                  const SizedBox(width: 8),
                  _viewModeButton(context),
                ],
              ),
            ),
            if (showSearch) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 40,
                child: TextField(
                  onChanged: onQueryChanged,
                  controller: TextEditingController(text: query)
                    ..selection = TextSelection.collapsed(offset: query.length),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索文件名',
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
    );
  }
}
