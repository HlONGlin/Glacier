part of 'emby_exclusive_ui.dart';

extension _EmbyExclusiveFolderPageUi on _EmbyExclusiveFolderPageState {
  Widget _topTabButton(_FolderTopTab tab) {
    final p = _palette;
    final selected = _topTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _setTopTab(tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.chipSelectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          style: TextStyle(
            color: p.text.withValues(alpha: selected ? 1 : 0.88),
            fontSize: selected ? 14.2 : 14,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
          ),
          child:
              Text(EmbyExclusiveFolderHelpers.topTabLabel(tab, _libraryKind)),
        ),
      ),
    );
  }

  Widget _sortMenuButton() {
    final p = _palette;
    return PopupMenuButton<_FolderSortKind>(
      tooltip: '排序',
      onSelected: _onSortSelected,
      color: p.chipBg,
      itemBuilder: (_) => [
        for (final v in _FolderSortKind.values)
          PopupMenuItem<_FolderSortKind>(
            value: v,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    EmbyExclusiveFolderHelpers.sortLabel(v),
                    style: TextStyle(color: p.text),
                  ),
                ),
                if (_sort == v)
                  Icon(
                    _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                    color: p.text,
                    size: 16,
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: p.chipBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, color: p.text, size: 16),
            const SizedBox(width: 6),
            Text(
              EmbyExclusiveFolderHelpers.sortLabel(_sort),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              color: p.text,
              size: 15,
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerControls(int count) {
    final p = _palette;
    final tabs = _visibleTopTabs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: p.chipBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: _onFolderTopTabSwipe,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tab in tabs) _topTabButton(tab),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _sortMenuButton(),
            const SizedBox(width: 8),
            if (_libraryKind != _LibraryKind.unknown) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.chipBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _libraryKindLabel(),
                  style: TextStyle(
                    color: p.sub,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            const Spacer(),
            Text(
              '共 $count 项',
              style: TextStyle(
                color: p.sub,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _cover(_UiItem item) {
    final p = _palette;
    final url = _effectiveCoverUrl(item);
    final isMovie = _isMovieItem(item) || _isMovieFolder(item);
    final token = widget.account.apiKey.trim();
    final headers =
        token.isEmpty ? null : <String, String>{'X-Emby-Token': token};
    final coverWidth = item.isImage ? 860 : (isMovie ? 620 : 560);
    final icon = _isSeriesFolder(item)
        ? Icons.live_tv_outlined
        : (isMovie
            ? Icons.movie_outlined
            : (item.isDir
                ? Icons.folder_open_rounded
                : (item.isImage
                    ? Icons.image_outlined
                    : Icons.video_file_outlined)));

    Widget emptyPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(child: Icon(icon, color: p.sub)),
      );
    }

    Widget brokenPlaceholder() {
      return ColoredBox(
        color: p.coverPlaceholderBg,
        child: Center(child: Icon(Icons.broken_image_outlined, color: p.sub)),
      );
    }

    Widget buildDirSeed(String seedUrl) {
      return Image.network(
        seedUrl,
        headers: headers,
        fit: BoxFit.cover,
        cacheWidth: coverWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => emptyPlaceholder(),
      );
    }

    if (item.isDir) {
      if (url.isEmpty) return emptyPlaceholder();
      return buildDirSeed(url);
    }

    if (url.isEmpty) {
      return emptyPlaceholder();
    }
    return Image.network(
      url,
      headers: headers,
      fit: BoxFit.cover,
      cacheWidth: coverWidth,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => brokenPlaceholder(),
    );
  }

  String _itemKindLabel(_UiItem item) {
    if (_isSeriesFolder(item)) return '剧集';
    if (_isMovieFolder(item)) return '电影';
    if (item.isDir) return '文件夹';
    if (item.isImage) return '图片';
    if (_isMovieItem(item)) return '电影';
    if (_libraryKind == _LibraryKind.series &&
        _embyTypeIsEpisode(item.item.type)) {
      return '剧集';
    }
    return '视频';
  }

  String _displayTitle(_UiItem item) {
    final raw = item.title.trim();
    if (!_isMovieFolder(item) && !_isMovieItem(item)) return raw;
    final stripped = raw.replaceAll(kMovieMetaTagBracketPattern, '');
    final compact = stripped.replaceAll(kMultiSpacePattern, ' ').trim();
    return compact.isEmpty ? raw : compact;
  }

  Widget _buildTopTabGridTile(
    _UiItem item,
    List<_UiItem> shown, {
    required double coverAspect,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openItem(item, pool: shown),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: coverAspect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _cover(item),
                    _itemBadgeOverlay(item),
                    _progressOverlay(item.item),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              _displayTitle(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _palette.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.16,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _itemKindLabel(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _palette.sub,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopTabSliverContent(List<_UiItem> shown) {
    if (shown.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            '目录为空',
            style: TextStyle(color: _palette.sub),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final coverAspect = _dominantCoverAspectCached(shown);
          final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
          final columns = _adaptiveGridColumns(
            width: width,
            coverAspectRatio: coverAspect,
            isTablet: isTablet,
          );
          final childAspect = _gridChildAspectRatio(
            maxWidth: width,
            columns: columns,
            coverAspectRatio: coverAspect,
          );
          return SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildTopTabGridTile(
                shown[i],
                shown,
                coverAspect: coverAspect,
              ),
              childCount: shown.length,
              addAutomaticKeepAlives: false,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 12,
              childAspectRatio: childAspect,
            ),
          );
        },
      ),
    );
  }
}
