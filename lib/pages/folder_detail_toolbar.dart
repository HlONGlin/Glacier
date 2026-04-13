part of '../pages.dart';

extension _FolderDetailToolbar on _FolderDetailPageState {
  void _toggleSearchUi(bool hasQuery) {
    final showing = _searchExpanded || hasQuery;
    if (showing) {
      _q = '';
      _searchExpanded = false;
      _clearScopeSearchState();
    } else {
      _searchExpanded = true;
    }
    _refreshFolderDetailState();
  }

  Future<void> _handleFolderMoreAction(String v) async {
    switch (v) {
      case 'search_scope':
        await _showSearchScopePanel();
        break;
      case 'history':
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const HistoryPage()),
        );
        break;
      case 'settings':
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsPage()),
        );
        await _reloadDynamicSettings();
        break;
      case 'refresh':
        await _refresh();
        break;
      case 'add':
        await _addFilesHere();
        break;
      case 'tag_manager':
        if (!mounted) return;
        await showAdaptivePanel<void>(
          context: context,
          barrierLabel: 'tag_manager',
          child: TagManagerPage(
            onOpenItem: (item) => openTagTarget(
              context,
              item,
              openFolder: openTagSourceAsFolder,
            ),
            onLocateItem: (item) => locateTagTarget(
              context,
              item,
              openFolder: openTagSourceAsFolder,
            ),
          ),
        );
        break;
      case 'webdav':
        if (!mounted) return;
        await Navigator.push(context, WebDavPage.routeNoAnim());
        break;
      case 'emby':
        if (!mounted) return;
        await _openEmbyPageWithUi(context);
        break;
    }
  }

  Widget _buildFolderHeaderGlass({required bool hasQuery}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Glass(
        radius: 16,
        blur: 16,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _onBack,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _stackBreadcrumb(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.65),
                        ),
                      ),
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _searchExpanded || hasQuery ? '收起搜索' : '展开搜索',
                  onPressed: () => _toggleSearchUi(hasQuery),
                  icon: Icon(
                    _searchExpanded || hasQuery ? Icons.close : Icons.search,
                  ),
                ),
                TopActionMenu<String>(
                  tooltip: '更多',
                  items: [
                    const TopActionMenuItem(
                        value: 'search_scope',
                        icon: Icons.search_outlined,
                        label: '搜索范围'),
                    const TopActionMenuItem(
                        value: 'history', icon: Icons.history, label: '历史记录'),
                    const TopActionMenuItem(
                        value: 'settings',
                        icon: Icons.settings_outlined,
                        label: '设置'),
                    const TopActionMenuItem(
                        value: 'refresh', icon: Icons.refresh, label: '刷新'),
                    if (_stack.isNotEmpty && _stack.last.kind == CtxKind.local)
                      const TopActionMenuItem(
                          value: 'add', icon: Icons.add, label: '添加文件'),
                    if (_tagEnabled)
                      const TopActionMenuItem(
                          value: 'tag_manager',
                          icon: Icons.sell_outlined,
                          label: '标签管理'),
                    const TopActionMenuItem(
                        value: 'webdav',
                        icon: Icons.cloud_outlined,
                        label: 'WebDAV'),
                    const TopActionMenuItem(
                        value: 'emby',
                        icon: Icons.video_library_outlined,
                        label: 'Emby'),
                  ],
                  onSelected: _handleFolderMoreAction,
                ),
              ],
            ),
            if (_searchExpanded || hasQuery) ...[
              const SizedBox(height: 8),
              TextField(
                onChanged: _onSearchQueryChanged,
                decoration: InputDecoration(
                  hintText: _searchHintText(),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _q.trim().isEmpty
                      ? IconButton(
                          tooltip: '收起',
                          icon: const Icon(Icons.expand_less),
                          onPressed: () {
                            _searchExpanded = false;
                            _refreshFolderDetailState();
                          },
                        )
                      : IconButton(
                          tooltip: '清空',
                          icon: const Icon(Icons.close),
                          onPressed: () => _onSearchQueryChanged(''),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFolderFilterBar() {
    return FilterBar(
      children: [
        if (_tagEnabled)
          ControlChip(
            icon: (_selectedTagId == null || _selectedTagId!.isEmpty)
                ? Icons.sell_outlined
                : Icons.sell,
            label: '标签',
            selected: _selectedTagId != null && _selectedTagId!.isNotEmpty,
            onTap: _showTagFilterPanel,
          ),
        ControlChip(
          icon: pageViewModeIcon(_active.viewMode),
          label: pageViewModeLabel(_active.viewMode),
          selected: true,
          onTap: _pickView,
        ),
        ControlChip(
          icon: pageSortKeyIcon(_active.sortKey),
          label: pageSortKeyLabel(_active.sortKey),
          selected: true,
          onTap: _pickSort,
        ),
        ControlChip(
          icon: _active.asc ? Icons.arrow_upward : Icons.arrow_downward,
          label: _active.asc ? '升序' : '降序',
          selected: true,
          onTap: () => _updateActiveLayerSettings((s) => s.asc = !s.asc),
        ),
      ],
    );
  }

  Widget _buildFolderFilterSummary({
    required bool hasQuery,
    required bool hasScopeInfo,
    required bool hasTagFilter,
    required bool scopedLoading,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Glass(
        radius: 12,
        blur: 12,
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  if (hasQuery) '搜索: ${_q.trim()}',
                  if (hasScopeInfo)
                    '范围: ${_searchScope == FolderSearchScope.singleCollection ? _searchScopeChipLabel().replaceFirst('范围: ', '') : _searchScopeBaseLabel(_searchScope)}',
                  if (hasTagFilter) '标签筛选',
                  if (scopedLoading) '搜索中…',
                ].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () {
                _q = '';
                _searchExpanded = false;
                _clearScopeSearchState();
                _selectedTagId = null;
                _refreshFolderDetailState();
              },
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderSelectionBar(List<Entry> list, int selectedCount) {
    return SelectionBar(
      title: selectedCount > 0 ? '已选择 $selectedCount 项' : '选择模式',
      actions: [
        SelectionBarAction(
          icon: Icons.sell_outlined,
          label: '标记',
          onTap: () => _tagSelectedEntries(list),
        ),
        SelectionBarAction(
          icon: Icons.close,
          label: '取消',
          onTap: () {
            _clearSelection();
            _refreshFolderDetailState();
          },
        ),
      ],
    );
  }
}
