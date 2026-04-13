part of '../pages.dart';

extension _FolderDetailEmby on _FolderDetailPageState {
  bool _embyTypeIsDir(String t) {
    final s = t.trim().toLowerCase();
    if (s.isEmpty) return false;
    return s == 'folder' ||
        s == 'collectionfolder' ||
        s == 'series' ||
        s == 'season' ||
        s == 'boxset' ||
        s == 'musicartist' ||
        s == 'musicalbum' ||
        s == 'playlist' ||
        s == 'genre' ||
        s == 'musicgenre' ||
        s == 'person' ||
        s == 'tag' ||
        s == 'studiO'.toLowerCase() ||
        s == 'photoalbum' ||
        s == 'userview' ||
        s == 'channel' ||
        s == 'livetvchannel' ||
        s == 'program' ||
        s == 'book' ||
        s == 'books' ||
        s == 'gamesystem' ||
        s == 'gamegenre' ||
        s == 'movies' ||
        s == 'tvshows' ||
        s == 'homevideos' ||
        s == 'musicvideos' ||
        s == 'music' ||
        s == 'photos';
  }

  bool _embyTypeIsImage(String t) {
    final s = t.trim().toLowerCase();
    if (s.isEmpty) return false;
    return s == 'photo' || s == 'image' || s == 'photobubble' || s == 'picture';
  }

  Future<Map<String, EmbyAccount>> _loadEmbyAccountsMap() async {
    final list = await EmbyStore.load();
    return {for (final a in list) a.id: a};
  }

  Future<void> _openEmbyItem(Entry e, {List<Entry>? pool}) async {
    final playlistPool = pool ?? _raw;
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[e.embyAccountId!];
    if (a == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Emby 配置不存在/已删除')));
      return;
    }
    final looksDir = e.isDir || e.typeKey == 'emby_folder';
    if (looksDir && e.embyItemId != null && e.embyItemId!.trim().isNotEmpty) {
      final next = FavoriteCollection(
        id: '_tmp_emby_${DateTime.now().millisecondsSinceEpoch}',
        name: e.name,
        sources: [buildEmbySource(a.id, 'view:${e.embyItemId}')],
        layer1: widget.collection.layer1,
        layer2: widget.collection.layer2,
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FolderDetailPage(collection: next)),
      );
      return;
    }

    if (e.typeKey == 'emby_image' && e.embyItemId != null) {
      await _recordFolderHistoryIfEnabled();
      final items = playlistPool
          .where((x) =>
              x.embyAccountId == e.embyAccountId &&
              !x.isDir &&
              x.embyItemId != null &&
              x.typeKey == 'emby_image')
          .toList(growable: false);

      final currentItemId = (e.embyItemId ?? '').trim();
      final currentSourceKey = buildEmbySource(a.id, 'item:$currentItemId');
      final imageSources = <String>[];
      final sourceKeys = <String>[];
      final sourceAspectRatios = <double?>[];
      if (items.isEmpty) {
        if (currentSourceKey.isNotEmpty) {
          imageSources.add(currentSourceKey);
          sourceKeys.add(currentSourceKey);
          sourceAspectRatios.add(e.embyAspectRatio);
        }
      } else {
        for (final item in items) {
          final itemId = (item.embyItemId ?? '').trim();
          if (itemId.isEmpty) continue;
          final source = buildEmbySource(a.id, 'item:$itemId').trim();
          if (source.isEmpty) continue;
          imageSources.add(source);
          sourceKeys.add(source);
          sourceAspectRatios.add(item.embyAspectRatio);
        }
      }

      final idx = sourceKeys.indexOf(currentSourceKey);
      final fallbackSingle = currentSourceKey;

      if (!mounted) return;
      final source = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths:
                imageSources.isEmpty ? <String>[fallbackSingle] : imageSources,
            initialIndex: (idx < 0) ? 0 : idx,
            sourceKeys:
                sourceKeys.isEmpty ? <String>[currentSourceKey] : sourceKeys,
            sourceAspectRatios: sourceAspectRatios.isEmpty
                ? <double?>[e.embyAspectRatio]
                : sourceAspectRatios,
          ),
        ),
      );
      await _maybeLocateAfterImageViewer(source);
      return;
    }

    try {
      final items = playlistPool
          .where((x) =>
              x.embyAccountId == e.embyAccountId &&
              !x.isDir &&
              x.embyItemId != null &&
              x.typeKey != 'emby_image' &&
              x.typeKey != 'emby_folder')
          .toList(growable: false);

      final urls = items
          .map((x) =>
              buildEmbySource(a.id, 'item:${x.embyItemId!}', name: x.name))
          .toList(growable: false);
      final idx = items.indexWhere((x) => x.embyItemId == e.embyItemId);

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            videoPaths: urls.isEmpty
                ? [buildEmbySource(a.id, 'item:${e.embyItemId!}', name: e.name)]
                : urls,
            initialIndex: (idx < 0) ? 0 : idx,
          ),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      final msg = redactSensitiveText(err.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：$msg')));
    }
  }

  Future<List<Entry>> _loadEmby(String accountId, String path) async {
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[accountId];
    if (a == null) {
      return [
        Entry(
          isDir: false,
          name: 'Emby 账号不存在 / 已删除',
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          typeKey: 'emby_login',
          origin: '请到 Emby 设置页检查账号是否还存在，并到收藏夹「编辑来源」重新绑定。',
          embyAccountId: accountId,
        )
      ];
    }
    final client = EmbyClient(a);

    final out = <Entry>[];

    void sortEmbyOut() {
      out.sort(
          (a, b) => _controller.compareEntries(a, b, activeSettings: _active));
    }

    try {
      if (path == 'favorites') {
        final views = await client.listViews();
        if (views.isNotEmpty) {
          for (final v in views) {
            out.add(
              Entry(
                isDir: true,
                name: v.name.isEmpty ? '未命名库' : v.name,
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: 'emby_folder',
                origin: 'Emby：${a.name}',
                embyAccountId: a.id,
                embyItemId: v.id,
                embyCoverUrl: client.bestCoverUrl(v, maxWidth: 420),
              ),
            );
          }
          sortEmbyOut();
          return out;
        }

        final items = await client.listFavorites();
        if (items.isEmpty) {
          out.add(
            Entry(
              isDir: false,
              name: 'Emby 没有可用媒体库',
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: 'emby_empty',
              origin: 'Emby：${a.name}',
              embyAccountId: a.id,
            ),
          );
          return out;
        }

        for (final it in items) {
          final cover = client.bestCoverUrl(
            it,
            maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
          );

          final isDir = _embyTypeIsDir(it.type);
          final isImg = _embyTypeIsImage(it.type);

          out.add(
            Entry(
              isDir: isDir,
              name: it.name.isEmpty ? '未命名' : it.name,
              size: isDir ? 0 : it.size,
              modified: it.dateCreated ??
                  it.dateModified ??
                  DateTime.fromMillisecondsSinceEpoch(0),
              typeKey:
                  isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
              origin: null,
              embyAccountId: accountId,
              embyItemId: it.id,
              embyCoverUrl: cover,
              embyAspectRatio: it.primaryImageAspectRatio,
            ),
          );
        }
        sortEmbyOut();
        return out;
      }

      if (path.startsWith('view:')) {
        final parentId = path.substring('view:'.length).trim();
        if (parentId.isEmpty) return out;

        final children = await client.listChildren(parentId: parentId);
        for (final it in children) {
          final isDir = _embyTypeIsDir(it.type);
          final isImg = _embyTypeIsImage(it.type);

          final cover = client.bestCoverUrl(
            it,
            maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
          );

          out.add(
            Entry(
              isDir: isDir,
              name: it.name.isEmpty ? '未命名' : it.name,
              size: isDir ? 0 : it.size,
              modified: it.dateCreated ??
                  it.dateModified ??
                  DateTime.fromMillisecondsSinceEpoch(0),
              typeKey:
                  isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
              origin: null,
              embyAccountId: a.id,
              embyItemId: it.id,
              embyCoverUrl: cover,
              embyAspectRatio: it.primaryImageAspectRatio,
            ),
          );
        }
        sortEmbyOut();
        return out;
      }

      final items = await client.listFavorites();
      for (final it in items) {
        final cover = client.bestCoverUrl(
          it,
          maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
        );

        final isDir = _embyTypeIsDir(it.type);
        final isImg = _embyTypeIsImage(it.type);

        out.add(
          Entry(
            isDir: isDir,
            name: it.name.isEmpty ? '未命名' : it.name,
            size: isDir ? 0 : it.size,
            modified: it.dateCreated ??
                it.dateModified ??
                DateTime.fromMillisecondsSinceEpoch(0),
            typeKey:
                isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
            origin: null,
            embyAccountId: accountId,
            embyItemId: it.id,
            embyCoverUrl: cover,
            embyAspectRatio: it.primaryImageAspectRatio,
          ),
        );
      }
      sortEmbyOut();
      return out;
    } catch (e) {
      out.add(
        Entry(
          isDir: false,
          name: '去 Emby 登录/检查配置',
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          typeKey: 'emby_login',
          origin:
              'Emby：${a.name}\n${e.toString().replaceFirst("Exception: ", "")}',
          embyAccountId: a.id,
        ),
      );
      return out;
    }
  }
}
