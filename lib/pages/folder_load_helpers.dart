part of '../pages.dart';

extension _FolderLoadHelperMethods on _FolderDetailPageState {
  Future<void> _ensureWebDavAccountsLoaded({bool force = false}) async {
    if (!force && _wdAccLoaded) return;
    if (!WebDavManager.instance.isLoaded || force) {
      await WebDavManager.instance.reload(notify: false);
    }
    _wdAccMap
      ..clear()
      ..addAll(WebDavManager.instance.accountsMap);
    _wdClientMap..clear();
    for (final e in _wdAccMap.entries) {
      _wdClientMap[e.key] = WebDavClient(e.value);
    }
    _wdAccLoaded = true;
  }

  bool _tryMigrateWebDavRef(_WebDavRef ref) {
    final accMap = _wdAccMap;
    if (accMap.containsKey(ref.accountId)) return false;
    if (accMap.length != 1) return false;
    final newId = accMap.keys.first;
    final old =
        _buildWebDavSource(ref.accountId, ref.relPath, isDir: ref.isDir);
    final neu = _buildWebDavSource(newId, ref.relPath, isDir: ref.isDir);
    final i = widget.collection.sources.indexOf(old);
    if (i >= 0) {
      widget.collection.sources[i] = neu;
      return true;
    }
    for (var k = 0; k < widget.collection.sources.length; k++) {
      final s = widget.collection.sources[k];
      final r = _parseWebDavSource(s);
      if (r == null) continue;
      if (r.accountId == ref.accountId &&
          r.relPath == ref.relPath &&
          r.isDir == ref.isDir) {
        widget.collection.sources[k] = neu;
        return true;
      }
    }
    return false;
  }

  bool _tryMigrateEmbyRef(_EmbyRef ref, Map<String, EmbyAccount> embyAccMap) {
    if (embyAccMap.containsKey(ref.accountId)) return false;
    if (embyAccMap.length != 1) return false;
    final newId = embyAccMap.keys.first;
    final neu = buildEmbySource(newId, ref.path);
    for (var k = 0; k < widget.collection.sources.length; k++) {
      final s = widget.collection.sources[k];
      final r = _parseEmbySource(s);
      if (r == null) continue;
      if (r.accountId == ref.accountId && r.path == ref.path) {
        widget.collection.sources[k] = neu;
        return true;
      }
    }
    return false;
  }

  Future<List<_Entry>> _loadVirtual() async {
    final out = <_Entry>[];

    final hasWebDav = widget.collection.sources.any(_isWebDavSource);
    if (hasWebDav) {
      await _ensureWebDavAccountsLoaded(force: true);
    } else {
      _wdAccMap.clear();
      _wdClientMap.clear();
      _wdAccLoaded = true;
    }
    final accMap = _wdAccMap;

    final embyAccList = await EmbyStore.load();
    final embyAccMap = {for (final a in embyAccList) a.id: a};

    for (final src in widget.collection.sources) {
      if (_isEmbySource(src)) {
        final ref = _parseEmbySource(src);
        if (ref == null) continue;

        var a = embyAccMap[ref.accountId];
        if (a == null) {
          final migrated = _tryMigrateEmbyRef(ref, embyAccMap);
          if (migrated) {
            final s2 = widget.collection.sources.firstWhere(
              (s) =>
                  _parseEmbySource(s)?.path == ref.path &&
                  (_parseEmbySource(s)?.accountId ?? '') != ref.accountId,
              orElse: () => '',
            );
            final r2 = s2.isEmpty ? null : _parseEmbySource(s2);
            a = (r2 == null) ? null : embyAccMap[r2.accountId];
          }
        }

        if (a == null) {
          out.add(
            _Entry(
              isDir: false,
              name: 'Emby 账号不存在 / 已删除',
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: 'emby_login',
              origin: embyAccMap.isEmpty
                  ? '当前没有任何 Emby 账号。请到 Emby 设置页先添加/登录。'
                  : (embyAccMap.length == 1
                      ? '已尝试自动迁移 Emby 账号但失败，请到「编辑来源」重新绑定。'
                      : '收藏夹引用的 Emby 账号找不到了，请到「编辑来源」重新绑定到现有账号。'),
              embyAccountId: ref.accountId,
            ),
          );
          continue;
        }

        final origin = 'Emby：${a.name}';
        final client = EmbyClient(a);
        final sourcePath =
            ref.path.trim().isEmpty ? 'favorites' : ref.path.trim();

        if (sourcePath != 'favorites') {
          try {
            final scoped = await _loadEmby(a.id, sourcePath);
            if (scoped.isEmpty) {
              out.add(
                _Entry(
                  isDir: false,
                  name: 'Emby 目录为空',
                  size: 0,
                  modified: DateTime.fromMillisecondsSinceEpoch(0),
                  typeKey: 'emby_empty',
                  origin: origin,
                  embyAccountId: a.id,
                ),
              );
            } else {
              out.addAll(scoped);
            }
            continue;
          } catch (e) {
            out.add(
              _Entry(
                isDir: false,
                name: '去 Emby 登录/检查配置',
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: 'emby_login',
                origin:
                    '$origin\n${e.toString().replaceFirst("Exception: ", "")}',
                embyAccountId: a.id,
              ),
            );
            continue;
          }
        }

        try {
          final views = await client.listViews();
          if (views.isNotEmpty) {
            for (final v in views) {
              out.add(
                _Entry(
                  isDir: true,
                  name: v.name.isEmpty ? '未命名库' : v.name,
                  size: 0,
                  modified: DateTime.fromMillisecondsSinceEpoch(0),
                  typeKey: 'emby_folder',
                  origin: origin,
                  embyAccountId: a.id,
                  embyItemId: v.id,
                  embyCoverUrl: client.bestCoverUrl(v, maxWidth: 420),
                ),
              );
            }
            continue;
          }

          final fav = await client.listFavorites();
          if (fav.isEmpty) {
            out.add(
              _Entry(
                isDir: false,
                name: 'Emby 没有可用媒体库',
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: 'emby_empty',
                origin: origin,
                embyAccountId: a.id,
              ),
            );
            continue;
          }

          for (final it in fav) {
            final cover = client.bestCoverUrl(
              it,
              maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
            );

            final isDir = _embyTypeIsDir(it.type);
            final isImg = _embyTypeIsImage(it.type);

            out.add(
              _Entry(
                isDir: isDir,
                name: it.name.isEmpty ? '未命名' : it.name,
                size: isDir ? 0 : it.size,
                modified: it.dateCreated ??
                    it.dateModified ??
                    DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: isDir
                    ? 'emby_folder'
                    : (isImg ? 'emby_image' : 'emby_video'),
                origin: origin,
                embyAccountId: a.id,
                embyItemId: it.id,
                embyCoverUrl: cover,
              ),
            );
          }
        } catch (e) {
          out.add(
            _Entry(
              isDir: false,
              name: '去 Emby 登录/检查配置',
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: 'emby_login',
              origin:
                  '$origin\n${e.toString().replaceFirst("Exception: ", "")}',
              embyAccountId: a.id,
            ),
          );
        }
        continue;
      }

      if (_isWebDavSource(src)) {
        final ref = _parseWebDavSource(src);
        if (ref == null) continue;

        var a = accMap[ref.accountId];
        if (a == null && hasWebDav) {
          final migrated = _tryMigrateWebDavRef(ref);
          if (migrated) {
            await _ensureWebDavAccountsLoaded(force: true);
            a = _wdAccMap[
                _parseWebDavSource(widget.collection.sources.firstWhere((s) {
                      final r = _parseWebDavSource(s);
                      return r != null &&
                          r.relPath == ref.relPath &&
                          r.isDir == ref.isDir;
                    }, orElse: () => ''))?.accountId ??
                    ''];
          }
        }

        if (a == null) {
          out.add(
            _Entry(
              isDir: false,
              name: 'WebDAV 账号不存在 / 已删除',
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: 'wd_error',
              origin: accMap.isEmpty
                  ? '当前没有任何 WebDAV 账号。请到 WebDAV 设置页先添加账号。'
                  : (accMap.length == 1
                      ? '已尝试自动迁移 WebDAV 账号但失败，请到「编辑来源」重新绑定。'
                      : '收藏夹引用的 WebDAV 账号找不到了，请到「编辑来源」重新绑定到现有账号。'),
              wdAccountId: ref.accountId,
              wdRelPath: ref.relPath,
              wdHref: '',
            ),
          );
          continue;
        }

        final origin = ref.relPath.isEmpty
            ? 'WebDAV：${a.name}'
            : 'WebDAV：${a.name}/${ref.relPath}';
        final client = _wdClientMap[a.id] ?? WebDavClient(a);

        if (!ref.isDir) {
          final name = p.basename(ref.relPath);
          out.add(
            _Entry(
              isDir: false,
              name: name.isEmpty ? '文件' : name,
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: p.extension(name).toLowerCase().isEmpty
                  ? 'file'
                  : p.extension(name).toLowerCase(),
              origin: origin,
              wdAccountId: a.id,
              wdRelPath: ref.relPath,
              wdHref: client.resolveRel(ref.relPath).toString(),
            ),
          );
          continue;
        }

        var baseRel = ref.relPath;
        if (baseRel.isNotEmpty && !baseRel.endsWith('/')) baseRel = '$baseRel/';

        try {
          final children = await client.list(baseRel);
          for (final it in children) {
            out.add(
              _Entry(
                isDir: it.isDir,
                name: it.name,
                size: it.size,
                modified: it.modified,
                typeKey: it.isDir
                    ? 'folder'
                    : (p.extension(it.name).toLowerCase().isEmpty
                        ? 'file'
                        : p.extension(it.name).toLowerCase()),
                origin: origin,
                wdAccountId: a.id,
                wdRelPath: it.relPath,
                wdHref: it.href,
              ),
            );
          }
        } catch (e) {
          out.add(
            _Entry(
              isDir: false,
              name: 'WebDAV 加载失败',
              size: 0,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
              typeKey: 'wd_error',
              origin: e.toString().replaceFirst('Exception: ', ''),
              wdAccountId: a.id,
              wdRelPath: baseRel,
              wdHref: '',
            ),
          );
        }
        continue;
      }

      final d = Directory(src);
      if (!await d.exists()) continue;
      final origin = p.basename(src).isEmpty ? src : p.basename(src);

      try {
        final children = await d.list(followLinks: false).toList();
        for (final e in children) {
          final isDir = e is Directory;
          FileStat st;
          try {
            st = await e.stat();
          } catch (_) {
            continue;
          }
          final ext = p.extension(e.path).toLowerCase();
          out.add(
            _Entry(
              isDir: isDir,
              name: (p.basename(e.path).isEmpty ? e.path : p.basename(e.path)),
              size: isDir ? 0 : st.size,
              modified: st.modified,
              typeKey: isDir ? 'folder' : (ext.isEmpty ? 'file' : ext),
              origin: origin,
              localPath: e.path,
            ),
          );
        }
      } catch (_) {
        continue;
      }
    }

    if (out.isEmpty) {
      out.add(
        _Entry(
          isDir: false,
          name: '暂无内容',
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          typeKey: 'hint',
          origin:
              '该收藏夹还没有可用来源。\n请在收藏夹列表里右键/长按 → 编辑（管理来源）添加 WebDAV / Emby / 本地目录。',
        ),
      );
    }

    return out;
  }

  Future<List<_Entry>> _loadLocalDir(String folder) async {
    final d = Directory(folder);
    if (!await d.exists()) return [];
    List<FileSystemEntity> children;
    try {
      children = await d.list(followLinks: false).toList();
    } catch (_) {
      return [];
    }
    final out = <_Entry>[];
    for (final e in children) {
      final isDir = e is Directory;
      FileStat st;
      try {
        st = await e.stat();
      } catch (_) {
        continue;
      }
      final ext = p.extension(e.path).toLowerCase();
      out.add(
        _Entry(
          isDir: isDir,
          name: (p.basename(e.path).isEmpty ? e.path : p.basename(e.path)),
          size: isDir ? 0 : st.size,
          modified: st.modified,
          typeKey: isDir ? 'folder' : (ext.isEmpty ? 'file' : ext),
          origin: null,
          localPath: e.path,
        ),
      );
    }
    return out;
  }

  Future<List<_Entry>> _loadWebDavDir(
      String accountId, String relFolder) async {
    await _ensureWebDavAccountsLoaded(force: true);

    final a = _wdAccMap[accountId];
    if (a == null) {
      return [
        _Entry(
          isDir: false,
          name: 'WebDAV 账号不存在 / 已删除',
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          typeKey: 'wd_error',
          origin: '请到 WebDAV 设置页检查账号是否还存在，并重新绑定到收藏夹来源。',
          wdAccountId: accountId,
          wdRelPath: relFolder,
          wdHref: '',
        )
      ];
    }

    final client = WebDavClient(a);
    List<WebDavItem> list;
    try {
      list = await client.list(relFolder);
    } catch (e) {
      return [
        _Entry(
          isDir: false,
          name: 'WebDAV 加载失败',
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          typeKey: 'wd_error',
          origin: e.toString().replaceFirst('Exception: ', ''),
          wdAccountId: a.id,
          wdRelPath: relFolder,
          wdHref: '',
        )
      ];
    }

    return [
      for (final it in list)
        _Entry(
          isDir: it.isDir,
          name: it.name,
          size: it.size,
          modified: it.modified,
          typeKey: it.isDir
              ? 'folder'
              : (p.extension(it.name).toLowerCase().isEmpty
                  ? 'file'
                  : p.extension(it.name).toLowerCase()),
          origin: null,
          wdAccountId: a.id,
          wdRelPath: it.relPath,
          wdHref: it.href,
        )
    ];
  }
}
