part of '../pages.dart';

extension _FolderNavigationHelperMethods on _FolderDetailPageState {
  String _stackBreadcrumb() {
    String labelFor(NavCtx ctx) {
      final t = (ctx.title ?? '').trim();
      if (t.isNotEmpty) return t;
      if (ctx.kind == CtxKind.local) {
        final v = p.basename(ctx.localDir ?? '').trim();
        return v.isEmpty ? '本地目录' : v;
      }
      if (ctx.kind == CtxKind.webdav) {
        final rel = ctx.wdRel.endsWith('/')
            ? ctx.wdRel.substring(0, ctx.wdRel.length - 1)
            : ctx.wdRel;
        return rel.isEmpty ? 'WebDAV' : p.basename(rel);
      }
      if (ctx.kind == CtxKind.emby) {
        return ctx.embyPath == 'favorites' ? 'Emby 收藏' : 'Emby';
      }
      return widget.collection.name;
    }

    final nodes = <String>[widget.collection.name];
    for (final s in _stack.skip(1)) {
      nodes.add(labelFor(s));
    }
    return nodes.join(' / ');
  }

  NavCtx? _navForDirectoryEntry(Entry e) {
    if (!e.isDir) return null;
    if (e.isEmby) {
      final id = (e.embyItemId ?? '').trim();
      final pth = id.isEmpty ? 'favorites' : 'view:$id';
      return NavCtx.emby(
          embyAccountId: e.embyAccountId!, embyPath: pth, title: e.name);
    }
    if (e.isWebDav) {
      var rel = (e.wdRelPath ?? '').trim();
      if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      return NavCtx.webdav(
          wdAccountId: e.wdAccountId!, wdRel: rel, title: e.name);
    }
    final lp = (e.localPath ?? '').trim();
    if (lp.isEmpty) return null;
    return NavCtx.local(lp, title: e.name);
  }

  Future<bool> _openCrossCollectionDirectoryFromSearch(Entry e) async {
    if (!_usingScopeSearch || !e.isDir) return false;
    final searchCollectionId = (e.searchCollectionId ?? '').trim();
    if (searchCollectionId.isEmpty ||
        searchCollectionId == widget.collection.id) {
      return false;
    }
    final target = _collectionById(searchCollectionId);
    final nav = _navForDirectoryEntry(e);
    if (target == null || nav == null) return false;
    if (!mounted) return true;
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              FolderDetailPage(collection: target.copy(), initialNav: nav)),
    );
    return true;
  }
}
