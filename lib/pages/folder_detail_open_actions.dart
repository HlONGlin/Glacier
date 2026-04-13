part of '../pages.dart';

extension _FolderDetailOpenActions on _FolderDetailPageState {
  Future<void> _maybeLocateAfterImageViewer(String? sourceKey) async {
    final key = (sourceKey ?? '').trim();
    if (key.isEmpty || !mounted) return;
    bool enabled = true;
    try {
      enabled = await AppSettings.getImageExitLocateEnabled();
    } catch (_) {
      enabled = true;
    }
    if (!enabled || !mounted) return;
    final currentVisible = _shown();
    final index = currentVisible
        .indexWhere((entry) => _imageSourceKeyForEntry(entry) == key);
    if (index < 0) return;
    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeLocateAfterImageViewer(key);
      });
      return;
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    final roughOffset =
        _estimateScrollOffsetForIndex(index).clamp(0.0, maxExtent);
    try {
      _scrollController.jumpTo(roughOffset);
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchorCtx = _entryAnchorKeys[key]?.currentContext;
      if (anchorCtx != null) {
        Scrollable.ensureVisible(
          anchorCtx,
          alignment: 0.18,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final ratio = currentVisible.length <= 1
          ? 0.0
          : (index / (currentVisible.length - 1)).clamp(0.0, 1.0);
      final fallback = (max * ratio).clamp(0.0, max);
      _scrollController.animateTo(
        fallback,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openEntry(
    Entry e, {
    required List<Entry> visibleEntries,
    required List<String> imgs,
    required List<String> vids,
  }) async {
    if (e.isDir) {
      if (await _openCrossCollectionDirectoryFromSearch(e)) return;
      await _openFolder(e);
      return;
    }
    if (e.isEmby) {
      await _openEmbyItem(
        e,
        pool: _usingScopeSearch ? <Entry>[e] : visibleEntries,
      );
      return;
    }
    if (e.isWebDav) {
      await _openWebDavFile(e);
      return;
    }
    final path = e.localPath;
    if (path == null) return;
    if (isPageImagePath(path)) {
      if (_usingScopeSearch) {
        if (!mounted) return;
        final source = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(
              imagePaths: <String>[path],
              initialIndex: 0,
              sourceKeys: <String>[_imageSourceKeyForEntry(e)],
            ),
          ),
        );
        await _maybeLocateAfterImageViewer(source);
        return;
      }
      final idx = imgs.indexOf(path);
      if (idx < 0) return;
      await _recordFolderHistoryIfEnabled();
      if (!mounted) return;
      final source = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths: imgs,
            initialIndex: idx,
            sourceKeys: imgs,
          ),
        ),
      );
      await _maybeLocateAfterImageViewer(source);
      return;
    }
    if (isPageVideoPath(path)) {
      if (_usingScopeSearch) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  VideoPlayerPage(videoPaths: <String>[path], initialIndex: 0)),
        );
        return;
      }
      final idx = vids.indexOf(path);
      if (idx < 0) return;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                VideoPlayerPage(videoPaths: vids, initialIndex: idx)),
      );
    }
  }

  Future<void> _onEntryTap(
    Entry e, {
    required List<Entry> visibleEntries,
    required List<String> imgs,
    required List<String> vids,
  }) async {
    if (_selectionMode && _isEntrySelectable(e)) {
      _toggleSelection(e);
      _refreshFolderDetailState();
      return;
    }
    await _openEntry(e, visibleEntries: visibleEntries, imgs: imgs, vids: vids);
  }

  void _onEntryLongPress(Entry e) {
    if (_isEntrySelectable(e)) {
      _selectionMode = true;
      _toggleSelection(e);
      _refreshFolderDetailState();
      return;
    }
    if (_tagEnabled) {
      _openTagForEntry(e);
    }
  }

  Future<void> _recordFolderHistoryIfEnabled() async {
    if (_stack.isEmpty) return;
    final cur = _stack.last;
    if (cur.kind == CtxKind.root) return;

    var title = (cur.title ?? '').trim();
    if (title.isEmpty) {
      if (cur.kind == CtxKind.local) {
        title = p.basename(cur.localDir ?? '').trim();
        if (title.isEmpty) title = (cur.localDir ?? '').trim();
      } else if (cur.kind == CtxKind.webdav) {
        final rel = cur.wdRel.endsWith('/')
            ? cur.wdRel.substring(0, cur.wdRel.length - 1)
            : cur.wdRel;
        title = rel.isEmpty ? 'WebDAV' : p.basename(rel);
      } else if (cur.kind == CtxKind.emby) {
        title = widget.collection.name;
      }
    }
    if (title.isEmpty) title = '目录';

    String? coverPath;
    if (cur.kind == CtxKind.local) {
      for (final it in _raw) {
        if (it.isDir || it.isLoading) continue;
        final lp = it.localPath;
        if (lp == null || lp.trim().isEmpty) continue;
        if (_isImgName(it.name) || _isImgName(lp)) {
          coverPath = lp;
          break;
        }
      }
      if (coverPath == null) {
        for (final it in _raw) {
          if (it.isDir || it.isLoading) continue;
          final lp = it.localPath;
          if (lp == null || lp.trim().isEmpty) continue;
          if (_isVidName(it.name) || _isVidName(lp)) {
            coverPath = lp;
            break;
          }
        }
      }
    }

    late final AppHistoryFolderCtx historyCtx;
    switch (cur.kind) {
      case CtxKind.root:
        return;
      case CtxKind.local:
        final dir = (cur.localDir ?? '').trim();
        if (dir.isEmpty) return;
        historyCtx = AppHistoryFolderCtx.local(dir);
        break;
      case CtxKind.webdav:
        final accId = (cur.wdAccountId ?? '').trim();
        if (accId.isEmpty) return;
        historyCtx =
            AppHistoryFolderCtx.webdav(accountId: accId, rel: cur.wdRel);
        break;
      case CtxKind.emby:
        final accId = (cur.embyAccountId ?? '').trim();
        if (accId.isEmpty) return;
        historyCtx = AppHistoryFolderCtx.emby(
          accountId: accId,
          path: cur.embyPath,
        );
        break;
    }

    await AppHistory.upsertFolderCtx(
      ctx: historyCtx,
      title: title,
      coverPath: coverPath,
    );
  }

  Future<void> _openFolder(Entry e) async {
    if (!e.isDir) return;

    if (_scrollController.hasClients) {
      _scrollOffsets[_stack.length - 1] = _scrollController.offset;
    }

    if (e.isEmby) {
      final pth =
          e.isDir && (e.embyItemId != null && e.embyItemId!.trim().isNotEmpty)
              ? 'view:${e.embyItemId}'
              : 'favorites';
      _stack.add(NavCtx.emby(
          embyAccountId: e.embyAccountId!, embyPath: pth, title: e.name));
      _q = '';
      _searchExpanded = false;
      _clearScopeSearchState();
      _clearSelection();
    } else if (e.isWebDav) {
      var rel = e.wdRelPath ?? '';
      if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      _stack.add(NavCtx.webdav(
          wdAccountId: e.wdAccountId!, wdRel: rel, title: e.name));
      _q = '';
      _searchExpanded = false;
      _clearScopeSearchState();
      _clearSelection();
    } else {
      final path = e.localPath;
      if (path == null) return;
      _stack.add(NavCtx.local(path, title: e.name));
      _q = '';
      _searchExpanded = false;
      _clearScopeSearchState();
      _clearSelection();
    }

    _refreshFolderDetailState();

    _prefillSkeletonForFolder(e);
    await _refresh(showGlobalLoading: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  Future<void> _openWebDavFile(Entry e) async {
    final accs = await loadPageWebDavAccountsMap();
    final a = accs[e.wdAccountId!];
    if (a == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('WebDAV 账号不存在/已删除')));
      return;
    }

    final client = WebDavClient(a);
    final name = e.name;

    try {
      if (isPageImageName(name)) {
        await _recordFolderHistoryIfEnabled();
        final relFile = (e.wdRelPath ?? '').toString();
        final parent = p.dirname(relFile);
        final parentRel = (parent == '.' || parent == '/')
            ? ''
            : (parent.endsWith('/') ? parent : '$parent/');
        final items = await client.list(parentRel);
        final imgs = items
            .where((x) => !x.isDir && isPageImageName(x.name))
            .toList(growable: false);
        final paths = imgs
            .map((x) => buildPageWebDavSource(a.id, x.relPath, isDir: false))
            .toList(growable: false);
        final sourceKeys = imgs
            .map((x) => _webDavImageSourceKey(
                  accountId: a.id,
                  relPath: x.relPath,
                  href: client.resolveRel(x.relPath).toString(),
                ))
            .toList(growable: false);
        final idx = imgs.indexWhere((x) => x.relPath == relFile);
        final fallbackSourceKey = _webDavImageSourceKey(
          accountId: a.id,
          relPath: relFile,
          href: client.resolveRel(relFile).toString(),
        );
        if (!mounted) return;
        final source = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(
              imagePaths: paths.isEmpty
                  ? [buildPageWebDavSource(a.id, relFile, isDir: false)]
                  : paths,
              initialIndex: (idx < 0) ? 0 : idx,
              sourceKeys:
                  sourceKeys.isEmpty ? <String>[fallbackSourceKey] : sourceKeys,
            ),
          ),
        );
        await _maybeLocateAfterImageViewer(source);
        return;
      }

      if (isPageVideoName(name)) {
        final relFile = (e.wdRelPath ?? '').toString();
        final parent = p.dirname(relFile);
        final parentRel = (parent == '.' || parent == '/')
            ? ''
            : (parent.endsWith('/') ? parent : '$parent/');
        final items = await client.list(parentRel);
        final vids = items
            .where((x) => !x.isDir && isPageVideoName(x.name))
            .toList(growable: false);
        final paths = vids
            .map((x) => buildPageWebDavSource(a.id, x.relPath, isDir: false))
            .toList(growable: false);
        final idx = vids.indexWhere((x) => x.relPath == relFile);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPlayerPage(
              videoPaths: paths.isEmpty
                  ? [buildPageWebDavSource(a.id, relFile, isDir: false)]
                  : paths,
              initialIndex: (idx < 0) ? 0 : idx,
            ),
          ),
        );
        return;
      }

      final picked =
          await FilePicker.platform.getDirectoryPath(dialogTitle: '选择保存位置');
      if (picked == null) return;
      final out = File(p.join(picked, name));
      final href = (e.wdHref ?? '').trim().isNotEmpty
          ? e.wdHref!.trim()
          : (e.wdRelPath == null
              ? ''
              : client.resolveRel(e.wdRelPath!).toString());
      if (href.trim().isEmpty) {
        throw Exception('缺少可下载地址');
      }
      await client.downloadToFile(href, out);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已保存到：${out.path}')));
    } catch (err) {
      if (!mounted) return;
      final msg = redactSensitiveText(err.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开/下载失败：$msg')));
    }
  }
}
