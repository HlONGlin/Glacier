part of '../pages.dart';

extension _FolderDetailRendering on _FolderDetailPageState {
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
    return _ProportionalPreviewBox(
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
      ),
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
      return _ProportionalPreviewBox(
        child: Image.network(
          uri.toString(),
          headers: acc.authHeaders,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
          loadingBuilder: (ctx, child, loading) {
            if (loading == null) return child;
            return const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
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
            return _ProportionalPreviewBox(
              child: Image.file(
                snap.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
              ),
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
      return _ProportionalPreviewBox(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
                child: Icon(Icons.video_library_outlined, size: 28)),
          ),
        ),
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
            return _ProportionalPreviewBox(
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _embyFolderThumb(e),
              ),
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
          return _ProportionalPreviewBox(
              child: VideoThumbImage(videoPath: info.localPath!));
        }
        return _ProportionalPreviewBox(
          child: Image.file(
            File(info.localPath!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _FolderCoverPlaceholder(),
          ),
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
      leading = _ProportionalPreviewBox(
        child: Image.file(
          File(e.localPath!),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
        ),
      );
    } else if ((e.localPath ?? '').trim().isNotEmpty &&
        isPageVideoPath(e.localPath!)) {
      leading = _ProportionalPreviewBox(
        child: VideoThumbImage(videoPath: e.localPath!),
      );
    } else {
      leading = const _CoverPlaceholder();
    }

    return GestureDetector(
      onSecondaryTapDown: (d) => _ctxEntryMenu(e, d.globalPosition),
      onLongPress: () => _onEntryLongPress(e),
      child: Card(
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
          onTap: () => _onEntryTap(e,
              visibleEntries: visibleEntries, imgs: imgs, vids: vids),
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
      preview = _ProportionalPreviewBox(
        child: Image.file(File(e.localPath!),
            errorBuilder: (_, __, ___) => const _CoverPlaceholder()),
      );
      badge = Icons.image_outlined;
    } else if (isPageVideoPath(e.localPath!)) {
      preview = _ProportionalPreviewBox(
          child: VideoThumbImage(videoPath: e.localPath!));
      badge = Icons.play_circle_outline;
    } else {
      preview = const _CoverPlaceholder();
      badge = Icons.insert_drive_file_outlined;
    }

    return InkWell(
      onSecondaryTapDown: (d) => _ctxEntryMenu(e, d.globalPosition),
      onLongPress: () => _onEntryLongPress(e),
      onTap: () => _onEntryTap(e,
          visibleEntries: visibleEntries, imgs: imgs, vids: vids),
      borderRadius: radius,
      child: Card(
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
