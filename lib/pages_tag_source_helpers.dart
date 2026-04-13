import 'tag_models.dart';
import 'source_refs.dart';

String tagKeyForEntry({
  required bool isWebDav,
  required bool isEmby,
  required String? localPath,
  required String? wdAccountId,
  required String? wdRelPath,
  required String? wdHref,
  required String? embyAccountId,
  required String? embyItemId,
}) {
  if (isEmby) {
    final a = (embyAccountId ?? '').trim();
    final i = (embyItemId ?? '').trim();
    if (a.isNotEmpty && i.isNotEmpty) return buildEmbySource(a, 'item:$i');
    return buildEmbySource('unknown', 'item:');
  }
  if (!isWebDav) return (localPath ?? '').trim();
  final a = (wdAccountId ?? '').trim();
  final r = (wdRelPath ?? '').trim();
  if (a.isNotEmpty && r.isNotEmpty) return buildWebDavSource(a, r);
  return (wdHref ?? '').trim();
}

bool tagMetaIsEmby(TagTargetMeta meta) {
  final key = meta.key.trim();
  return meta.isEmby || isEmbySource(key);
}

bool tagMetaIsWebDav(TagTargetMeta meta) {
  final key = meta.key.trim();
  return meta.isWebDav || isWebDavSource(key);
}

bool tagEmbyTypeIsDir(String t) {
  final raw = t.trim();
  if (raw.isEmpty) return false;
  final l = raw.toLowerCase();
  if (l.contains('folder') ||
      l.contains('album') ||
      l.contains('collection') ||
      l.contains('boxset') ||
      l.contains('season') ||
      l.contains('series') ||
      l.contains('view') ||
      l.contains('playlist')) {
    return true;
  }
  const dirTypes = <String>{
    'Folder',
    'CollectionFolder',
    'Collection',
    'BoxSet',
    'Series',
    'Season',
    'UserView',
    'PhotoAlbum',
    'MusicAlbum',
    'Album',
    'Playlist',
  };
  return dirTypes.contains(raw);
}

bool tagEmbyTypeIsImage(String t) {
  final raw = t.trim();
  if (raw.isEmpty) return false;
  if (tagEmbyTypeIsDir(raw)) return false;
  final l = raw.toLowerCase();
  if (l.contains('photo') || l.contains('image') || l.contains('picture')) {
    return true;
  }
  return raw == 'Photo' || raw == 'Image';
}

class TagEmbyRef {
  final String accountId;
  final String? itemId;
  final String? viewId;

  const TagEmbyRef({required this.accountId, this.itemId, this.viewId});
}

TagEmbyRef? parseTagEmbyRef(TagTargetMeta meta) {
  var accountId = (meta.embyAccountId ?? '').trim();
  String? itemId = (meta.embyItemId ?? '').trim();
  if (itemId.isEmpty) itemId = null;
  String? viewId;

  final key = meta.key.trim();
  if (key.isNotEmpty) {
    try {
      final u = Uri.parse(key);
      if (u.scheme.toLowerCase() == 'emby') {
        if (accountId.isEmpty) accountId = u.host.trim();
        final raw =
            (u.path.startsWith('/') ? u.path.substring(1) : u.path).trim();
        if (raw.startsWith('item:')) {
          final id = raw.substring('item:'.length).trim();
          if (id.isNotEmpty) itemId = id;
        } else if (raw.startsWith('view:')) {
          final id = raw.substring('view:'.length).trim();
          if (id.isNotEmpty) viewId = id;
        }
      }
    } catch (_) {}
  }

  if (accountId.isEmpty) return null;
  return TagEmbyRef(accountId: accountId, itemId: itemId, viewId: viewId);
}

WebDavSourceRef? parseTagWebDavRef(TagTargetMeta meta) {
  final acc = (meta.wdAccountId ?? '').trim();
  final rel = (meta.wdRelPath ?? '').trim();
  if (acc.isNotEmpty) {
    return WebDavSourceRef(accountId: acc, relPath: rel, isDir: meta.isDir);
  }
  final key = meta.key.trim();
  if (key.isNotEmpty) return parseWebDavSourceForPage(key);
  return null;
}

WebDavSourceRef? parseWebDavSourceForPage(String s) {
  final parsed = parseWebDavSource(s);
  if (parsed == null) return null;
  return WebDavSourceRef(
    accountId: parsed.accountId,
    relPath: parsed.relPath,
    isDir: parsed.isDir,
  );
}

String buildWebDavSourceWithDir(String accountId, String relPath,
    {required bool isDir}) {
  final base = buildWebDavSource(accountId, relPath);
  if (isDir) return base.endsWith('/') ? base : '$base/';
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}
