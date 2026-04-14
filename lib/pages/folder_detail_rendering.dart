part of '../pages.dart';

class _FolderEntryInteractive extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final BorderRadius borderRadius;

  const _FolderEntryInteractive({
    required this.child,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTapDown,
    required this.borderRadius,
  });

  @override
  State<_FolderEntryInteractive> createState() =>
      _FolderEntryInteractiveState();
}

class _FolderEntryInteractiveState extends State<_FolderEntryInteractive> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.988 : 1.0;
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 105),
      curve: Curves.easeOutCubic,
      child: InkWell(
        borderRadius: widget.borderRadius,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        onHighlightChanged: _setPressed,
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.03),
        child: widget.child,
      ),
    );
  }
}

extension _FolderDetailRendering on _FolderDetailPageState {
  Widget _fadeInPreview(Widget child, {Object? keySeed}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 170),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: KeyedSubtree(
        key: ValueKey(keySeed ?? child.runtimeType),
        child: child,
      ),
    );
  }

  Widget _animatedImageFile(
    File file, {
    required Widget errorFallback,
    BoxFit fit = BoxFit.cover,
  }) {
    return Image.file(
      file,
      fit: fit,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, wasSyncLoaded) {
        return AnimatedOpacity(
          opacity: frame == null && !wasSyncLoaded ? 0 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: child,
        );
      },
      errorBuilder: (_, __, ___) => errorFallback,
    );
  }

  Widget _animatedNetworkImage(
    String url, {
    required Widget errorFallback,
    Map<String, String>? headers,
    BoxFit fit = BoxFit.cover,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 160),
      fadeOutDuration: const Duration(milliseconds: 80),
      placeholder: (_, __) => errorFallback,
      errorWidget: (_, __, ___) => errorFallback,
    );
  }

  Widget _buildImmersiveLoadingBody({bool compact = false}) {
    switch (_active.viewMode) {
      case ViewMode.list:
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: compact ? 4 : 7,
          itemBuilder: (_, __) => const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: _FolderListSkeletonItem(),
          ),
        );
      case ViewMode.gallery:
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          itemCount: compact ? 4 : 6,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 420,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.45,
          ),
          itemBuilder: (_, __) => const _FolderGridSkeletonItem(wide: true),
        );
      case ViewMode.grid:
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          itemCount: compact ? 6 : 10,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (_, __) => const _FolderGridSkeletonItem(),
        );
    }
  }

  Widget _buildByMode(List<Entry> l, List<String> imgs, List<String> vids) {
    _syncEntryAnchorKeys(l);
    final usedAnchorKeys = <String>{};

    Widget itemWithAnchor(Entry entry, Widget child) {
      final sourceKey = _imageSourceKeyForEntry(entry).trim();
      if (sourceKey.isEmpty || usedAnchorKeys.contains(sourceKey)) {
        return child;
      }
      usedAnchorKeys.add(sourceKey);
      return _wrapWithEntryAnchor(entry, child);
    }

    switch (_active.viewMode) {
      case ViewMode.list:
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemExtent: 88,
          itemCount: l.length,
          itemBuilder: (_, i) {
            final entry = l[i];
            return itemWithAnchor(entry, _listItem(entry, l, imgs, vids));
          },
        );
      case ViewMode.gallery:
        return GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45),
          itemCount: l.length,
          itemBuilder: (_, i) {
            final entry = l[i];
            return itemWithAnchor(entry, _cardItem(entry, l, imgs, vids));
          },
        );
      case ViewMode.grid:
        return GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95),
          itemCount: l.length,
          itemBuilder: (_, i) {
            final entry = l[i];
            return itemWithAnchor(entry, _cardItem(entry, l, imgs, vids));
          },
        );
    }
  }

  Widget _embyThumb(Entry e) {
    final url = e.embyCoverUrl;
    if (url == null || url.trim().isEmpty) {
      return const _CoverPlaceholder();
    }
    return _fadeInPreview(
      _ProportionalPreviewBox(
        child: _animatedNetworkImage(
          url,
          errorFallback: const _CoverPlaceholder(),
        ),
      ),
      keySeed: url,
    );
  }

  Widget _webDavThumb(Entry e) {
    if (e.isDir) return const _FolderPreviewBox();

    final accId = e.wdAccountId;
    if (accId == null) return const _CoverPlaceholder();

    final acc = _wdAccMap[accId];
    if (acc == null) return const _CoverPlaceholder();

    final client = _wdClientMap[accId] ?? WebDavClient(acc);
    final href = (e.wdHref != null && e.wdHref!.trim().isNotEmpty)
        ? e.wdHref!.trim()
        : (e.wdRelPath != null
            ? client.resolveRel(e.wdRelPath!).toString()
            : '');

    if (_isImgName(e.name)) {
      final uri = client.resolveHref(href);
      return _fadeInPreview(
        _ProportionalPreviewBox(
          child: _animatedNetworkImage(
            uri.toString(),
            headers: acc.authHeaders,
            errorFallback: const _CoverPlaceholder(),
          ),
        ),
        keySeed: uri.toString(),
      );
    }

    if (_isVidName(e.name)) {
      final key = '${e.wdAccountId}|$href';
      final fut = _wdVideoThumbJobs.putIfAbsent(key, () async {
        final cached =
            await client.cacheFileForHref(href, suggestedName: e.name);
        if (await cached.exists() && await cached.length() > 0) {
          return ThumbCache.getOrCreateVideoPreviewFrame(
              cached.path, Duration.zero);
        }
        if (!_wdAutoVideoThumb) return null;
        return getPageWebDavVideoThumbFile(client, href, e.name,
            maxBytes: _wdVideoThumbMaxBytes, expectedSize: e.size);
      });

      return FutureBuilder<File?>(
        future: fut,
        builder: (_, snap) {
          if (snap.data != null) {
            return _fadeInPreview(
              _ProportionalPreviewBox(
                child: _animatedImageFile(
                  snap.data!,
                  fit: BoxFit.cover,
                  errorFallback: const _VideoPlaceholder(),
                ),
              ),
              keySeed: snap.data!.path,
            );
          }
          return const _VideoPlaceholder();
        },
      );
    }

    return const _CoverPlaceholder();
  }

  Widget _embyFolderThumb(Entry e) {
    final url = e.embyCoverUrl;
    if (url != null && url.trim().isNotEmpty) {
      return _fadeInPreview(
        _ProportionalPreviewBox(
          child: _animatedNetworkImage(
            url,
            errorFallback: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                  child: Icon(Icons.video_library_outlined, size: 28)),
            ),
          ),
        ),
        keySeed: url,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Icon(Icons.video_library_outlined, size: 28),
      ),
    );
  }

  Widget _entryDirThumb(Entry e) {
    if (!e.isDir) return const _CoverPlaceholder();

    return FutureBuilder<_CoverInfo?>(
      future: _getFolderCoverInfo(e),
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) {
          if (e.isEmby) return _embyFolderThumb(e);
          return const _FolderCoverPlaceholder();
        }

        if (info.source == 'emby') {
          final url = (info.embyCoverUrl ?? '').trim();
          if (url.isNotEmpty) {
            return _fadeInPreview(
              _ProportionalPreviewBox(
                child: _animatedNetworkImage(
                  url,
                  errorFallback: _embyFolderThumb(e),
                ),
              ),
              keySeed: url,
            );
          }
          return _embyFolderThumb(e);
        }

        if (info.source == 'webdav') {
          final mockEntry = Entry(
            isDir: false,
            name: p.basename(info.wdRelPath ?? ''),
            size: 0,
            modified: DateTime.now(),
            typeKey: info.isVideo ? 'video' : 'image',
            origin: null,
            wdAccountId: info.wdAccountId,
            wdRelPath: info.wdRelPath,
            wdHref: info.wdHref,
          );
          return _webDavThumb(mockEntry);
        }

        if (info.isVideo) {
          return _fadeInPreview(
            _ProportionalPreviewBox(
              child: VideoThumbImage(videoPath: info.localPath!),
            ),
            keySeed: info.localPath,
          );
        }
        return _fadeInPreview(
          _ProportionalPreviewBox(
            child: _animatedImageFile(
              File(info.localPath!),
              fit: BoxFit.cover,
              errorFallback: const _FolderCoverPlaceholder(),
            ),
          ),
          keySeed: info.localPath,
        );
      },
    );
  }

  bool _isImageEntry(Entry e) {
    if (e.isDir) return false;
    if (e.typeKey == 'emby_image') return true;
    if (e.isEmby) return false;
    if (e.isWebDav) return _isImgName(e.name);
    if (e.localPath != null) return isPageImagePath(e.localPath!);
    return _isImgName(e.name);
  }

  String _entryKindLabel(Entry e) =>
      e.isDir ? '目录' : (_isImageEntry(e) ? '图片' : '视频');

  String _entrySubtitle(Entry e, {required bool includeSize}) {
    final kind = _entryKindLabel(e);
    final sizePart = (!includeSize || e.isDir || e.size <= 0)
        ? kind
        : '$kind · ${_fmtSize(e.size)}';
    final showOrigin = _usingScopeSearch ? (e.origin ?? '').trim() : '';
    if (showOrigin.isEmpty) return sizePart;
    return '$sizePart · $showOrigin';
  }

  Widget _listItem(Entry e, List<Entry> visibleEntries, List<String> imgs,
      List<String> vids) {
    if (e.isLoading) {
      return const Card(
        child: SizedBox(
          height: 72,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (e.typeKey == 'hint') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.origin ?? '',
              maxLines: 3, overflow: TextOverflow.ellipsis),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('请回到收藏夹列表 → 右键/长按收藏夹 → 编辑（管理来源）')));
          },
        ),
      );
    }
    if (e.typeKey == 'emby_login') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.origin ?? 'Emby 需要登录或配置异常',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _openEmbyPageWithUi(context),
        ),
      );
    }
    if (e.typeKey == 'emby_empty') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.bookmark_border),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.origin ?? 'Emby 收藏为空',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _openEmbyPageWithUi(context),
        ),
      );
    }
    if (e.typeKey == 'wd_error') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.cloud_off_outlined),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.origin ?? 'WebDAV 加载失败',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.push(context, WebDavPage.routeNoAnim()),
        ),
      );
    }

    final selected = _isEntrySelected(e);
    final selectable = _isEntrySelectable(e);

    Widget leading;
    if (e.isDir) {
      leading = _entryDirThumb(e);
    } else if (e.isEmby) {
      leading = _embyThumb(e);
    } else if (e.isWebDav) {
      leading = _webDavThumb(e);
    } else if ((e.localPath ?? '').trim().isNotEmpty &&
        isPageImagePath(e.localPath!)) {
      leading = _fadeInPreview(
        _ProportionalPreviewBox(
          child: _animatedImageFile(
            File(e.localPath!),
            fit: BoxFit.cover,
            errorFallback: const _CoverPlaceholder(),
          ),
        ),
        keySeed: e.localPath,
      );
    } else if ((e.localPath ?? '').trim().isNotEmpty &&
        isPageVideoPath(e.localPath!)) {
      leading = _fadeInPreview(
        _ProportionalPreviewBox(
          child: VideoThumbImage(videoPath: e.localPath!),
        ),
        keySeed: e.localPath,
      );
    } else {
      leading = const _CoverPlaceholder();
    }

    return Card(
      color: selected
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.55),
                width: 1.3,
              )
            : BorderSide.none,
      ),
      child: _FolderEntryInteractive(
        borderRadius: BorderRadius.circular(12),
        onSecondaryTapDown: (d) => _ctxEntryMenu(e, d.globalPosition),
        onLongPress: () => _onEntryLongPress(e),
        onTap: () => _onEntryTap(e,
            visibleEntries: visibleEntries, imgs: imgs, vids: vids),
        child: ListTile(
          leading: SizedBox(
            width: 56,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Positioned.fill(child: leading),
                  if (selected)
                    const Positioned(
                      right: 4,
                      top: 4,
                      child: Icon(Icons.check_circle, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _entrySubtitle(e, includeSize: true),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _selectionMode && selectable && !selected
              ? const Icon(Icons.radio_button_unchecked, size: 20)
              : null,
        ),
      ),
    );
  }

  Widget _cardItem(Entry e, List<Entry> visibleEntries, List<String> imgs,
      List<String> vids) {
    final radius = BorderRadius.circular(14);

    if (e.isLoading) {
      return Card(
        elevation: 1,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: radius),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (e.typeKey == 'emby_login' || e.typeKey == 'emby_empty') {
      final isLogin = e.typeKey == 'emby_login';
      return Card(
        elevation: 1,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: radius),
        child: InkWell(
          onTap: () => _openEmbyPageWithUi(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                    isLogin
                        ? Icons.account_circle_outlined
                        : Icons.bookmark_border,
                    size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(e.origin ?? '',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget preview;
    IconData badge;
    final selected = _isEntrySelected(e);
    final selectable = _isEntrySelectable(e);

    if (e.isDir) {
      preview = _entryDirThumb(e);
      badge = e.isWebDav ? Icons.cloud_outlined : Icons.folder_outlined;
    } else if (e.isEmby) {
      preview = _embyThumb(e);
      badge = Icons.video_library_outlined;
    } else if (e.isWebDav) {
      preview = _webDavThumb(e);
      badge = _isImgName(e.name)
          ? Icons.image_outlined
          : (_isVidName(e.name)
              ? Icons.play_circle_outline
              : Icons.insert_drive_file_outlined);
    } else if (isPageImagePath(e.localPath!)) {
      preview = _fadeInPreview(
        _ProportionalPreviewBox(
          child: _animatedImageFile(
            File(e.localPath!),
            errorFallback: const _CoverPlaceholder(),
          ),
        ),
        keySeed: e.localPath,
      );
      badge = Icons.image_outlined;
    } else if (isPageVideoPath(e.localPath!)) {
      preview = _fadeInPreview(
        _ProportionalPreviewBox(
          child: VideoThumbImage(videoPath: e.localPath!),
        ),
        keySeed: e.localPath,
      );
      badge = Icons.play_circle_outline;
    } else {
      preview = const _CoverPlaceholder();
      badge = Icons.insert_drive_file_outlined;
    }

    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: selected
            ? BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.6),
                width: 1.4,
              )
            : BorderSide.none,
      ),
      child: _FolderEntryInteractive(
        onSecondaryTapDown: (d) => _ctxEntryMenu(e, d.globalPosition),
        onLongPress: () => _onEntryLongPress(e),
        onTap: () => _onEntryTap(e,
            visibleEntries: visibleEntries, imgs: imgs, vids: vids),
        borderRadius: radius,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: preview),
                  if (selected)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  if (_selectionMode && selectable && !selected)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.32),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.circle_outlined,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(999)),
                      child: Icon(badge, size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                _entrySubtitle(e, includeSize: false),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// 文件夹封面占位（用于没有找到媒体文件时）
class _FolderCoverPlaceholder extends StatelessWidget {
  const _FolderCoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.10),
            scheme.secondary.withValues(alpha: 0.08),
            scheme.tertiary.withValues(alpha: 0.06),
          ],
        ),
      ),
      child: Center(
        child: Icon(Icons.folder_outlined,
            color: scheme.onSurface.withValues(alpha: 0.55), size: 26),
      ),
    );
  }
}
