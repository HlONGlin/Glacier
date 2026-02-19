import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'image.dart';
import 'video.dart';
import 'webdav.dart';
import 'emby.dart';
import 'thumbnail_inspector.dart';

// 👇👇👇 重点修改这两行 👇👇👇
import 'utils.dart'; // 必须直接引入，去掉 "as utils"
import 'tag.dart';
// 👆👆👆 重点修改这两行 👆👆👆
// ===== app_pages.dart (auto-grouped) =====

// --- from pages.dart ---

/// =========================
/// Tag Module integration helpers
/// =========================

/// 为 Tag 模块生成稳定唯一的 key。
/// - 本地：绝对路径
/// - WebDAV：webdav://<accountId>/<relPath>（优先）
/// - 退化：href（如果 relPath 不可用）
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
    if (a.isNotEmpty && i.isNotEmpty) return 'emby://$a/item:$i';
    return 'emby://unknown';
  }
  if (!isWebDav) return (localPath ?? '').trim();
  final a = (wdAccountId ?? '').trim();
  final r = (wdRelPath ?? '').trim();
  if (a.isNotEmpty && r.isNotEmpty) return 'webdav://$a/$r';
  return (wdHref ?? '').trim();
}

enum ViewMode { list, gallery, grid }

enum SortKey { name, date, size, type }

const _imgExts = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
const _vidExts = <String>{
  '.mp4',
  '.mkv',
  '.mov',
  '.avi',
  '.wmv',
  '.flv',
  '.webm',
  '.m4v',
  '.mpg',
  '.mpeg',
  '.m2v',
  '.ts',
  '.m2ts',
  '.mts',
  '.vob',
  '.3gp',
  '.rm',
  '.rmvb',
  '.iso',
  '.dat',
  '.asf',
  '.f4v',
  '.divx',
  '.dv',
  '.ogv',
  '.hevc',
  '.264',
  '.265'
};
bool _isImg(String path) => _imgExts.contains(p.extension(path).toLowerCase());
bool _isVid(String path) => _vidExts.contains(p.extension(path).toLowerCase());

String _vmLabel(ViewMode v) => const ['列表', '画廊', '网格'][v.index];
String _skLabel(SortKey k) => const ['名称', '日期', '大小', '类型'][k.index];
IconData _vmIcon(ViewMode v) => const [
      Icons.view_list,
      Icons.photo_library_outlined,
      Icons.grid_view
    ][v.index];
IconData _skIcon(SortKey k) => const [
      Icons.sort_by_alpha,
      Icons.calendar_today_outlined,
      Icons.data_usage_outlined,
      Icons.category_outlined
    ][k.index];
bool _isImgName(String name) =>
    _imgExts.contains(p.extension(name).toLowerCase());
bool _isVidName(String name) =>
    _vidExts.contains(p.extension(name).toLowerCase());

bool _tagMetaIsEmby(TagTargetMeta meta) {
  final key = meta.key.trim().toLowerCase();
  return meta.isEmby || key.startsWith('emby://');
}

bool _tagMetaIsWebDav(TagTargetMeta meta) {
  final key = meta.key.trim().toLowerCase();
  return meta.isWebDav || key.startsWith('webdav://');
}

/// Tag 管理页/详情页点击条目时，复用现有页面打开逻辑。
/// - 本地：图片/视频跳到 viewer；其它文件：提示路径（避免引入平台相关打开插件）
/// - WebDAV：图片/视频跳到 viewer；其它文件：下载到用户选择目录
Future<void> openTagTarget(BuildContext context, TagTargetMeta meta) async {
  // Emby
  if (_tagMetaIsEmby(meta)) {
    final ref = _parseTagEmbyRef(meta);
    if (ref == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Tag 的 Emby 信息不完整')));
      return;
    }

    final list = await EmbyStore.load();
    EmbyAccount? acc;
    for (final a in list) {
      if (a.id == ref.accountId) {
        acc = a;
        break;
      }
    }
    if (acc == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Emby 配置不存在/已删除')));
      return;
    }
    final account = acc;
    final client = EmbyClient(account);

    final directViewId = (ref.viewId ?? '').trim();
    if (meta.isDir || directViewId.isNotEmpty) {
      final folderId =
          directViewId.isNotEmpty ? directViewId : (ref.itemId ?? '').trim();
      if (folderId.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('目录信息缺失，无法打开')));
        return;
      }
      await _openTagSourceAsFolder(
        context,
        title: meta.name,
        source: 'emby://${account.id}/view:$folderId',
      );
      return;
    }

    final itemId = (ref.itemId ?? '').trim();
    if (itemId.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Emby ItemId 缺失')));
      return;
    }

    String? parentId;
    EmbyItem? current;
    var siblings = <EmbyItem>[];
    try {
      parentId = await client.getItemParentId(itemId);
      if ((parentId ?? '').trim().isNotEmpty) {
        siblings = await client.listChildren(parentId: parentId!.trim());
        for (final it in siblings) {
          if (it.id == itemId) {
            current = it;
            break;
          }
        }
      }
    } catch (_) {
      // ignore and use metadata fallback
    }

    var itemType = (current?.type ?? '').trim();
    if (itemType.isEmpty) {
      try {
        itemType = (await client.getItemType(itemId) ?? '').trim();
      } catch (_) {}
    }
    final isDirByApi = itemType.isNotEmpty && _tagEmbyTypeIsDir(itemType);
    final isImageByApi = itemType.isNotEmpty && _tagEmbyTypeIsImage(itemType);
    final isImageByMeta = meta.kind == TagKind.image;
    final isVideoByMeta = meta.kind == TagKind.video;
    Future<bool> tryOpenSingleImage() async {
      var single = '';
      if (current != null) {
        single = client.bestImageUrl(current).trim();
      }
      if (single.isEmpty) {
        single = _embyPreferOriginalUrl((meta.embyCoverUrl ?? '').trim());
      }
      if (single.isEmpty) {
        single = client.originalImageUrl(itemId).trim();
      }
      if (single.isEmpty) return false;
      if (!context.mounted) return true;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                ImageViewerPage(imagePaths: [single], initialIndex: 0)),
      );
      return true;
    }

    if (!isDirByApi && !meta.isDir && itemType.isEmpty) {
      try {
        final selfChildren = await client.listChildren(parentId: itemId);
        if (selfChildren.isNotEmpty) {
          await _openTagSourceAsFolder(
            context,
            title: meta.name,
            source: 'emby://${account.id}/view:$itemId',
          );
          return;
        }
      } catch (_) {}
    }

    if (isDirByApi || meta.isDir) {
      await _openTagSourceAsFolder(
        context,
        title: (current != null && current.name.isNotEmpty)
            ? current.name
            : meta.name,
        source: 'emby://${account.id}/view:$itemId',
      );
      return;
    }

    if (isImageByApi || isImageByMeta) {
      final imgs = siblings
          .where((it) =>
              !_tagEmbyTypeIsDir(it.type) && _tagEmbyTypeIsImage(it.type))
          .toList(growable: false);
      if (imgs.isNotEmpty) {
        final urls = imgs
            .map((it) => client.bestImageUrl(it).trim())
            .where((u) => u.isNotEmpty)
            .toList(growable: false);
        if (urls.isNotEmpty) {
          final idx = imgs.indexWhere((it) => it.id == itemId);
          if (!context.mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImageViewerPage(
                imagePaths: urls,
                initialIndex: idx < 0 ? 0 : idx,
              ),
            ),
          );
          return;
        }
      }

      if (await tryOpenSingleImage()) return;
    }

    if (!isVideoByMeta && !isImageByApi && !isImageByMeta && !meta.isDir) {
      try {
        final pb = await client.playbackInfo(itemId);
        if (pb == null) {
          if (await tryOpenSingleImage()) return;
          await _openTagSourceAsFolder(
            context,
            title: meta.name,
            source: 'emby://${account.id}/view:$itemId',
          );
          return;
        }
      } catch (_) {
        if (await tryOpenSingleImage()) return;
        await _openTagSourceAsFolder(
          context,
          title: meta.name,
          source: 'emby://${account.id}/view:$itemId',
        );
        return;
      }
    }

    if (isVideoByMeta || !isImageByApi && !isImageByMeta) {
      final vids = siblings
          .where((it) =>
              !_tagEmbyTypeIsDir(it.type) && !_tagEmbyTypeIsImage(it.type))
          .toList(growable: false);

      final paths = vids.map((it) {
        final nm = it.name.trim().isEmpty ? meta.name : it.name.trim();
        return 'emby://${account.id}/item:${it.id}?name=${Uri.encodeComponent(nm)}';
      }).toList(growable: false);
      final idx = vids.indexWhere((it) => it.id == itemId);

      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            videoPaths: paths.isEmpty
                ? [
                    'emby://${account.id}/item:$itemId?name=${Uri.encodeComponent(meta.name)}'
                  ]
                : paths,
            initialIndex: idx < 0 ? 0 : idx,
          ),
        ),
      );
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('该 Emby 条目暂不支持直接打开')));
    return;
  }

  // Local
  if (!_tagMetaIsWebDav(meta)) {
    final lp = (meta.localPath ?? meta.key).trim();
    if (lp.isEmpty) return;

    var isLocalDir = meta.isDir;
    if (!isLocalDir) {
      try {
        isLocalDir = FileSystemEntity.typeSync(lp, followLinks: false) ==
            FileSystemEntityType.directory;
      } catch (_) {}
    }

    if (isLocalDir) {
      await _openTagSourceAsFolder(context, title: meta.name, source: lp);
      return;
    }

    if (meta.kind == TagKind.image) {
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ImageViewerPage(imagePaths: [lp], initialIndex: 0)),
      );
      return;
    }
    if (meta.kind == TagKind.video) {
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => VideoPlayerPage(videoPaths: [lp], initialIndex: 0)),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('文件路径：$lp')));
    return;
  }

  // WebDAV
  final wd = _parseTagWebDavRef(meta);
  final wdIsDir = wd?.isDir ?? false;
  if (wd != null && (meta.isDir || wdIsDir)) {
    var rel = wd.relPath.trim();
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
    await _openTagSourceAsFolder(
      context,
      title: meta.name,
      source: _buildWebDavSource(wd.accountId, rel, isDir: true),
    );
    return;
  }

  final href = (meta.wdHref ?? meta.key).trim();
  final name = meta.name;
  if (href.isEmpty) return;
  if (meta.kind == TagKind.image) {
    final accId = (meta.wdAccountId ?? '').trim();
    final accs = await WebDavStore.load();
    WebDavAccount? acc;
    for (final a in accs) {
      if (a.id == accId) {
        acc = a;
        break;
      }
    }
    if (acc == null) return;
    final client = WebDavClient(acc);
    final f = await client.ensureCachedForThumb(href, name,
        maxBytes: 12 * 1024 * 1024);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              ImageViewerPage(imagePaths: [f.path], initialIndex: 0)),
    );
    return;
  }
  if (meta.kind == TagKind.video) {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              VideoPlayerPage(videoPaths: [meta.key], initialIndex: 0)),
    );
    return;
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('该文件类型暂不支持直接打开')));
}

Future<void> locateTagTarget(BuildContext context, TagTargetMeta meta) async {
  if (_tagMetaIsEmby(meta)) {
    final ref = _parseTagEmbyRef(meta);
    if (ref == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Tag 的 Emby 信息不完整')));
      return;
    }
    final list = await EmbyStore.load();
    EmbyAccount? acc;
    for (final a in list) {
      if (a.id == ref.accountId) {
        acc = a;
        break;
      }
    }
    if (acc == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Emby 配置不存在/已删除')));
      return;
    }
    final account = acc;
    final client = EmbyClient(account);

    final directViewId = (ref.viewId ?? '').trim();
    if (meta.isDir || directViewId.isNotEmpty) {
      final folderId =
          directViewId.isNotEmpty ? directViewId : (ref.itemId ?? '').trim();
      if (folderId.isEmpty) return;
      await _openTagSourceAsFolder(
        context,
        title: '定位：${meta.name}',
        source: 'emby://${account.id}/view:$folderId',
      );
      return;
    }

    final itemId = (ref.itemId ?? '').trim();
    if (itemId.isEmpty) return;
    var targetFolderId = itemId;
    var itemType = '';
    try {
      itemType = (await client.getItemType(itemId) ?? '').trim();
    } catch (_) {}
    if (itemType.isNotEmpty && _tagEmbyTypeIsDir(itemType)) {
      await _openTagSourceAsFolder(
        context,
        title: '定位：${meta.name}',
        source: 'emby://${account.id}/view:$itemId',
      );
      return;
    }
    try {
      final selfChildren = await client.listChildren(parentId: itemId);
      if (selfChildren.isNotEmpty) {
        await _openTagSourceAsFolder(
          context,
          title: '定位：${meta.name}',
          source: 'emby://${account.id}/view:$itemId',
        );
        return;
      }
    } catch (_) {}
    try {
      final pid = await client.getItemParentId(itemId);
      if ((pid ?? '').trim().isNotEmpty) targetFolderId = pid!.trim();
    } catch (_) {}

    final sourcePath =
        (targetFolderId == itemId) ? 'favorites' : 'view:$targetFolderId';
    await _openTagSourceAsFolder(
      context,
      title: '定位：${meta.name}',
      source: 'emby://${account.id}/$sourcePath',
    );
    return;
  }

  if (_tagMetaIsWebDav(meta)) {
    final wd = _parseTagWebDavRef(meta);
    if (wd == null) return;
    var rel = wd.relPath.trim();
    if (!meta.isDir) {
      final parent = p.dirname(rel);
      rel = (parent == '.' || parent == '/') ? '' : parent;
    }
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';

    await _openTagSourceAsFolder(
      context,
      title: '定位：${meta.name}',
      source: _buildWebDavSource(wd.accountId, rel, isDir: true),
    );
    return;
  }

  final raw = (meta.localPath ?? meta.key).trim();
  if (raw.isEmpty) return;
  var dir = raw;
  try {
    final t = FileSystemEntity.typeSync(raw, followLinks: false);
    if (t != FileSystemEntityType.directory) {
      dir = p.dirname(raw);
    }
  } catch (_) {
    dir = p.dirname(raw);
  }

  await _openTagSourceAsFolder(
    context,
    title: '定位：${meta.name}',
    source: dir,
  );
}

Future<void> _openTagSourceAsFolder(
  BuildContext context, {
  required String title,
  required String source,
}) async {
  final t = title.trim().isEmpty ? 'Tag 目录' : title.trim();
  _NavCtx? nav;
  if (_isEmbySource(source)) {
    final ref = _parseEmbySource(source);
    if (ref != null) {
      nav = _NavCtx.emby(
        embyAccountId: ref.accountId,
        embyPath: ref.path.trim().isEmpty ? 'favorites' : ref.path.trim(),
        title: t,
      );
    }
  } else if (_isWebDavSource(source)) {
    final ref = _parseWebDavSource(source);
    if (ref != null) {
      var rel = ref.relPath;
      if (ref.isDir && rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      nav = _NavCtx.webdav(wdAccountId: ref.accountId, wdRel: rel, title: t);
    }
  } else {
    var dir = source.trim();
    if (dir.isNotEmpty) {
      try {
        final ft = FileSystemEntity.typeSync(dir, followLinks: false);
        if (ft != FileSystemEntityType.directory) {
          dir = p.dirname(dir);
        }
      } catch (_) {
        dir = p.dirname(dir);
      }
      if (dir.trim().isNotEmpty) {
        nav = _NavCtx.local(dir.trim(), title: t);
      }
    }
  }
  final c = FavoriteCollection(
    id: '_tmp_tag_${DateTime.now().millisecondsSinceEpoch}',
    name: t,
    sources: [source],
    layer1: LayerSettings(viewMode: ViewMode.gallery),
    layer2: LayerSettings(viewMode: ViewMode.list),
  );
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => FolderDetailPage(
        collection: c,
        initialNav: nav,
        exitOnInitialContextBack: true,
      ),
    ),
  );
}

bool _tagEmbyTypeIsDir(String t) {
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

bool _tagEmbyTypeIsImage(String t) {
  final raw = t.trim();
  if (raw.isEmpty) return false;
  if (_tagEmbyTypeIsDir(raw)) return false;
  final l = raw.toLowerCase();
  if (l.contains('photo') || l.contains('image') || l.contains('picture'))
    return true;
  return raw == 'Photo' || raw == 'Image';
}

class _TagEmbyRef {
  final String accountId;
  final String? itemId;
  final String? viewId;
  const _TagEmbyRef({required this.accountId, this.itemId, this.viewId});
}

_TagEmbyRef? _parseTagEmbyRef(TagTargetMeta meta) {
  var accountId = (meta.embyAccountId ?? '').trim();
  String? itemId = (meta.embyItemId ?? '').trim();
  if ((itemId ?? '').isEmpty) itemId = null;
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
  return _TagEmbyRef(accountId: accountId, itemId: itemId, viewId: viewId);
}

_WebDavRef? _parseTagWebDavRef(TagTargetMeta meta) {
  final acc = (meta.wdAccountId ?? '').trim();
  final rel = (meta.wdRelPath ?? '').trim();
  if (acc.isNotEmpty) {
    return _WebDavRef(accountId: acc, relPath: rel, isDir: meta.isDir);
  }
  final key = meta.key.trim();
  if (key.isNotEmpty) return _parseWebDavSource(key);
  return null;
}

/// 尽量保留 Emby URL 的鉴权/tag 等参数，只去掉会导致降采样的尺寸参数。
String _embyPreferOriginalUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  try {
    final u = Uri.parse(raw);
    final qp = Map<String, String>.from(u.queryParameters);
    qp.removeWhere((k, _) {
      final lk = k.toLowerCase();
      return lk == 'maxwidth' || lk == 'maxheight' || lk == 'quality';
    });
    final out =
        qp.isEmpty ? u.replace(query: '') : u.replace(queryParameters: qp);
    return out.toString();
  } catch (_) {
    return raw;
  }
}

class _EmbyRef {
  final String accountId;
  final String path;
  const _EmbyRef({required this.accountId, required this.path});
}

_EmbyRef? _parseEmbySource(String s) {
  // emby://<accountId>/favorites
  try {
    final u = Uri.parse(s);
    if (u.scheme.toLowerCase() != 'emby') return null;
    final accId = u.host;
    final segs = u.pathSegments.where((x) => x.isNotEmpty).toList();
    final path = segs.isEmpty ? 'favorites' : segs.join('/');
    if (accId.trim().isEmpty) return null;
    return _EmbyRef(accountId: accId, path: path);
  } catch (_) {
    const prefix = 'emby://';
    if (!s.startsWith(prefix)) return null;
    final raw = s.substring(prefix.length);
    final slash = raw.indexOf('/');
    if (slash == -1) return null;
    final accId = raw.substring(0, slash);
    final path = raw.substring(slash + 1);
    return _EmbyRef(accountId: accId, path: path.isEmpty ? 'favorites' : path);
  }
}

class _WebDavRef {
  final String accountId;
  final String relPath; // '' for root; without leading '/'
  final bool isDir;
  const _WebDavRef(
      {required this.accountId, required this.relPath, required this.isDir});
}

// 放在 const _imgExts = <String>{...} 这行代码的后面即可
extension CharExt on String {
  bool get isDigit =>
      this.length == 1 && this.codeUnitAt(0) >= 48 && this.codeUnitAt(0) <= 57;
}

String _decodeMaybeTwice(String s) {
  var out = s;
  for (int i = 0; i < 2; i++) {
    try {
      final d = Uri.decodeFull(out);
      if (d == out) break;
      out = d;
    } catch (_) {
      break;
    }
  }
  return out;
}

_WebDavRef? _parseWebDavSource(String s) {
  try {
    final safe =
        s.replaceAllMapped(RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    final u = Uri.parse(safe);
    if (u.scheme.toLowerCase() != 'webdav' || u.host.isEmpty) return null;

    var rel = u.path;
    try {
      rel = Uri.decodeFull(rel);
    } catch (_) {
      // 如果 path 里有裸 %，decodeFull 会炸，直接用原始 path
      rel = u.path;
    }

    if (rel.startsWith('/')) rel = rel.substring(1);

    final isDir = s.trim().endsWith('/');
    return _WebDavRef(
        accountId: u.host, relPath: rel, isDir: rel.isEmpty ? true : isDir);
  } catch (_) {
    return null;
  }
}

String _encodePathPreserveSlash(String rp) {
  rp = rp.trim();
  if (rp.startsWith('/')) rp = rp.substring(1);
  if (rp.isEmpty) return '';

  // 逐段 encode，保留 '/'
  final parts = rp.split('/').map(Uri.encodeComponent).toList();
  return parts.join('/');
}

String _buildWebDavSource(String accountId, String relPath,
    {required bool isDir}) {
  final encoded = _encodePathPreserveSlash(relPath);
  final base = 'webdav://$accountId/${encoded.isEmpty ? '' : encoded}';
  if (isDir) return base.endsWith('/') ? base : '$base/';
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}

/// 统一读取 WebDAV 账号映射（避免页面层自己维护全局 static 缓存）
Future<Map<String, WebDavAccount>> _loadWebDavAccountsMapShared() async {
  if (!WebDavManager.instance.isLoaded) {
    await WebDavManager.instance.reload(notify: false);
  }
  return WebDavManager.instance.accountsMap;
}

/// WebDAV 视频封面生成：
/// 1) 先下载前 maxBytes（省流）
/// 2) 用 ffmpeg 抽帧生成缩略图
/// 3) 若抽帧失败（常见：moov 在尾部），再完整下载一次再抽帧
/// WebDAV 视频封面生成
Future<File?> _getWebDavVideoThumbFile(
  WebDavClient client,
  String href,
  String name, {
  required int maxBytes,
  int? expectedSize,
}) async {
  File? thumb;

  // 如果 utils.dart 里没有 WebDavBackgroundGate，请注释掉下面这行，或者换成 WebDavBackgroundHttpPool
  // await WebDavBackgroundGate.waitIfPaused();

  // 1. 尝试使用前缀文件 (Prefix)
  try {
    final prefix =
        await client.ensureCachedForThumb(href, name, maxBytes: maxBytes);
    if (await prefix.exists() && await prefix.length() > 0) {
      // ✅ 修正：使用新方法名，并传入 Duration.zero
      thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
          prefix.path, Duration.zero);
      if (thumb != null) return thumb;
    }
  } catch (_) {}

  // 2. 探测是否需要在尾部下载 (Moov Atom)
  if (expectedSize != null && expectedSize > 0) {
    try {
      final moovInTail =
          await client.probeMoovInTail(href, fileSize: expectedSize);
      if (!moovInTail) return thumb; // 如果 moov 不在尾部且前缀解析失败，可能文件损坏，不继续下载
    } catch (_) {}
  }

  // 3. 尝试下载完整文件 (Full)
  try {
    final full =
        await client.ensureCached(href, name, expectedSize: expectedSize);
    if (await full.exists() && await full.length() > 0) {
      // ✅ 修正：使用新方法名，并传入 Duration.zero
      thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
          full.path, Duration.zero);
    }
  } catch (_) {}

  return thumb;
}

/// =========================
/// Layer settings
/// =========================
class LayerSettings {
  ViewMode viewMode;
  SortKey sortKey;
  bool asc;
  LayerSettings(
      {this.viewMode = ViewMode.gallery,
      this.sortKey = SortKey.name,
      this.asc = true});

  Map<String, dynamic> toJson() =>
      {'v': viewMode.index, 's': sortKey.index, 'a': asc};
  static LayerSettings fromJson(dynamic j) {
    if (j is! Map) return LayerSettings();
    final v = (j['v'] is int) ? (j['v'] as int) : 1;
    final s = (j['s'] is int) ? (j['s'] as int) : 0;
    final a = (j['a'] is bool) ? (j['a'] as bool) : true;
    return LayerSettings(
      viewMode: ViewMode.values[v.clamp(0, ViewMode.values.length - 1)],
      sortKey: SortKey.values[s.clamp(0, SortKey.values.length - 1)],
      asc: a,
    );
  }

  LayerSettings copy() =>
      LayerSettings(viewMode: viewMode, sortKey: sortKey, asc: asc);
}

/// =========================
/// Favorite collection model
/// =========================
class FavoriteCollection {
  final String id;
  String name;
  List<String> sources; // local folders OR webdav://... sources
  String? coverPath; // local image/video path
  LayerSettings layer1;
  LayerSettings layer2;

  FavoriteCollection({
    required this.id,
    required this.name,
    required this.sources,
    required this.layer1,
    required this.layer2,
    this.coverPath,
  });

  FavoriteCollection copy() => FavoriteCollection(
        id: id,
        name: name,
        sources: [...sources],
        coverPath: coverPath,
        layer1: layer1.copy(),
        layer2: layer2.copy(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sources': sources,
        'cover': coverPath,
        'l1': layer1.toJson(),
        'l2': layer2.toJson(),
      };

  static FavoriteCollection fromJson(Map<String, dynamic> j) =>
      FavoriteCollection(
        id: (j['id'] ?? '').toString().isEmpty
            ? DateTime.now().millisecondsSinceEpoch.toString()
            : (j['id'] ?? '').toString(),
        name: ((j['name'] ?? '').toString().trim().isEmpty)
            ? '未命名收藏夹'
            : (j['name'] ?? '').toString(),
        sources: (j['sources'] is List)
            ? (j['sources'] as List).map((e) => e.toString()).toList()
            : <String>[],
        coverPath:
            j['cover'] == null ? null : p.normalize(j['cover'].toString()),
        layer1: LayerSettings.fromJson(j['l1']),
        layer2: LayerSettings.fromJson(j['l2']),
      );
}

// ===============================
// Source 前缀判断（收藏夹/多来源预览用）
//
// 设计原因：收藏夹 sources 目前用字符串存储来源，使用前缀区分类型。
// 这里做成顶层方法，方便 _CollectionCard / _MultiSourcePreview 等多个组件复用。
// ===============================
bool _isWebDavSource(String s) => s.startsWith('webdav://');
bool _isEmbySource(String s) => s.startsWith('emby://');

class _Store {
  static const _kV2 = 'favorite_collections_v2';
  static const _kV1 = 'favorite_folders_v1'; // legacy

  static Future<List<FavoriteCollection>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kV2);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          final out = list
              .whereType<Map>()
              .map(
                  (m) => FavoriteCollection.fromJson(m.cast<String, dynamic>()))
              .toList();

// ✅ 清洗 sources 里所有非法 %
          for (final c in out) {
            for (var i = 0; i < c.sources.length; i++) {
              c.sources[i] = c.sources[i].replaceAllMapped(
                RegExp(r'%(?![0-9A-Fa-f]{2})'),
                (_) => '%25',
              );
            }
          }
          await save(out); // 可选但强烈建议：回写，彻底修复老数据
          return out;
        }
      } catch (_) {}
    }

    // migrate v1 (folders only)
    final legacy = prefs.getStringList(_kV1);
    if (legacy != null && legacy.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <FavoriteCollection>[];
      for (var i = 0; i < legacy.length; i++) {
        final src = p.normalize(legacy[i]);
        out.add(
          FavoriteCollection(
            id: '${now}_$i',
            name: p.basename(src).isEmpty ? '收藏夹${i + 1}' : p.basename(src),
            sources: [src],
            coverPath: null,
            layer1: LayerSettings(
                viewMode: ViewMode.gallery, sortKey: SortKey.name, asc: true),
            layer2: LayerSettings(
                viewMode: ViewMode.list, sortKey: SortKey.name, asc: true),
          ),
        );
      }
      await save(out);
      return out;
    }
    return <FavoriteCollection>[];
  }

  static Future<void> save(List<FavoriteCollection> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kV2, jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}

/// =========================
/// FavoritesPage (Collections)
/// =========================
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});
  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  /// 控制“整页一个 loading”还是“列表/网格自己撑开（预铺占位）”
  /// - true：显示整页 Center(CircularProgressIndicator)
  /// - false：尽量避免整页 loading（更贴近你要的“预铺”体验）
  bool showGlobalLoading = false;

  bool _loading = true;
  Object? _loadError;
  bool _reloading = false;
  List<FavoriteCollection> _list = [];
  String _favoritesQuery = '';
  bool _favoritesSearchExpanded = false;
  bool _favoritesGrid = true;

  // ✅ 新增：防止“自动进入上次收藏夹”反复触发。
  bool _autoEnteredLast = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    if (showGlobalLoading) {
      setState(() => _loading = true);
    }
    try {
      final list = await _Store.load();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
      return;
    } finally {
      _reloading = false;
    }

    // ✅ 必选功能：选择后，软件默认进入“之前选择的收藏夹”。
    // 实现方式：
    // - Settings 中提供开关（默认关闭，避免打扰原有流程）；
    // - 开启后：应用启动进入 FavoritesPage 时，自动跳转到上一次打开的收藏夹。
    // 设计原因：用户更像在“固定使用某一个收藏夹”，减少每次重复点击。
    if (!_autoEnteredLast) {
      _autoEnteredLast = true;
      _tryAutoEnterLastFavorite();
    }
  }

  Future<void> _tryAutoEnterLastFavorite() async {
    try {
      final enabled = await AppSettings.getAutoEnterLastFavorite();
      if (!enabled) return;

      final lastId = await AppSettings.getLastFavoriteId();
      if (lastId == null) return;

      final idx = _list.indexWhere((e) => e.id == lastId);
      if (idx < 0) return;

      if (!mounted) return;
      final c = _list[idx];
      final updated = await Navigator.push<FavoriteCollection>(
        context,
        MaterialPageRoute(
            builder: (_) => FolderDetailPage(collection: c.copy())),
      );
      if (updated == null) return;
      final uIdx = _list.indexWhere((e) => e.id == updated.id);
      if (uIdx >= 0) {
        setState(() => _list[uIdx] = updated);
        await _save();
      }
    } catch (_) {
      // 自动进入失败不影响主流程。
    }
  }

  Future<void> _save() => _Store.save(_list);

  List<FavoriteCollection> _filteredCollections() {
    final query = _favoritesQuery.trim().toLowerCase();
    final out = _list.where((c) {
      if (query.isEmpty) return true;
      return c.name.toLowerCase().contains(query);
    }).toList();

    out.sort((a, b) {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<void> _openCollection(FavoriteCollection c) async {
    await AppSettings.setLastFavoriteId(c.id);
    final updated = await Navigator.push<FavoriteCollection>(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailPage(collection: c.copy())),
    );
    if (updated == null) return;
    final idx = _list.indexWhere((e) => e.id == updated.id);
    if (idx >= 0) {
      setState(() => _list[idx] = updated);
      await _save();
    }
  }

  Future<void> _newCollection() async {
    final name = await _textInput(context,
        title: '新建收藏夹', hint: '输入收藏夹名称', initial: '新收藏夹');
    if (name == null) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _list.add(
        FavoriteCollection(
          id: id,
          name: name.trim().isEmpty ? '新收藏夹' : name.trim(),
          sources: [],
          coverPath: null,
          layer1: LayerSettings(
              viewMode: ViewMode.gallery, sortKey: SortKey.name, asc: true),
          layer2: LayerSettings(
              viewMode: ViewMode.list, sortKey: SortKey.name, asc: true),
        ),
      );
    });
    await _save();
  }

  Future<void> _rename(FavoriteCollection c) async {
    final name =
        await _textInput(context, title: '重命名', hint: '输入新名称', initial: c.name);
    if (name == null) return;
    final v = name.trim();
    if (v.isEmpty) return;
    setState(() => c.name = v);
    await _save();
  }

  Future<void> _delete(FavoriteCollection c) async {
    final ok = await _confirm(context,
        title: '删除收藏夹', message: '确定删除「${c.name}」吗？\n（仅删除配置，不会删除磁盘文件）');
    if (!ok) return;
    setState(() => _list.removeWhere((e) => e.id == c.id));
    await _save();
  }

  Future<void> _changeCover(FavoriteCollection c) async {
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: '选择封面（图片或视频）',
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions:
          [..._imgExts, ..._vidExts].map((e) => e.substring(1)).toList(),
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    setState(() => c.coverPath = p.normalize(path));
    await _save();
  }

  Future<void> _clearCover(FavoriteCollection c) async {
    setState(() => c.coverPath = null);
    await _save();
  }

  Future<void> _edit(FavoriteCollection c) async {
    final updated = await _editSourcesDialog(context, c);
    if (updated == null) return;
    final idx = _list.indexWhere((e) => e.id == c.id);
    if (idx < 0) return;
    setState(() => _list[idx] = updated);
    await _save();
  }

  Future<void> _ctx(FavoriteCollection c, Offset pos) async {
    final a = await _ctxMenu<String>(context, pos, const [
      _CtxItem('edit', '编辑（管理来源）', Icons.edit_outlined),
      _CtxItem('rename', '重命名', Icons.drive_file_rename_outline),
      _CtxItem('cover', '更换封面', Icons.image_outlined),
      _CtxItem('clear', '清除自定义封面', Icons.layers_clear_outlined),
      _CtxItem('delete', '删除', Icons.delete_outline),
    ]);

    switch (a) {
      case 'edit':
        await _edit(c);
        break;
      case 'rename':
        await _rename(c);
        break;
      case 'cover':
        await _changeCover(c);
        break;
      case 'clear':
        await _clearCover(c);
        break;
      case 'delete':
        await _delete(c);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filteredCollections();
    final hasFilterState = _favoritesQuery.trim().isNotEmpty;

    final activeTokens = <String>[
      if (_favoritesQuery.trim().isNotEmpty) '搜索: ${_favoritesQuery.trim()}',
    ];

    final body = _loading
        ? const AppLoadingState()
        : _loadError != null
            ? AppErrorState(
                title: '加载收藏夹失败',
                details: friendlyErrorMessage(_loadError!),
                onRetry: _reload,
              )
            : _list.isEmpty
                ? AppEmptyState(
                    title: '还没有收藏夹',
                    subtitle: '点击新建，创建你的第一个收藏夹',
                    icon: Icons.folder_open_outlined,
                    actionLabel: '新建收藏夹',
                    onAction: _newCollection,
                  )
                : shown.isEmpty
                    ? AppEmptyState(
                        title: '没有匹配结果',
                        subtitle: '尝试修改或清空搜索关键词',
                        icon: Icons.filter_alt_off_outlined,
                        actionLabel: '清空搜索',
                        onAction: () => setState(() {
                          _favoritesQuery = '';
                          _favoritesSearchExpanded = false;
                        }),
                      )
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: AppViewport(
                          child: _favoritesGrid
                              ? GridView.builder(
                                  padding: const EdgeInsets.all(12),
                                  cacheExtent: 3000,
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 360,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 1.35,
                                  ),
                                  itemCount: shown.length,
                                  itemBuilder: (_, i) {
                                    final c = shown[i];
                                    return _CollectionCard(
                                      key: ValueKey(c.id),
                                      c: c,
                                      onOpen: () => _openCollection(c),
                                      onSecondary: (pos) => _ctx(c, pos),
                                    );
                                  },
                                )
                              : ListView.separated(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 8, 12, 16),
                                  itemCount: shown.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (_, i) {
                                    final c = shown[i];
                                    return _CollectionListTile(
                                      c: c,
                                      onOpen: () => _openCollection(c),
                                      onSecondary: (pos) => _ctx(c, pos),
                                    );
                                  },
                                ),
                        ),
                      );

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF7F6FF), Color(0xFFEFF4FF), Color(0xFFF6FBFF)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Glass(
                  radius: 16,
                  blur: 16,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '收藏夹控制台',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: _favoritesSearchExpanded ||
                                    _favoritesQuery.trim().isNotEmpty
                                ? '收起搜索'
                                : '展开搜索',
                            onPressed: () => setState(() {
                              final showing = _favoritesSearchExpanded ||
                                  _favoritesQuery.trim().isNotEmpty;
                              if (showing) {
                                _favoritesQuery = '';
                                _favoritesSearchExpanded = false;
                              } else {
                                _favoritesSearchExpanded = true;
                              }
                            }),
                            icon: Icon(
                              _favoritesSearchExpanded ||
                                      _favoritesQuery.trim().isNotEmpty
                                  ? Icons.close
                                  : Icons.search,
                            ),
                          ),
                          TopActionMenu<String>(
                            tooltip: '更多',
                            items: const [
                              TopActionMenuItem(
                                  value: 'history',
                                  icon: Icons.history,
                                  label: '历史记录'),
                              TopActionMenuItem(
                                  value: 'settings',
                                  icon: Icons.settings_outlined,
                                  label: '设置'),
                              TopActionMenuItem(
                                  value: 'tags',
                                  icon: Icons.sell_outlined,
                                  label: '标签管理'),
                              TopActionMenuItem(
                                  value: 'webdav',
                                  icon: Icons.cloud_outlined,
                                  label: 'WebDAV'),
                              TopActionMenuItem(
                                  value: 'emby',
                                  icon: Icons.video_library_outlined,
                                  label: 'Emby'),
                              TopActionMenuItem(
                                  value: 'refresh',
                                  icon: Icons.refresh,
                                  label: '刷新'),
                            ],
                            onSelected: (v) async {
                              switch (v) {
                                case 'history':
                                  await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => const HistoryPage()));
                                  break;
                                case 'settings':
                                  await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const SettingsPage()));
                                  break;
                                case 'tags':
                                  if (!mounted) return;
                                  await showAdaptivePanel<void>(
                                    context: context,
                                    barrierLabel: 'tag_manager',
                                    child: TagManagerPage(
                                      onOpenItem: (item) =>
                                          openTagTarget(context, item),
                                      onLocateItem: (item) =>
                                          locateTagTarget(context, item),
                                    ),
                                  );
                                  break;
                                case 'webdav':
                                  if (!mounted) return;
                                  await Navigator.push(
                                      context, WebDavPage.routeNoAnim());
                                  break;
                                case 'emby':
                                  if (!mounted) return;
                                  await Navigator.push(
                                      context, EmbyPage.routeNoAnim());
                                  break;
                                case 'refresh':
                                  await _reload();
                                  break;
                              }
                            },
                          ),
                        ],
                      ),
                      if (_favoritesSearchExpanded ||
                          _favoritesQuery.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        TextField(
                          onChanged: (v) => setState(() => _favoritesQuery = v),
                          decoration: InputDecoration(
                            hintText: '搜索收藏夹',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _favoritesQuery.trim().isEmpty
                                ? IconButton(
                                    tooltip: '收起',
                                    icon: const Icon(Icons.expand_less),
                                    onPressed: () => setState(
                                        () => _favoritesSearchExpanded = false),
                                  )
                                : IconButton(
                                    tooltip: '清空',
                                    icon: const Icon(Icons.close),
                                    onPressed: () =>
                                        setState(() => _favoritesQuery = ''),
                                  ),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            isDense: true,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FilterBar(
                children: [
                  ControlChip(
                    icon: _favoritesGrid
                        ? Icons.grid_view_outlined
                        : Icons.view_list_outlined,
                    label: _favoritesGrid ? '卡片' : '列表',
                    selected: true,
                    onTap: () =>
                        setState(() => _favoritesGrid = !_favoritesGrid),
                  ),
                ],
              ),
              if (hasFilterState)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Glass(
                    radius: 12,
                    blur: 12,
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已生效: ${activeTokens.join('  ·  ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _favoritesQuery = '';
                            _favoritesSearchExpanded = false;
                          }),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newCollection,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('新建收藏夹'),
      ),
    );
  }
}

Widget _collectionCover(FavoriteCollection c) {
  final custom = c.coverPath;
  if (custom != null && custom.trim().isNotEmpty && File(custom).existsSync()) {
    return _isImg(custom)
        ? Image.file(File(custom),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _CoverPlaceholder())
        : (_isVid(custom)
            ? VideoThumbImage(videoPath: custom)
            : const _CoverPlaceholder());
  }
  return _MultiSourcePreview(c.sources);
}

String _collectionSubtitle(FavoriteCollection c) {
  if (c.sources.isEmpty) {
    return '未添加来源（长按或右上角菜单可编辑）';
  }
  return '来源总数: ${c.sources.length}';
}

class _CollectionCard extends StatelessWidget {
  final FavoriteCollection c;
  final VoidCallback onOpen;
  final void Function(Offset globalPos) onSecondary;
  const _CollectionCard(
      {super.key,
      required this.c,
      required this.onOpen,
      required this.onSecondary});

  @override
  Widget build(BuildContext context) {
    final subtitle = _collectionSubtitle(c);

    return InkWell(
      onTap: onOpen,
      // Desktop: right-click; Mobile: long-press
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        onSecondary(pos);
      },
      borderRadius: BorderRadius.circular(16),
      child: Glass(
        radius: 18,
        blur: 18,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Expanded(child: _collectionCover(c)),
            ListTile(
              dense: true,
              title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Builder(
                builder: (btnCtx) => IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () {
                    final box = btnCtx.findRenderObject() as RenderBox?;
                    final pos = box == null
                        ? Offset.zero
                        : box.localToGlobal(Offset.zero);
                    onSecondary(pos);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionListTile extends StatelessWidget {
  final FavoriteCollection c;
  final VoidCallback onOpen;
  final void Function(Offset globalPos) onSecondary;

  const _CollectionListTile({
    required this.c,
    required this.onOpen,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = _collectionSubtitle(c);
    return InkWell(
      onTap: onOpen,
      onSecondaryTapDown: (d) => onSecondary(d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        onSecondary(pos);
      },
      borderRadius: BorderRadius.circular(14),
      child: Glass(
        radius: 14,
        blur: 14,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 72,
                height: 72,
                child: _collectionCover(c),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Builder(
              builder: (btnCtx) => IconButton(
                icon: const Icon(Icons.more_horiz),
                onPressed: () {
                  final box = btnCtx.findRenderObject() as RenderBox?;
                  final pos = box == null
                      ? Offset.zero
                      : box.localToGlobal(Offset.zero);
                  onSecondary(pos);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =========================
/// FolderDetailPage
/// depth==0: virtual root (flatten sources first level)
/// depth>=1: real folder (use layer2 settings)
/// =========================
class FolderDetailPage extends StatefulWidget {
  final FavoriteCollection collection;

  /// 可选：用于从“历史记录/外部入口”直接打开到某个目录上下文。
  ///
  /// 设计原因：
  /// - 用户希望“点击图片后，把上级目录记入历史”，因此历史点击需要能还原到对应目录。
  /// - 为了最小改动，这里复用现有 FolderDetailPage 的导航栈，而不是新建一套页面。
  final _NavCtx? initialNav;
  final bool exitOnInitialContextBack;
  const FolderDetailPage(
      {super.key,
      required this.collection,
      this.initialNav,
      this.exitOnInitialContextBack = false});
  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

enum _CtxKind { root, local, webdav, emby }

enum _FolderSearchScope {
  currentDirectory,
  currentCollection,
  allCollections,
  singleCollection,
}

class _NavCtx {
  final _CtxKind kind;

  /// 当前目录在 UI/历史里展示用的标题。
  /// 设计原因：
  /// - Emby 多级目录仅靠 embyPath 无法稳定还原中文目录名；
  /// - 历史目录需要“人类可读”的名称，否则会回退为通用文案（例如：Emby 媒体）。
  final String? title;

  final String? localDir;
  final String? wdAccountId;
  final String
      wdRel; // '' for root of account, always with trailing '/' for folder context
  final String? embyAccountId;
  final String embyPath; // e.g. 'favorites'
  const _NavCtx.root({this.title})
      : kind = _CtxKind.root,
        localDir = null,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';
  const _NavCtx.local(this.localDir, {this.title})
      : kind = _CtxKind.local,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';
  const _NavCtx.webdav(
      {required this.wdAccountId, required this.wdRel, this.title})
      : kind = _CtxKind.webdav,
        localDir = null,
        embyAccountId = null,
        embyPath = '';

  const _NavCtx.emby(
      {required this.embyAccountId, this.embyPath = 'favorites', this.title})
      : kind = _CtxKind.emby,
        localDir = null,
        wdAccountId = null,
        wdRel = '';
}

class _Entry {
  final bool isDir;
  final String name;
  final int size;
  final DateTime modified;
  final String typeKey;
  final String? origin; // only shown in virtual root

  // local
  final String? localPath;

  // webdav
  final String? wdAccountId;
  final String? wdRelPath; // for navigation & unique id
  final String? wdHref; // for download/open

  // emby
  final String? embyAccountId;
  final String? embyItemId;
  final String? embyCoverUrl;

  // Optional metadata for cross-collection search results.
  final String? searchCollectionId;
  final String? searchCollectionName;

  const _Entry({
    required this.isDir,
    required this.name,
    required this.size,
    required this.modified,
    required this.typeKey,
    required this.origin,
    this.localPath,
    this.wdAccountId,
    this.wdRelPath,
    this.wdHref,
    this.embyAccountId,
    this.embyItemId,
    this.embyCoverUrl,
    this.searchCollectionId,
    this.searchCollectionName,
  });

  bool get isWebDav => wdAccountId != null;
  bool get isEmby => embyAccountId != null;

  String get displayPath => isWebDav
      ? 'webdav://$wdAccountId/${wdRelPath ?? ''}'
      : (isEmby
          ? () {
              // ✅ 设计原因：历史记录标题需要可读的中文名称。
              // 如果仅保存 emby://.../item:<id>，播放器侧会无法从 URL 推出名称，
              // 最终历史只能显示“Emby 媒体”。因此这里把名称作为 query 参数携带。
              final id = (embyItemId ?? '').trim();
              if (id.isEmpty) return 'emby://$embyAccountId/item:';
              final nm = name.trim();
              if (nm.isNotEmpty) {
                return 'emby://$embyAccountId/item:$id?name=${Uri.encodeComponent(nm)}';
              }
              return 'emby://$embyAccountId/item:$id';
            }()
          : (localPath ?? '')); // Skeleton/loading placeholder support
  static const String kLoadingTypeKey = '__loading__';
  bool get isLoading => typeKey == kLoadingTypeKey;

  static _Entry loading(int i) => _Entry(
        isDir: false,
        name: 'loading_$i',
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        typeKey: kLoadingTypeKey,
        origin: null,
      );
}

/// =========================
/// SettingsPage (新：应用设置)
/// =========================
/// 设计目标：
/// - 提供更完整的“交互/字幕/历史/收藏夹”设置。
/// - 只做“必要字段”的持久化，避免侵入式重构。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;

  // 字幕
  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;

  // 交互
  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  bool _videoMiniProgressWhenHidden = true;
  bool _videoCatalogEnabled = true;

  // 收藏夹
  bool _autoEnterLastFavorite = false;

  // 历史
  bool _historyEnabled = true;

  // 标签
  bool _tagEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final font = await AppSettings.getSubtitleFontSize();
      final bottom = await AppSettings.getSubtitleBottomOffset();
      final lpEnabled = await AppSettings.getLongPressSpeedEnabled();
      final lpMul = await AppSettings.getLongPressSpeedMultiplier();
      final miniProgress = await AppSettings.getVideoMiniProgressWhenHidden();
      final catalogEnabled = await AppSettings.getVideoCatalogEnabled();
      final autoFav = await AppSettings.getAutoEnterLastFavorite();
      final his = await AppSettings.getHistoryEnabled();
      final tagEnabled = await AppSettings.getTagEnabled();

      if (!mounted) return;
      setState(() {
        _subtitleFontSize = font;
        _subtitleBottomOffset = bottom;
        _longPressSpeedEnabled = lpEnabled;
        _longPressSpeedMultiplier = lpMul;
        _videoMiniProgressWhenHidden = miniProgress;
        _videoCatalogEnabled = catalogEnabled;
        _autoEnterLastFavorite = autoFav;
        _historyEnabled = his;
        _tagEnabled = tagEnabled;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: AppLoadingState());
    }

    return Scaffold(
      appBar: GlassAppBar(title: const Text('设置')),
      body: AppViewport(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          children: [
            const _SettingsSectionTitle('字幕'),
            _SettingsSliderTile(
              title: '字幕大小',
              subtitle: '调整字幕字号（建议 18~30 之间）',
              value: _subtitleFontSize,
              min: 12,
              max: 48,
              divisions: 36,
              valueText: _subtitleFontSize.toStringAsFixed(0),
              onChanged: (v) async {
                setState(() => _subtitleFontSize = v);
                await AppSettings.setSubtitleFontSize(v);
              },
            ),
            _SettingsSliderTile(
              title: '字幕位置（距底部）',
              subtitle: '避免遮挡画面关键区域',
              value: _subtitleBottomOffset,
              min: 0,
              max: 200,
              divisions: 40,
              valueText: _subtitleBottomOffset.toStringAsFixed(0),
              onChanged: (v) async {
                setState(() => _subtitleBottomOffset = v);
                await AppSettings.setSubtitleBottomOffset(v);
              },
            ),
            const SizedBox(height: 10),
            const _SettingsSectionTitle('交互'),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('单击唤出控制栏 / 双击播放暂停'),
              subtitle: Text('移动端采用主流观影播放器交互'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('长按倍数播放'),
              subtitle: const Text('按住屏幕临时加速播放，松开恢复原倍速'),
              value: _longPressSpeedEnabled,
              onChanged: (v) async {
                setState(() => _longPressSpeedEnabled = v);
                await AppSettings.setLongPressSpeedEnabled(v);
              },
            ),
            if (_longPressSpeedEnabled)
              _SettingsSliderTile(
                title: '长按倍速乘数',
                subtitle: '最终倍速 = 当前倍速 × 乘数',
                value: _longPressSpeedMultiplier,
                min: 1.25,
                max: 4.0,
                divisions: 11,
                valueText: _longPressSpeedMultiplier.toStringAsFixed(2),
                onChanged: (v) async {
                  setState(() => _longPressSpeedMultiplier = v);
                  await AppSettings.setLongPressSpeedMultiplier(v);
                },
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('隐藏控制栏时显示底部细进度'),
              subtitle: const Text('关闭后全屏更干净，但无法看到当前进度'),
              value: _videoMiniProgressWhenHidden,
              onChanged: (v) async {
                setState(() => _videoMiniProgressWhenHidden = v);
                await AppSettings.setVideoMiniProgressWhenHidden(v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用播放器目录功能'),
              subtitle: const Text('关闭后隐藏目录入口，并禁用 L/Ctrl+L 与右上热区'),
              value: _videoCatalogEnabled,
              onChanged: (v) async {
                setState(() => _videoCatalogEnabled = v);
                await AppSettings.setVideoCatalogEnabled(v);
              },
            ),
            const SizedBox(height: 10),
            const _SettingsSectionTitle('收藏夹'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启动后自动进入上次收藏夹'),
              subtitle: const Text('开启后，下次打开软件会自动进入你上次打开的收藏夹'),
              value: _autoEnterLastFavorite,
              onChanged: (v) async {
                setState(() => _autoEnterLastFavorite = v);
                await AppSettings.setAutoEnterLastFavorite(v);
                if (!v) {
                  // 关闭时清理 last id，避免用户误以为还会跳转。
                  await AppSettings.setLastFavoriteId(null);
                }
              },
            ),
            const SizedBox(height: 10),
            const _SettingsSectionTitle('历史记录'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记录播放历史'),
              subtitle: const Text('关闭后不会新增历史记录（已有历史不会自动删除）'),
              value: _historyEnabled,
              onChanged: (v) async {
                setState(() => _historyEnabled = v);
                await AppSettings.setHistoryEnabled(v);
              },
            ),
            const SizedBox(height: 10),
            const _SettingsSectionTitle('标签'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用标签功能'),
              subtitle: const Text('关闭后隐藏标签管理入口，并禁用长按打 Tag 与标签筛选'),
              value: _tagEnabled,
              onChanged: (v) async {
                setState(() => _tagEnabled = v);
                await AppSettings.setTagEnabled(v);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('清空历史记录'),
              subtitle: const Text('不可恢复，请谨慎操作'),
              trailing: const Icon(Icons.delete_outline),
              onTap: () async {
                final ok = await _confirm(context,
                    title: '清空历史', message: '确定要清空全部历史记录吗？');
                if (!ok) return;
                await AppHistory.clear();
                if (!mounted) return;
                showAppToast(context, '已清空历史记录');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  final String text;
  const _SettingsSectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

class _SettingsSliderTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueText;
  final ValueChanged<double> onChanged;
  const _SettingsSliderTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            Text(valueText,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: onChanged,
        ),
        const Divider(height: 10),
      ],
    );
  }
}

/// =========================
/// HistoryPage (新：播放历史)
/// =========================
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _loading = true;
  bool _reloading = false;
  Object? _loadError;
  List<Map<String, dynamic>> _list = <Map<String, dynamic>>[];

  // ✅ 性能优化：历史列表里经常需要渲染 Emby 封面。
  // 如果每一行都去 EmbyStore.load()，会导致频繁读 SharedPreferences，
  // 轻则掉帧，重则出现明显的列表滚动卡顿。
  // 因此这里做一次“按页缓存”。
  late final Future<Map<String, EmbyAccount>> _embyAccMapFuture;

  @override
  void initState() {
    super.initState();
    _embyAccMapFuture = _loadEmbyAccountsMap();
    _reload();
  }

  Future<Map<String, EmbyAccount>> _loadEmbyAccountsMap() async {
    final list = await EmbyStore.load();
    return {for (final a in list) a.id: a};
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    try {
      final list = await AppHistory.load();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
    } finally {
      _reloading = false;
    }
  }

  String _fmtTime(int ms) {
    try {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      final two = (int v) => v.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    } catch (_) {
      return '';
    }
  }

  String _fmtPos(int? posMs) {
    if (posMs == null || posMs <= 0) return '';
    final s = (posMs / 1000).floor();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    if (h > 0) return '${h}小时${m}分${ss}秒';
    if (m > 0) return '${m}分${ss}秒';
    return '${ss}秒';
  }

  bool _isWebDavPath(String path) => path.startsWith('webdav://');
  bool _isEmbyPath(String path) => path.startsWith('emby://');

  /// 历史记录封面（尽量统一“封面 + 标题”的观感，类似 B 站历史列表）
  /// - kind=media：本地/WebDAV/Emby 媒体
  /// - kind=fav：收藏夹（历史兼容保留）
  /// - kind=folder：目录（使用 coverPath 兜底，没有就占位）
  Widget _historyCover(String kind, String path, String? coverPath) {
    final radius = BorderRadius.circular(10);

    if (kind == 'fav' || kind == 'folder') {
      final cp = (coverPath ?? '').trim();
      if (cp.isNotEmpty) {
        if (_isImg(cp)) {
          return ClipRRect(
            borderRadius: radius,
            child: Image.file(File(cp),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _FolderPreviewBox()),
          );
        }
        if (_isVid(cp)) {
          return ClipRRect(
              borderRadius: radius, child: VideoThumbImage(videoPath: cp));
        }
      }
      return const _FolderPreviewBox();
    }

    // Emby：直接拼封面 URL（失败则降级占位）
    if (_isEmbyPath(path)) {
      final m = RegExp(r'^emby://([^/]+)/item:([^/?#]+)').firstMatch(path);
      final accId = m?.group(1) ?? '';
      final itemId = m?.group(2) ?? '';

      if (accId.isNotEmpty && itemId.isNotEmpty) {
        return FutureBuilder<Map<String, EmbyAccount>>(
          future: _embyAccMapFuture,
          builder: (c, snap) {
            final m = snap.data;
            final a = m == null ? null : m[accId];
            if (a == null) return const _CoverPlaceholder();
            final client = EmbyClient(a);
            final url = client.coverUrl(itemId,
                type: 'Primary', maxWidth: 320, quality: 85);
            return ClipRRect(
              borderRadius: radius,
              child: Image.network(url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const _CoverPlaceholder()),
            );
          },
        );
      }
      return const _CoverPlaceholder();
    }

    // WebDAV：下载小前缀并抓帧（失败则占位）
    if (_isWebDavPath(path)) {
      final m = RegExp(r'^webdav://([^/]+)/(.+)$').firstMatch(path);
      final accId = m?.group(1) ?? '';
      final rel = m?.group(2) ?? '';

      if (accId.isEmpty || rel.isEmpty) return const _CoverPlaceholder();

      return FutureBuilder<File?>(
        future: () async {
          try {
            final mgr = WebDavManager.instance;
            if (!mgr.isLoaded) {
              // ✅ 设计原因：历史封面仅用于展示，避免依赖外部“必须先进入设置页加载账号”的隐含前置条件
              await mgr.reload(notify: false);
            }
            final acc = mgr.getAccount(accId);
            if (acc == null) return null;

            final client = WebDavClient(acc);

            // 设计原因：历史里只要“看起来像封面”即可，不追求 100% 精准。
            // 因此这里走“前缀抓帧”轻量方案，失败就直接降级占位。
            final parent = p.dirname(rel);
            final name = p.basename(rel);
            final list = await client.list(parent == '.' ? '' : parent);
            final it = list.firstWhere((x) => x.name == name,
                orElse: () => WebDavItem(
                    name: name,
                    href: '',
                    relPath: rel,
                    isDir: false,
                    size: 0,
                    modified: DateTime.now()));
            final href = it.href.trim().isEmpty
                ? client.resolveRel(rel).toString()
                : it.href;

            if (href.trim().isEmpty) return null;

            final prefix = await client.ensureCachedForThumb(href, name,
                maxBytes: 4 * 1024 * 1024);
            if (!await prefix.exists()) return null;
            final thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
                prefix.path, Duration.zero);
            return thumb;
          } catch (_) {
            return null;
          }
        }(),
        builder: (c, snap) {
          final f = snap.data;
          if (f != null) {
            return ClipRRect(
                borderRadius: radius, child: Image.file(f, fit: BoxFit.cover));
          }
          return const _CoverPlaceholder();
        },
      );
    }

    // Local：图片直接显示；视频抓帧；失败占位
    final isImg = _isImg(path);
    if (isImg) {
      return ClipRRect(
          borderRadius: radius,
          child: Image.file(File(path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const _CoverPlaceholder()));
    }
    if (_isVid(path)) {
      return ClipRRect(
          borderRadius: radius, child: VideoThumbImage(videoPath: path));
    }
    return const _CoverPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('历史记录'),
        actions: [
          IconButton(
              onPressed: _reloading ? null : _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新'),
        ],
      ),
      body: _loading
          ? const AppLoadingState()
          : _loadError != null
              ? AppErrorState(
                  title: '加载历史失败',
                  details: friendlyErrorMessage(_loadError!),
                  onRetry: _reload,
                )
              : _list.isEmpty
                  ? const AppEmptyState(
                      title: '暂无历史记录',
                      subtitle: '播放媒体后会自动出现在这里',
                      icon: Icons.history_toggle_off,
                    )
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: AppViewport(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          itemCount: _list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final e = _list[i];
                            final kind =
                                (e['kind'] ?? 'media').toString().trim();
                            final title = (e['title'] ?? '').toString().trim();
                            final path = (e['path'] ?? '').toString().trim();
                            final cover = (e['cover'] ?? '').toString().trim();
                            final favId = (e['favId'] ?? '').toString().trim();
                            final t =
                                int.tryParse((e['t'] ?? '').toString()) ?? 0;
                            final pos =
                                int.tryParse((e['pos'] ?? '').toString());
                            final posText = _fmtPos(pos);

                            return Card(
                              elevation: 0,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  if (path.isEmpty) return;
                                  if (kind == 'fav') {
                                    _openFavoriteFromHistory(favId);
                                    return;
                                  }
                                  if (kind == 'folder') {
                                    _openFolderFromHistory(e);
                                    return;
                                  }

                                  if (!_isWebDavPath(path) &&
                                      !_isEmbyPath(path) &&
                                      _isImg(path)) {
                                    Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => ImageViewerPage(
                                                imagePaths: [path],
                                                initialIndex: 0)));
                                    return;
                                  }

                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => VideoPlayerPage(
                                              videoPaths: [path],
                                              initialIndex: 0)));
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                          width: 120,
                                          height: 68,
                                          child:
                                              _historyCover(kind, path, cover)),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title.isEmpty ? '未命名文件' : title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              [
                                                if (t > 0) _fmtTime(t),
                                                if (kind != 'fav' &&
                                                    posText.isNotEmpty)
                                                  '进度：$posText',
                                                if (kind == 'fav') '收藏夹',
                                                if (kind == 'folder') '目录',
                                              ]
                                                  .where((s) =>
                                                      s.trim().isNotEmpty)
                                                  .join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .hintColor),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '删除',
                                        icon: const Icon(Icons.close),
                                        onPressed: () async {
                                          await AppHistory.removeAt(i);
                                          await _reload();
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
    );
  }

  Future<void> _openFavoriteFromHistory(String favId) async {
    if (favId.trim().isEmpty) return;
    try {
      final list = await _Store.load();
      final c = list.firstWhere(
        (x) => x.id == favId,
        orElse: () => FavoriteCollection(
            id: '',
            name: '',
            sources: const [],
            layer1: LayerSettings(),
            layer2: LayerSettings()),
      );
      if (!mounted) return;
      if (c.id.isEmpty) {
        showAppToast(context, '收藏夹不存在/已删除', error: true);
        return;
      }
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => FolderDetailPage(collection: c.copy())));
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '打开收藏夹失败', error: true);
    }
  }

  Future<void> _openFolderFromHistory(Map<String, dynamic> e) async {
    try {
      final kind = (e['ctxKind'] ?? '').toString().trim();
      if (kind.isEmpty) return;

      // ✅ 目录历史：构造一个“临时收藏夹”，复用 FolderDetailPage 的浏览能力。
      // 设计原因：
      // - 最小改动：不新增新页面；
      // - 目录来源本质上就是 FolderDetailPage 支持的 source（local/webdav/emby）。
      // - 修复：需要把“目录标题”带入导航上下文，否则 Emby 中文目录容易退化为默认文案。
      final title = (e['title'] ?? '').toString().trim();

      late final _NavCtx nav;
      late final String source;

      if (kind == 'local') {
        final dir = (e['localDir'] ?? '').toString().trim();
        if (dir.isEmpty) return;
        nav = _NavCtx.local(dir, title: title.isEmpty ? null : title);
        source = dir;
      } else if (kind == 'webdav') {
        final accId = (e['wdAccountId'] ?? '').toString().trim();
        final rel = (e['wdRel'] ?? '').toString().trim();
        if (accId.isEmpty) return;
        final rel2 = rel.isEmpty ? '' : (rel.endsWith('/') ? rel : '$rel/');
        nav = _NavCtx.webdav(
            wdAccountId: accId,
            wdRel: rel2,
            title: title.isEmpty ? null : title);
        source = 'webdav://$accId/$rel2';
      } else if (kind == 'emby') {
        final accId = (e['embyAccountId'] ?? '').toString().trim();
        final pth = (e['embyPath'] ?? '').toString().trim();
        if (accId.isEmpty) return;
        nav = _NavCtx.emby(
          embyAccountId: accId,
          embyPath: pth.isEmpty ? 'favorites' : pth,
          title: title.isEmpty ? null : title,
        );
        // 这里的 source 只是为了“能创建收藏夹对象”，实际浏览以 initialNav 为准。
        source = 'emby://$accId/${pth.isEmpty ? 'favorites' : pth}';
      } else {
        return;
      }

      final col = FavoriteCollection(
        id: '__history_folder__',
        name: title.isEmpty ? '目录' : title,
        sources: [source],
        layer1: LayerSettings(),
        layer2: LayerSettings(viewMode: ViewMode.list),
      );

      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  FolderDetailPage(collection: col, initialNav: nav)));
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '打开目录失败', error: true);
    }
  }
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  static Future<Map<String, WebDavAccount>> _loadWebDavAccountsMap() =>
      _loadWebDavAccountsMapShared();
  final Map<String, Future<_CoverInfo?>> _dirCoverJobs =
      <String, Future<_CoverInfo?>>{};

  // ✅ Folder cover result cache (memory + SharedPreferences + TTL)
  _FolderCoverCache? _folderCoverCache;

  // 🔥 1. 新增：滚动控制器和位置记录
  final ScrollController _scrollController = ScrollController();
  final Map<int, double> _scrollOffsets = {};

  final List<_NavCtx> _stack = const [_NavCtx.root()].toList();
  bool _loading = true;
  List<_Entry> _raw = [];

  /// Emby 文件大小补全缓存（仅内存）。
  ///
  /// ✅ 背景：部分 Emby 服务端/版本在列表接口不返回 MediaSources（或返回不完整），
  /// 导致 size=0，从而“按大小排序”看起来不生效。
  ///
  /// 方案：当用户选择“按大小排序”且当前是 Emby 目录时，按需对 size=0 的条目做补全。
  /// - 只对前 N 个可见/候选条目补全，避免一次性请求过多。
  /// - 结果写入内存缓存，避免来回切换排序重复请求。
  final Map<String, int> _embySizeCache = <String, int>{};
  bool _embySizeHydrating = false;

  // Folder media count cache (for skeleton prefill). Key: localPath or webdav://<acc>/<rel>/
  final Map<String, int> _folderMediaCountCache = <String, int>{};
  bool _folderMediaCountLoaded = false;

  String _q = '';
  bool _searchExpanded = false;
  _FolderSearchScope _searchScope = _FolderSearchScope.currentCollection;
  String? _singleSearchCollectionId;
  List<FavoriteCollection> _searchCollections = const <FavoriteCollection>[];
  bool _searchCollectionsLoaded = false;
  bool _scopeSearching = false;
  Object? _scopeSearchError;
  List<_Entry> _scopeSearchRaw = const <_Entry>[];
  final Map<String, List<_Entry>> _scopeSearchCache = <String, List<_Entry>>{};
  Timer? _scopeSearchDebounce;
  int _scopeSearchToken = 0;
  static const int _maxScopeSearchResults = 400;
  String? _selectedTagId; // null 表示不过滤

  bool _tagEnabled = true; // 由设置控制，避免用户不需要时被打扰
  bool _selectionMode = false;
  final Set<String> _selectedEntryKeys = <String>{};

  TagKind _tagKindForEntry(_Entry e) {
    if (e.isDir) return TagKind.other;
    if (e.isEmby) {
      if (e.typeKey == 'emby_image') return TagKind.image;
      if (e.typeKey == 'emby_video') return TagKind.video;
    }
    return TagKindX.fromFilename(e.name);
  }

  Future<void> _openTagForEntry(_Entry e) async {
    if (!_tagEnabled) return;

    final key = tagKeyForEntry(
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
    );
    if (key.trim().isEmpty) return;

    final meta = TagTargetMeta(
      key: key,
      name: e.name,
      kind: _tagKindForEntry(e),
      isDir: e.isDir,
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      localPath: e.localPath,
    );

    await TagUI.showTagPicker(context,
        target: meta, title: e.isDir ? '标记目录Tag' : '标记Tag');

    if (!mounted) return;
    setState(() {}); // 让 TagChipsBar / 列表过滤即时刷新
  }

  String _entrySelectionKey(_Entry e) {
    if (!_isEntrySelectable(e)) return '';
    if (e.isEmby || e.isWebDav) {
      return tagKeyForEntry(
        isWebDav: e.isWebDav,
        isEmby: e.isEmby,
        localPath: e.localPath,
        wdAccountId: e.wdAccountId,
        wdRelPath: e.wdRelPath,
        wdHref: e.wdHref,
        embyAccountId: e.embyAccountId,
        embyItemId: e.embyItemId,
      );
    }
    return (e.localPath ?? '').trim();
  }

  bool _isEntrySelectable(_Entry e) {
    if (e.isLoading) return false;
    if (e.typeKey == 'hint' ||
        e.typeKey == 'emby_login' ||
        e.typeKey == 'emby_empty' ||
        e.typeKey == 'wd_error') {
      return false;
    }
    return _entrySelectionKeyRaw(e).isNotEmpty;
  }

  String _entrySelectionKeyRaw(_Entry e) {
    if (e.isEmby || e.isWebDav) {
      return tagKeyForEntry(
        isWebDav: e.isWebDav,
        isEmby: e.isEmby,
        localPath: e.localPath,
        wdAccountId: e.wdAccountId,
        wdRelPath: e.wdRelPath,
        wdHref: e.wdHref,
        embyAccountId: e.embyAccountId,
        embyItemId: e.embyItemId,
      );
    }
    return (e.localPath ?? '').trim();
  }

  bool _isEntrySelected(_Entry e) =>
      _selectedEntryKeys.contains(_entrySelectionKey(e));

  void _clearSelection() {
    _selectionMode = false;
    _selectedEntryKeys.clear();
  }

  void _toggleSelection(_Entry e) {
    final key = _entrySelectionKey(e);
    if (key.isEmpty) return;
    if (_selectedEntryKeys.contains(key)) {
      _selectedEntryKeys.remove(key);
    } else {
      _selectedEntryKeys.add(key);
    }
    if (_selectedEntryKeys.isEmpty) {
      _selectionMode = false;
    }
  }

  List<_Entry> _selectedEntriesFrom(List<_Entry> list) {
    if (_selectedEntryKeys.isEmpty) return const [];
    return list.where(_isEntrySelected).toList();
  }

  TagTargetMeta? _tagMetaForEntry(_Entry e) {
    final key = tagKeyForEntry(
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
    );
    if (key.trim().isEmpty) return null;
    return TagTargetMeta(
      key: key,
      name: e.name,
      kind: _tagKindForEntry(e),
      isDir: e.isDir,
      isWebDav: e.isWebDav,
      isEmby: e.isEmby,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      localPath: e.localPath,
    );
  }

  Future<void> _tagSelectedEntries(List<_Entry> visible) async {
    final targets = _selectedEntriesFrom(visible)
        .map(_tagMetaForEntry)
        .whereType<TagTargetMeta>()
        .toList();
    if (targets.isEmpty) {
      showAppToast(context, '没有可标记的项目', error: true);
      return;
    }
    final picked = await TagUI.showTagPicker(
      context,
      target: targets.first,
      title: '批量标记（共 ${targets.length} 项）',
    );
    if (picked == null) return;
    await TagStore.I.ensureLoaded();
    for (final t in targets) {
      await TagStore.I.setTagsForTarget(t, picked);
    }
    if (!mounted) return;
    setState(() {});
    showAppToast(context, '已更新 ${targets.length} 项标签');
  }

  String _searchScopeBaseLabel(_FolderSearchScope scope) {
    switch (scope) {
      case _FolderSearchScope.currentDirectory:
        return '当前目录';
      case _FolderSearchScope.currentCollection:
        return '当前收藏夹';
      case _FolderSearchScope.allCollections:
        return '全部收藏夹';
      case _FolderSearchScope.singleCollection:
        return '单个收藏夹';
    }
  }

  IconData _searchScopeIcon(_FolderSearchScope scope) {
    switch (scope) {
      case _FolderSearchScope.currentDirectory:
        return Icons.search_outlined;
      case _FolderSearchScope.currentCollection:
        return Icons.folder_special_outlined;
      case _FolderSearchScope.allCollections:
        return Icons.collections_bookmark_outlined;
      case _FolderSearchScope.singleCollection:
        return Icons.bookmark_outline;
    }
  }

  String _searchScopeChipLabel() {
    if (_searchScope == _FolderSearchScope.singleCollection) {
      final c = _collectionById(_singleSearchCollectionId);
      final name = (c?.name ?? '').trim();
      return name.isEmpty ? '范围: 单个收藏夹' : '范围: $name';
    }
    return '范围: ${_searchScopeBaseLabel(_searchScope)}';
  }

  String _searchHintText() {
    switch (_searchScope) {
      case _FolderSearchScope.currentDirectory:
        return '搜索当前目录';
      case _FolderSearchScope.currentCollection:
        return '搜索当前收藏夹';
      case _FolderSearchScope.allCollections:
        return '搜索全部收藏夹';
      case _FolderSearchScope.singleCollection:
        final c = _collectionById(_singleSearchCollectionId);
        final name = (c?.name ?? '').trim();
        if (name.isEmpty) return '搜索单个收藏夹';
        return '搜索收藏夹：$name';
    }
  }

  bool get _usingScopeSearch =>
      _searchScope != _FolderSearchScope.currentDirectory &&
      _q.trim().isNotEmpty;

  FavoriteCollection? _collectionById(String? id) {
    final key = (id ?? '').trim();
    if (key.isEmpty) return null;
    if (widget.collection.id == key) return widget.collection;
    for (final c in _searchCollections) {
      if (c.id == key) return c;
    }
    return null;
  }

  List<FavoriteCollection> _allSearchCollections() {
    final out = <FavoriteCollection>[widget.collection];
    for (final c in _searchCollections) {
      if (out.any((x) => x.id == c.id)) continue;
      out.add(c);
    }
    return out;
  }

  Future<void> _ensureSearchCollectionsLoaded() async {
    if (_searchCollectionsLoaded) return;
    try {
      final list = await _Store.load();
      if (!mounted) return;
      setState(() {
        _searchCollections = list;
        _searchCollectionsLoaded = true;
        _singleSearchCollectionId ??= widget.collection.id;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchCollectionsLoaded = true;
        _singleSearchCollectionId ??= widget.collection.id;
      });
    }
  }

  Future<void> _loadSearchScopeSettings() async {
    try {
      final scopeRaw = await AppSettings.getFolderSearchScope();
      final singleId = await AppSettings.getFolderSearchSingleCollectionId();
      if (!mounted) return;
      setState(() {
        switch (scopeRaw) {
          case 'currentDirectory':
            _searchScope = _FolderSearchScope.currentDirectory;
            break;
          case 'allCollections':
            _searchScope = _FolderSearchScope.allCollections;
            break;
          case 'singleCollection':
            _searchScope = _FolderSearchScope.singleCollection;
            break;
          case 'currentCollection':
          default:
            _searchScope = _FolderSearchScope.currentCollection;
            break;
        }
        final sid = (singleId ?? '').trim();
        if (sid.isNotEmpty) {
          _singleSearchCollectionId = sid;
        } else {
          _singleSearchCollectionId ??= widget.collection.id;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchScope = _FolderSearchScope.currentCollection;
        _singleSearchCollectionId ??= widget.collection.id;
      });
    }
  }

  Future<void> _persistSearchScopeSettings() async {
    await AppSettings.setFolderSearchScope(_searchScope.name);
    final sid = (_singleSearchCollectionId ?? '').trim();
    if (sid.isEmpty) {
      await AppSettings.setFolderSearchSingleCollectionId(null);
    } else {
      await AppSettings.setFolderSearchSingleCollectionId(sid);
    }
  }

  String _searchPathHint(_Entry e) {
    if (e.isWebDav) {
      final rel = (e.wdRelPath ?? '').trim();
      if (rel.isEmpty) return 'WebDAV';
      final d = p.dirname(rel);
      if (d == '.' || d == '/') return 'WebDAV 根目录';
      return 'WebDAV/$d';
    }
    if (e.isEmby) {
      return 'Emby';
    }
    final lp = (e.localPath ?? '').trim();
    if (lp.isEmpty) return '本地';
    final d = p.dirname(lp);
    if (d == '.' || d.trim().isEmpty) return '本地';
    final base = p.basename(d).trim();
    return base.isEmpty ? d : base;
  }

  _Entry _cloneEntry(
    _Entry e, {
    String? origin,
    String? searchCollectionId,
    String? searchCollectionName,
  }) {
    return _Entry(
      isDir: e.isDir,
      name: e.name,
      size: e.size,
      modified: e.modified,
      typeKey: e.typeKey,
      origin: origin ?? e.origin,
      localPath: e.localPath,
      wdAccountId: e.wdAccountId,
      wdRelPath: e.wdRelPath,
      wdHref: e.wdHref,
      embyAccountId: e.embyAccountId,
      embyItemId: e.embyItemId,
      embyCoverUrl: e.embyCoverUrl,
      searchCollectionId: searchCollectionId ?? e.searchCollectionId,
      searchCollectionName: searchCollectionName ?? e.searchCollectionName,
    );
  }

  _Entry _asSearchResult(FavoriteCollection c, _Entry e) {
    final cName = c.name.trim().isEmpty ? '未命名收藏夹' : c.name.trim();
    final hint = _searchPathHint(e);
    final label = hint.trim().isEmpty ? cName : '$cName · $hint';
    return _cloneEntry(
      e,
      origin: label,
      searchCollectionId: c.id,
      searchCollectionName: cName,
    );
  }

  String _scopeSearchCacheKey(String qLower, List<FavoriteCollection> cols) {
    final scope = _searchScope.name;
    final ids = cols.map((e) => e.id).join(',');
    return '$scope|$_singleSearchCollectionId|$ids|$qLower';
  }

  void _clearScopeSearchState({bool clearCache = false}) {
    _scopeSearchDebounce?.cancel();
    _scopeSearchToken++;
    _scopeSearching = false;
    _scopeSearchError = null;
    _scopeSearchRaw = const <_Entry>[];
    if (clearCache) _scopeSearchCache.clear();
  }

  void _scheduleScopeSearch({bool immediate = false}) {
    _scopeSearchDebounce?.cancel();
    if (!_usingScopeSearch) {
      if (_scopeSearching ||
          _scopeSearchError != null ||
          _scopeSearchRaw.isNotEmpty) {
        setState(() => _clearScopeSearchState());
      }
      return;
    }
    setState(() {
      _scopeSearching = true;
      _scopeSearchError = null;
      _scopeSearchRaw = const <_Entry>[];
    });
    void run() {
      // ignore: unawaited_futures
      _runScopeSearchNow();
    }

    if (immediate) {
      run();
    } else {
      _scopeSearchDebounce = Timer(const Duration(milliseconds: 260), run);
    }
  }

  void _onSearchQueryChanged(String v) {
    setState(() => _q = v);
    _scheduleScopeSearch();
  }

  Future<List<_Entry>> _loadRootEntriesForCollection(
    FavoriteCollection collection, {
    String searchQuery = '',
  }) async {
    final out = <_Entry>[];
    final q = searchQuery.trim();
    for (final src in collection.sources) {
      try {
        if (_isEmbySource(src)) {
          final ref = _parseEmbySource(src);
          if (ref == null) continue;
          if (q.isNotEmpty) {
            out.addAll(await _searchEmbyEntriesBySource(ref, q));
            continue;
          }
          final path = ref.path.trim().isEmpty ? 'favorites' : ref.path.trim();
          out.addAll(await _loadEmby(ref.accountId, path));
          continue;
        }

        if (_isWebDavSource(src)) {
          final ref = _parseWebDavSource(src);
          if (ref == null) continue;
          if (!ref.isDir) {
            final fileName = p.basename(ref.relPath);
            out.add(
              _Entry(
                isDir: false,
                name: fileName.isEmpty ? '文件' : fileName,
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: p.extension(fileName).toLowerCase().isEmpty
                    ? 'file'
                    : p.extension(fileName).toLowerCase(),
                origin: null,
                wdAccountId: ref.accountId,
                wdRelPath: ref.relPath,
                wdHref: '',
              ),
            );
            continue;
          }
          var rel = ref.relPath.trim();
          if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
          out.addAll(await _loadWebDavDir(ref.accountId, rel));
          continue;
        }

        final folder = src.trim();
        if (folder.isEmpty) continue;
        out.addAll(await _loadLocalDir(folder));
      } catch (_) {
        // keep searching other sources
      }
    }
    return out;
  }

  _Entry _entryFromEmbySearchItem({
    required EmbyAccount account,
    required EmbyClient client,
    required EmbyItem item,
  }) {
    final isDir = item.isFolder || _embyTypeIsDir(item.type);
    final isImg = !isDir && _embyTypeIsImage(item.type);
    final thumbWidth = _active.viewMode == ViewMode.grid ? 420 : 220;
    return _Entry(
      isDir: isDir,
      name: item.name.isEmpty ? '未命名' : item.name,
      size: isDir ? 0 : item.size,
      modified: item.dateCreated ??
          item.dateModified ??
          DateTime.fromMillisecondsSinceEpoch(0),
      typeKey: isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
      origin: null,
      embyAccountId: account.id,
      embyItemId: item.id,
      embyCoverUrl: client.bestCoverUrl(item, maxWidth: thumbWidth),
    );
  }

  Future<List<_Entry>> _searchEmbyEntriesByTraversalFallback({
    required EmbyAccount account,
    required EmbyClient client,
    required String sourcePath,
    required String query,
  }) async {
    final qLower = query.trim().toLowerCase();
    if (qLower.isEmpty) return const <_Entry>[];

    final out = <_Entry>[];
    final seenItemIds = <String>{};
    final dirQueue = <String>[];
    var cursor = 0;
    final maxVisit = (_maxScopeSearchResults * 10).clamp(400, 5000).toInt();

    void pushItem(EmbyItem item) {
      final isDirCandidate = item.isFolder || _embyTypeIsDir(item.type);
      if (!isDirCandidate) return;

      final id = item.id.trim();
      if (id.isEmpty || !seenItemIds.add(id)) return;
      final e = _entryFromEmbySearchItem(
        account: account,
        client: client,
        item: item,
      );
      if (e.isDir &&
          e.name.toLowerCase().contains(qLower) &&
          out.length < _maxScopeSearchResults) {
        out.add(e);
      }
      if (e.isDir && seenItemIds.length < maxVisit) {
        dirQueue.add(id);
      }
    }

    Future<void> seedQueue() async {
      if (sourcePath.startsWith('view:')) {
        final pid = sourcePath.substring('view:'.length).trim();
        if (pid.isEmpty) return;
        final root = await client.listChildren(parentId: pid);
        for (final it in root) {
          pushItem(it);
        }
        return;
      }

      if (sourcePath == 'favorites') {
        final fav = await client.listFavorites();
        for (final it in fav) {
          pushItem(it);
        }
        final views = await client.listViews();
        for (final it in views) {
          pushItem(it);
        }
        return;
      }

      final firstLevel = await _loadEmby(account.id, sourcePath);
      for (final e in firstLevel) {
        if (e.isLoading ||
            e.typeKey == 'hint' ||
            e.typeKey == 'emby_login' ||
            e.typeKey == 'emby_empty') {
          continue;
        }
        final id = (e.embyItemId ?? '').trim();
        if (e.isDir && id.isNotEmpty) {
          seenItemIds.add(id);
        }
        if (e.isDir &&
            e.name.toLowerCase().contains(qLower) &&
            out.length < _maxScopeSearchResults) {
          out.add(e);
        }
        if (e.isDir && id.isNotEmpty && seenItemIds.length < maxVisit) {
          dirQueue.add(id);
        }
      }
    }

    await seedQueue();

    while (cursor < dirQueue.length &&
        out.length < _maxScopeSearchResults &&
        seenItemIds.length < maxVisit) {
      final parentId = dirQueue[cursor];
      cursor++;

      List<EmbyItem> children;
      try {
        children = await client.listChildren(parentId: parentId);
      } catch (_) {
        continue;
      }

      for (final it in children) {
        pushItem(it);
        if (out.length >= _maxScopeSearchResults) break;
      }
    }

    return out;
  }

  Future<List<_Entry>> _searchEmbyEntriesBySource(
      _EmbyRef ref, String query) async {
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[ref.accountId];
    if (a == null) return const <_Entry>[];

    final client = EmbyClient(a);
    final sourcePath = ref.path.trim().isEmpty ? 'favorites' : ref.path.trim();
    String? parentId;

    if (sourcePath.startsWith('view:')) {
      final pid = sourcePath.substring('view:'.length).trim();
      if (pid.isEmpty) return const <_Entry>[];
      parentId = pid;
    } else if (sourcePath == 'favorites') {
      // favorites 入口下，允许全局递归搜索，避免“只能搜到首层”。
      parentId = null;
    } else {
      // 兜底：未知路径格式退回到原有加载并在本地做包含匹配。
      final qLower = query.trim().toLowerCase();
      final fallback = await _loadEmby(a.id, sourcePath);
      return fallback
          .where((e) => e.isDir && e.name.toLowerCase().contains(qLower))
          .toList(growable: false);
    }

    try {
      final items = await client.searchItems(
        query: query,
        parentId: parentId,
        recursive: true,
        limit: _maxScopeSearchResults,
      );
      final dirs = items
          .map((it) => _entryFromEmbySearchItem(
                account: a,
                client: client,
                item: it,
              ))
          .where((e) => e.isDir)
          .toList(growable: false);
      if (dirs.isNotEmpty) return dirs;
    } catch (_) {
      // ignore and fallback below
    }
    return _searchEmbyEntriesByTraversalFallback(
      account: a,
      client: client,
      sourcePath: sourcePath,
      query: query,
    );
  }

  Future<void> _runScopeSearchNow() async {
    final qRaw = _q.trim();
    final qLower = qRaw.toLowerCase();
    if (!_usingScopeSearch || qLower.isEmpty) {
      if (!mounted) return;
      setState(() => _clearScopeSearchState());
      return;
    }

    List<FavoriteCollection> targets = <FavoriteCollection>[];
    switch (_searchScope) {
      case _FolderSearchScope.currentDirectory:
        targets = <FavoriteCollection>[];
        break;
      case _FolderSearchScope.currentCollection:
        targets = <FavoriteCollection>[widget.collection];
        break;
      case _FolderSearchScope.allCollections:
        await _ensureSearchCollectionsLoaded();
        targets = _allSearchCollections();
        break;
      case _FolderSearchScope.singleCollection:
        await _ensureSearchCollectionsLoaded();
        var selected = _collectionById(_singleSearchCollectionId);
        if (selected == null) {
          selected = widget.collection;
          _singleSearchCollectionId = widget.collection.id;
          // ignore: unawaited_futures
          _persistSearchScopeSettings();
        }
        targets = <FavoriteCollection>[selected];
        break;
    }

    if (targets.isEmpty) {
      if (!mounted) return;
      setState(() {
        _scopeSearching = false;
        _scopeSearchError = null;
        _scopeSearchRaw = const <_Entry>[];
      });
      return;
    }

    final token = ++_scopeSearchToken;
    final cacheKey = _scopeSearchCacheKey(qLower, targets);
    final cached = _scopeSearchCache[cacheKey];
    if (cached != null) {
      if (!mounted || token != _scopeSearchToken) return;
      setState(() {
        _scopeSearching = false;
        _scopeSearchError = null;
        _scopeSearchRaw = cached;
      });
      return;
    }

    try {
      final out = <_Entry>[];
      final seen = <String>{};
      for (final c in targets) {
        if (out.length >= _maxScopeSearchResults) break;
        final list = await _loadRootEntriesForCollection(c, searchQuery: qRaw);
        for (final e in list) {
          if (out.length >= _maxScopeSearchResults) break;
          final name = e.name.toLowerCase();
          final matchedByName = name.contains(qLower);
          // Emby 使用服务端 SearchTerm 时，允许“非纯 contains”命中结果通过。
          if (!matchedByName && !(e.isEmby && qRaw.isNotEmpty)) continue;
          if (e.isLoading ||
              e.typeKey == 'hint' ||
              e.typeKey == 'wd_error' ||
              e.typeKey == 'emby_login' ||
              e.typeKey == 'emby_empty') {
            continue;
          }
          final key = '${c.id}|${e.displayPath}|${e.name}|${e.typeKey}';
          if (!seen.add(key)) continue;
          out.add(_asSearchResult(c, e));
        }
      }
      if (!mounted || token != _scopeSearchToken) return;
      _scopeSearchCache[cacheKey] = out;
      setState(() {
        _scopeSearching = false;
        _scopeSearchError = null;
        _scopeSearchRaw = out;
      });
    } catch (e) {
      if (!mounted || token != _scopeSearchToken) return;
      setState(() {
        _scopeSearching = false;
        _scopeSearchError = e;
        _scopeSearchRaw = const <_Entry>[];
      });
    }
  }

  Future<void> _showSearchScopePanel() async {
    await _ensureSearchCollectionsLoaded();
    if (!mounted) return;
    final picked = await showModalBottomSheet<_FolderSearchScope>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        Widget tile(_FolderSearchScope scope, {String? subtitle}) {
          final selected = _searchScope == scope;
          return ListTile(
            leading: Icon(_searchScopeIcon(scope)),
            title: Text(_searchScopeBaseLabel(scope)),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: selected
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
            onTap: () => Navigator.pop(ctx, scope),
          );
        }

        final singleName =
            (_collectionById(_singleSearchCollectionId)?.name ?? '').trim();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile(_FolderSearchScope.currentDirectory, subtitle: '仅筛选当前打开目录'),
              tile(_FolderSearchScope.currentCollection,
                  subtitle: '在“${widget.collection.name}”内搜索'),
              tile(_FolderSearchScope.allCollections, subtitle: '在全部收藏夹内搜索'),
              tile(
                _FolderSearchScope.singleCollection,
                subtitle: singleName.isEmpty ? '选择一个收藏夹' : '当前：$singleName',
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;

    if (picked == _FolderSearchScope.singleCollection) {
      final id = await _pickSingleSearchCollection();
      if (id == null || !mounted) return;
      setState(() {
        _searchScope = picked;
        _singleSearchCollectionId = id;
      });
      // ignore: unawaited_futures
      _persistSearchScopeSettings();
      _scheduleScopeSearch(immediate: true);
      return;
    }

    setState(() => _searchScope = picked);
    // ignore: unawaited_futures
    _persistSearchScopeSettings();
    _scheduleScopeSearch(immediate: true);
  }

  Future<String?> _pickSingleSearchCollection() async {
    await _ensureSearchCollectionsLoaded();
    final all = _allSearchCollections()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (all.isEmpty) return null;

    return showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(
          builder: (ctx2, setS) {
            final filtered = q.trim().isEmpty
                ? all
                : all
                    .where((c) =>
                        c.name.toLowerCase().contains(q.trim().toLowerCase()))
                    .toList(growable: false);
            final h =
                (MediaQuery.of(ctx2).size.height * 0.72).clamp(320.0, 560.0);
            return SizedBox(
              height: h,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setS(() => q = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索收藏夹',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: q.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空',
                                onPressed: () => setS(() => q = ''),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('没有匹配的收藏夹'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final c = filtered[i];
                              final selected =
                                  c.id == _singleSearchCollectionId;
                              return ListTile(
                                leading: const Icon(Icons.bookmark_outline),
                                title: Text(c.name),
                                subtitle: Text('来源: ${c.sources.length}'),
                                trailing: selected
                                    ? const Icon(Icons.check_circle,
                                        color: Colors.green)
                                    : null,
                                onTap: () => Navigator.pop(ctx2, c.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _stackBreadcrumb() {
    String labelFor(_NavCtx ctx) {
      final t = (ctx.title ?? '').trim();
      if (t.isNotEmpty) return t;
      if (ctx.kind == _CtxKind.local) {
        final v = p.basename(ctx.localDir ?? '').trim();
        return v.isEmpty ? '本地目录' : v;
      }
      if (ctx.kind == _CtxKind.webdav) {
        final rel = ctx.wdRel.endsWith('/')
            ? ctx.wdRel.substring(0, ctx.wdRel.length - 1)
            : ctx.wdRel;
        return rel.isEmpty ? 'WebDAV' : p.basename(rel);
      }
      if (ctx.kind == _CtxKind.emby) {
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

  _NavCtx? _navForDirectoryEntry(_Entry e) {
    if (!e.isDir) return null;
    if (e.isEmby) {
      final id = (e.embyItemId ?? '').trim();
      final pth = id.isEmpty ? 'favorites' : 'view:$id';
      return _NavCtx.emby(
          embyAccountId: e.embyAccountId!, embyPath: pth, title: e.name);
    }
    if (e.isWebDav) {
      var rel = (e.wdRelPath ?? '').trim();
      if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      return _NavCtx.webdav(
          wdAccountId: e.wdAccountId!, wdRel: rel, title: e.name);
    }
    final lp = (e.localPath ?? '').trim();
    if (lp.isEmpty) return null;
    return _NavCtx.local(lp, title: e.name);
  }

  Future<bool> _openCrossCollectionDirectoryFromSearch(_Entry e) async {
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

  Future<void> _openEntry(
    _Entry e, {
    required List<_Entry> visibleEntries,
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
        pool: _usingScopeSearch ? <_Entry>[e] : visibleEntries,
      );
      return;
    }
    if (e.isWebDav) {
      await _openWebDavFile(e);
      return;
    }
    final path = e.localPath;
    if (path == null) return;
    if (_isImg(path)) {
      if (_usingScopeSearch) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  ImageViewerPage(imagePaths: <String>[path], initialIndex: 0)),
        );
        return;
      }
      final idx = imgs.indexOf(path);
      if (idx < 0) return;
      await _recordFolderHistoryIfEnabled();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                ImageViewerPage(imagePaths: imgs, initialIndex: idx)),
      );
      return;
    }
    if (_isVid(path)) {
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
    _Entry e, {
    required List<_Entry> visibleEntries,
    required List<String> imgs,
    required List<String> vids,
  }) async {
    if (_selectionMode && _isEntrySelectable(e)) {
      setState(() => _toggleSelection(e));
      return;
    }
    await _openEntry(e, visibleEntries: visibleEntries, imgs: imgs, vids: vids);
  }

  void _onEntryLongPress(_Entry e) {
    if (_isEntrySelectable(e)) {
      setState(() {
        _selectionMode = true;
        _toggleSelection(e);
      });
      return;
    }
    if (_tagEnabled) {
      _openTagForEntry(e);
    }
  }

  Future<void> _recordFolderHistoryIfEnabled() async {
    // ✅ 目录历史：在打开图片/视频前，把“当前所在目录”写入历史。
    // 设计原因：
    // - 用户高频需求：看完图片/视频后，能一键回到刚才浏览的目录继续翻找；
    // - Emby 多级目录场景下，如果不记录目录 ctx，历史会退化为根目录/默认文案（例如：Emby 媒体）；
    // - 只记录“当前目录”一条，避免多层目录时一次性写入多条造成“把目录内容都登记进历史”的误解。
    if (_stack.isEmpty) return;
    final cur = _stack.last;
    if (cur.kind == _CtxKind.root) return;

    // 标题优先使用导航栈携带的 title，其次从路径推断，最后兜底为“目录”。
    var title = (cur.title ?? '').trim();
    if (title.isEmpty) {
      if (cur.kind == _CtxKind.local) {
        title = p.basename(cur.localDir ?? '').trim();
        if (title.isEmpty) title = (cur.localDir ?? '').trim();
      } else if (cur.kind == _CtxKind.webdav) {
        final rel = cur.wdRel.endsWith('/')
            ? cur.wdRel.substring(0, cur.wdRel.length - 1)
            : cur.wdRel;
        title = rel.isEmpty ? 'WebDAV' : p.basename(rel);
      } else if (cur.kind == _CtxKind.emby) {
        // Emby 的层级标题如果缺失，至少保持收藏夹名可读。
        title = widget.collection.name;
      }
    }
    if (title.isEmpty) title = '目录';

    // coverPath：仅对本地目录尝试提取一个可用的本地文件作为封面。
    // 设计原因：HistoryPage 的封面渲染使用 Image.file / 本地视频首帧，
    // WebDAV/Emby 的资源并不是本地文件路径，强行传入会导致封面加载失败。
    String? coverPath;
    if (cur.kind == _CtxKind.local) {
      // 优先图片，其次视频。
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

    await AppHistory.upsertFolderCtx(
        ctx: cur, title: title, coverPath: coverPath);
  }

  // ===== WebDAV 账号/Client 缓存（由 WebDavManager 统一驱动，避免 static 生命周期漏洞）=====
  final Map<String, WebDavAccount> _wdAccMap = <String, WebDavAccount>{};
  final Map<String, WebDavClient> _wdClientMap = <String, WebDavClient>{};
  bool _wdAccLoaded = false;

  // Scheme A: generate video thumbnails by downloading only a prefix into temp cache
  bool _wdAutoVideoThumb = true;
  // WebDAV 远程缩略图前缀下载阈值：过大容易抢占带宽/连接，影响起播。
  // 2MB-4MB 通常足够覆盖大多数文件头部信息；遇到 moov 在尾部会由 probeMoovInTail 决定是否全量下载。
  int _wdVideoThumbMaxBytes = 4 * 1024 * 1024; // 4MB
  final Map<String, Future<File?>> _wdVideoThumbJobs =
      <String, Future<File?>>{};

  LayerSettings get _active =>
      _stack.length == 1 ? widget.collection.layer1 : widget.collection.layer2;
  String get _title {
    if (_stack.length == 1) return widget.collection.name;
    final cur = _stack.last;
    if (cur.kind == _CtxKind.local) return p.basename(cur.localDir ?? '');
    if (cur.kind == _CtxKind.webdav) {
      final rel = cur.wdRel.endsWith('/')
          ? cur.wdRel.substring(0, cur.wdRel.length - 1)
          : cur.wdRel;
      return rel.isEmpty ? 'WebDAV' : p.basename(rel);
    }
    if (cur.kind == _CtxKind.emby) {
      final t = (cur.title ?? '').trim();
      return t.isEmpty ? widget.collection.name : t;
    }
    return widget.collection.name;
  }

  @override
  void initState() {
    super.initState();
    _singleSearchCollectionId = widget.collection.id;
    // ignore: unawaited_futures
    _loadSearchScopeSettings();
    // WebDAV 账号变化通知：清理缓存并重载
    WebDavManager.instance.addListener(_onWebDavAccountsChanged);
    // ignore: unawaited_futures
    _ensureWebDavAccountsLoaded();
    // ignore: unawaited_futures
    _loadFolderMediaCountCache();
    // ignore: unawaited_futures
    _ensureSearchCollectionsLoaded();

    // ✅ 历史/外部入口：支持直接进入指定目录上下文（尤其是 Emby 多级目录）。
    // 设计原因：
    // - HistoryPage 会把目录上下文写入 AppHistory；
    // - 点击“历史目录”时需要能还原到对应层级，否则会退化为根目录/全部内容，
    //   体验上就像“把整个目录都登记进历史”。
    final initNav = widget.initialNav;
    if (initNav != null && initNav.kind != _CtxKind.root) {
      _stack.add(initNav);
    }

    _refresh();

    // Folder cover cache init (async)
    // ignore: unawaited_futures
    _initFolderCoverCache();
    // TagStore：用于标签筛选（隐藏式筛选面板）
    // ignore: unawaited_futures
    TagStore.I.ensureLoaded().then((_) => mounted ? setState(() {}) : null);
    // 标签功能开关：用于长按打 Tag / 标签筛选 / 标签管理入口
    // 设计原因：用户不需要标签时，避免误触与多余 UI。
    AppSettings.getTagEnabled()
        .then((v) => mounted ? setState(() => _tagEnabled = v) : null);
    TagStore.I.addListener(_onTagStoreChanged);
  }

  Future<void> _initFolderCoverCache() async {
    try {
      final c = await _FolderCoverCache.init(ttl: const Duration(hours: 12));
      if (!mounted) return;
      setState(() => _folderCoverCache = c);
    } catch (_) {
      // ignore
    }
  }

  void _onWebDavAccountsChanged() {
    // 账号增删改后：清空失效 Client/缩略图任务缓存，避免使用旧 Token
    _wdAccLoaded = false;
    _wdAccMap.clear();
    _wdClientMap.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchCache.clear();
    _clearScopeSearchState();
    if (mounted) {
      // ignore: unawaited_futures
      _refresh();
    }
  }

  void _onTagStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WebDavManager.instance.removeListener(_onWebDavAccountsChanged);
    TagStore.I.removeListener(_onTagStoreChanged);
    _dirCoverJobs.clear();
    _wdVideoThumbJobs.clear();
    _scopeSearchDebounce?.cancel();
    _scrollController.dispose(); // 🔥 2. 新增：销毁控制器
    super.dispose();
  }

  Future<void> _loadFolderMediaCountCache() async {
    if (_folderMediaCountLoaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('folder_media_count_cache_v1');
      if (raw != null && raw.trim().isNotEmpty) {
        final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
        for (final e in m.entries) {
          final v = e.value;
          if (v is int) _folderMediaCountCache[e.key] = v;
          if (v is double) _folderMediaCountCache[e.key] = v.toInt();
          if (v is String) {
            final n = int.tryParse(v);
            if (n != null) _folderMediaCountCache[e.key] = n;
          }
        }
      }
    } catch (_) {
      // ignore
    }
    _folderMediaCountLoaded = true;
  }

  Future<void> _saveFolderMediaCountCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          'folder_media_count_cache_v1', jsonEncode(_folderMediaCountCache));
    } catch (_) {
      // ignore
    }
  }

  String _folderKeyForCtx(_NavCtx ctx) {
    if (ctx.kind == _CtxKind.local) return (ctx.localDir ?? '').trim();
    if (ctx.kind == _CtxKind.webdav)
      return 'webdav://${ctx.wdAccountId}/${ctx.wdRel}';
    return '';
  }

  String _folderKeyForEntry(_Entry e) {
    if (!e.isDir) return '';
    if (!e.isWebDav) return (e.localPath ?? '').trim();
    var rel = (e.wdRelPath ?? '').trim();
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
    return 'webdav://${e.wdAccountId}/$rel';
  }

  String _normWebDavDirRel(String rel) {
    var r = rel.trim();
    if (r.startsWith('/')) r = r.substring(1);
    if (r.isNotEmpty && !r.endsWith('/')) r = '$r/';
    return r;
  }

  String _folderCoverCacheKey(_Entry e) {
    if (!e.isDir) return '';
    if (e.isEmby) {
      return 'emby://${e.embyAccountId}/item:${e.embyItemId ?? ''}';
    }
    if (e.isWebDav) {
      final rel = _normWebDavDirRel(e.wdRelPath ?? '');
      return 'webdav://${e.wdAccountId}/$rel';
    }
    return 'local://${(e.localPath ?? '').trim()}';
  }

  int _estimateLocalMediaCount(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      final ents = d.listSync(followLinks: false);
      var n = 0;
      for (final it in ents) {
        if (it is File) {
          final name = p.basename(it.path);
          if (_isImgName(name) || _isVidName(name)) n++;
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  void _prefillSkeletonForFolder(_Entry folder) {
    final key = _folderKeyForEntry(folder);
    int n = 0;
    if (!folder.isWebDav) {
      final dir = folder.localPath;
      if (dir != null) n = _estimateLocalMediaCount(dir);
    }
    if (n <= 0) {
      final cached = _folderMediaCountCache[key];
      n = cached ?? 24;
    }
    // Safety clamp to keep UI smooth
    n = n.clamp(0, 120);
    if (n <= 0) return;

    setState(() {
      _raw = List.generate(n, (i) => _Entry.loading(i));
      _loading = false;
    });
  }

  void _updateFolderCountCacheFromList(_NavCtx ctx, List<_Entry> list) {
    final key = _folderKeyForCtx(ctx);
    if (key.trim().isEmpty) return;
    final n = list
        .where((e) => !e.isDir && (_isImgName(e.name) || _isVidName(e.name)))
        .length;
    if (n <= 0) return;
    _folderMediaCountCache[key] = n;
    // ignore: unawaited_futures
    _saveFolderMediaCountCache();
  }

  Future<void> _refresh({bool showGlobalLoading = true}) async {
    if (showGlobalLoading) {
      setState(() => _loading = true);
    }
    final cur = _stack.last;
    final list = switch (cur.kind) {
      _CtxKind.root => await _loadVirtual(),
      _CtxKind.local => await _loadLocalDir(cur.localDir!),
      _CtxKind.webdav => await _loadWebDavDir(cur.wdAccountId!, cur.wdRel),
      _CtxKind.emby => await _loadEmby(cur.embyAccountId!, cur.embyPath),
    };
    // Update media count cache for current folder (used for skeleton prefill)
    _updateFolderCountCacheFromList(cur, list);
    if (!mounted) return;
    setState(() {
      _raw = list;
      _loading = false;
      if (_selectionMode) {
        final keys = list
            .map(_entrySelectionKeyRaw)
            .where((e) => e.trim().isNotEmpty)
            .toSet();
        _selectedEntryKeys.removeWhere((k) => !keys.contains(k));
        if (_selectedEntryKeys.isEmpty) {
          _selectionMode = false;
        }
      }
    });
    _scopeSearchCache.clear();

    // ✅ Emby：当用户正在使用“按大小排序”时，按需补全 size=0 的条目，
    // 让排序真正对 Emby 文件数据生效。
    // ignore: unawaited_futures
    _hydrateEmbySizesIfNeeded();
  }

  Future<void> _hydrateEmbySizesIfNeeded({int maxItems = 60}) async {
    if (_embySizeHydrating) return;
    if (_stack.isEmpty) return;
    final cur = _stack.last;
    if (cur.kind != _CtxKind.emby) return;
    if (_active.sortKey != SortKey.size) return;

    final accId = (cur.embyAccountId ?? '').trim();
    if (accId.isEmpty) return;

    // 只处理“需要补全”的条目；避免对目录、占位 skeleton 造成干扰。
    final targets = _raw
        .where((e) =>
            e.isEmby &&
            !e.isDir &&
            !e.isLoading &&
            (e.embyItemId ?? '').trim().isNotEmpty &&
            e.size == 0)
        .take(maxItems)
        .toList();
    if (targets.isEmpty) return;

    final accList = await EmbyStore.load();
    final acc = accList.firstWhere((a) => a.id == accId,
        orElse: () => EmbyAccount(
              id: '',
              name: '',
              serverUrl: '',
              username: '',
              userId: '',
              apiKey: '',
            ));
    if (acc.id.isEmpty) return;

    _embySizeHydrating = true;
    final client = EmbyClient(acc);

    // 分批并发（轻量）：避免一次性开太多 HTTP 连接。
    const int batch = 6;
    final Map<String, int> updates = <String, int>{}; // key: itemId

    try {
      for (int i = 0; i < targets.length; i += batch) {
        final end = (i + batch) < targets.length ? (i + batch) : targets.length;
        final slice = targets.sublist(i, end);
        final futures = <Future<void>>[];
        for (final e in slice) {
          final itemId = (e.embyItemId ?? '').trim();
          if (itemId.isEmpty) continue;
          final cacheKey = '$accId|$itemId';
          final cached = _embySizeCache[cacheKey];
          if (cached != null && cached > 0) {
            updates[itemId] = cached;
            continue;
          }
          futures.add(() async {
            try {
              final sz = await client.getItemSize(itemId).timeout(
                    const Duration(seconds: 6),
                    onTimeout: () => null,
                  );
              if (sz != null && sz > 0) {
                _embySizeCache[cacheKey] = sz;
                updates[itemId] = sz;
              }
            } catch (_) {
              // 单条失败不影响整体。
            }
          }());
        }
        if (futures.isNotEmpty) {
          await Future.wait(futures);
        }
      }
    } catch (_) {
      // 静默失败：不影响主流程/浏览。
    } finally {
      _embySizeHydrating = false;
    }

    if (!mounted) return;
    if (updates.isEmpty) return;

    // 把补全结果写回 _raw（保持其它字段不变）。
    setState(() {
      _raw = _raw.map((e) {
        if (!e.isEmby || e.isDir || e.isLoading) return e;
        if (e.embyAccountId != accId) return e;
        final itemId = (e.embyItemId ?? '').trim();
        final sz = updates[itemId];
        if (sz == null || sz <= 0) return e;
        if (e.size > 0) return e;
        return _Entry(
          isDir: e.isDir,
          name: e.name,
          size: sz,
          modified: e.modified,
          typeKey: e.typeKey,
          origin: e.origin,
          localPath: e.localPath,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
          embyCoverUrl: e.embyCoverUrl,
        );
      }).toList();
    });
  }

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

  /// =========================
  /// Favorites source migration helpers
  /// =========================
  /// 收藏夹里保存的是账号 id；当用户重新登录/重建账号后，id 会变化，导致「账号不存在/已删除」。
  /// 这里做一个“尽量自动修复”的迁移：
  /// - 如果当前仅存在 1 个账号，则自动把旧 id 迁移到新 id（保持 relPath/path 不变）。
  /// - 如果存在多个账号，则不做猜测，提示用户去「编辑来源」重新绑定。
  bool _tryMigrateWebDavRef(_WebDavRef ref) {
    final accMap = _wdAccMap;
    if (accMap.containsKey(ref.accountId)) return false;
    if (accMap.length != 1) return false;
    final newId = accMap.keys.first;
    // Replace in collection sources
    final old =
        _buildWebDavSource(ref.accountId, ref.relPath, isDir: ref.isDir);
    final neu = _buildWebDavSource(newId, ref.relPath, isDir: ref.isDir);
    final i = widget.collection.sources.indexOf(old);
    if (i >= 0) {
      widget.collection.sources[i] = neu;
      return true;
    }
    // fallback: replace by parsing equality (same relPath/isDir) even if encoding differs
    for (int k = 0; k < widget.collection.sources.length; k++) {
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
    final neu = 'emby://$newId/${ref.path}';
    for (int k = 0; k < widget.collection.sources.length; k++) {
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

  bool _embyTypeIsDir(String t) {
    final raw = t.trim();
    if (raw.isEmpty) return false;

    final l = raw.toLowerCase();

    // ✅ Emby 常见“目录/容器”类型（关键修复：PhotoAlbum / MusicAlbum / UserView 等）
    // 经验规则：只要它像“容器”，就当目录打开，避免误判成图片
    if (l.contains('folder') ||
        l.contains('album') || // PhotoAlbum / MusicAlbum / Album
        l.contains('collection') || // Collection / CollectionFolder
        l.contains('boxset') ||
        l.contains('season') ||
        l.contains('series') ||
        l.contains('view') || // UserView / View
        l.contains('playlist')) {
      return true;
    }

    // ✅ 精确兜底
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

  bool _embyTypeIsImage(String t) {
    final raw = t.trim();
    if (raw.isEmpty) return false;

    // ✅ 目录优先：目录绝不当图片
    if (_embyTypeIsDir(raw)) return false;

    final l = raw.toLowerCase();
    if (l.contains('photo') || l.contains('image') || l.contains('picture'))
      return true;

    const imgTypes = <String>{
      'Photo',
      'Image',
    };
    return imgTypes.contains(raw);
  }

  Future<List<_Entry>> _loadVirtual() async {
    final out = <_Entry>[];

    final hasWebDav = widget.collection.sources.any(_isWebDavSource);
    if (hasWebDav) {
      await _ensureWebDavAccountsLoaded(force: true);
    } else {
      // Avoid forcing WebDAV reload when the collection doesn't reference WebDAV.
      _wdAccMap.clear();
      _wdClientMap.clear();
      _wdAccLoaded = true;
    }
    final accMap = _wdAccMap;

    final embyAccList = await EmbyStore.load();
    final embyAccMap = {for (final a in embyAccList) a.id: a};

    for (final src in widget.collection.sources) {
      // ---- Emby ----
      if (_isEmbySource(src)) {
        final ref = _parseEmbySource(src);
        if (ref == null) continue;

        var a = embyAccMap[ref.accountId];
        if (a == null) {
          final migrated = _tryMigrateEmbyRef(ref, embyAccMap);
          if (migrated) {
            // retry with migrated id
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

        // 收藏夹根层：优先展示收藏；如果收藏为空，则展示“媒体库（Views）”
        try {
          final fav = await client.listFavorites();
          if (fav.isNotEmpty) {
            for (final it in fav) {
              final cover = client.bestCoverUrl(
                it,
                maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
              );

              // ✅ 修复点：目录优先判定，避免 PhotoAlbum/UserView 等被当成图片
              final isDir = _embyTypeIsDir(it.type);
              final isImg = _embyTypeIsImage(it.type);

              out.add(
                _Entry(
                  isDir: isDir,
                  name: it.name.isEmpty ? '未命名' : it.name,
                  size: isDir ? 0 : it.size,
                  // ✅ Emby 日期排序增强：优先 DateCreated（加入库时间），兜底 DateModified。
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
            continue;
          }

          // favorites empty -> show views as folders
          final views = await client.listViews();
          if (views.isEmpty) {
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

          for (final v in views) {
            // ✅ views 本质就是目录（UserView）
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

      // ---- WebDAV ----
      if (_isWebDavSource(src)) {
        final ref = _parseWebDavSource(src);
        if (ref == null) continue;

        var a = accMap[ref.accountId];
        if (a == null && hasWebDav) {
          final migrated = _tryMigrateWebDavRef(ref);
          if (migrated) {
            // reload map and retry with migrated id
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

        String baseRel = ref.relPath;
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

      // ---- Local ----
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

    // Empty state: collection with no valid sources should still open
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
    // ✅ Fix: always sync account map before listing, otherwise WebDAV folder may show empty.
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

  int _cmp(_Entry a, _Entry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;

    // ✅ Emby 排序增强：
    // - 部分 Emby 服务端/版本在列表接口中不会返回完整的 MediaSources/DateCreated，
    //   导致 size=0 / date=epoch0，从而“大小/日期排序看起来不生效”。
    // - 这里把 Emby 的“未知值”统一排到末尾（无论升序/降序），并在相同值时以名称做稳定兜底。
    final asc = _active.asc;

    bool embyUnknownDate(_Entry e) =>
        e.isEmby && !e.isDir && e.modified.millisecondsSinceEpoch == 0;
    bool embyUnknownSize(_Entry e) => e.isEmby && !e.isDir && e.size == 0;
    int byName() => _naturalSort(a.name.toLowerCase(), b.name.toLowerCase());

    int r;
    switch (_active.sortKey) {
      case SortKey.name:
        r = byName();
        if (r != 0) return asc ? r : -r;
        // tie-breaker: date
        r = a.modified.compareTo(b.modified);
        return asc ? r : -r;

      case SortKey.date:
        final au = embyUnknownDate(a);
        final bu = embyUnknownDate(b);
        if (au != bu) return au ? 1 : -1; // unknown always last
        r = a.modified.compareTo(b.modified);
        if (r != 0) return asc ? r : -r;
        r = byName();
        return asc ? r : -r;

      case SortKey.size:
        final au = embyUnknownSize(a);
        final bu = embyUnknownSize(b);
        if (au != bu) return au ? 1 : -1; // unknown always last
        r = a.size.compareTo(b.size);
        if (r != 0) return asc ? r : -r;
        r = byName();
        return asc ? r : -r;

      case SortKey.type:
        r = a.typeKey.compareTo(b.typeKey);
        if (r != 0) return asc ? r : -r;
        // 类型排序兜底也用自然排序
        r = byName();
        return asc ? r : -r;
    }
  }

  // ✅ 核心自然排序方法
  int _naturalSort(String a, String b) {
    int aIdx = 0, bIdx = 0;
    final aLen = a.length, bLen = b.length;

    while (aIdx < aLen && bIdx < bLen) {
      final aChar = a[aIdx];
      final bChar = b[bIdx];

      if (aChar.isDigit && bChar.isDigit) {
        // 提取连续数字段
        String aNum = '', bNum = '';
        while (aIdx < aLen && a[aIdx].isDigit) aNum += a[aIdx++];
        while (bIdx < bLen && b[bIdx].isDigit) bNum += b[bIdx++];

        // 数字转整数比较
        final numA = int.parse(aNum);
        final numB = int.parse(bNum);
        if (numA != numB) return numA.compareTo(numB);
      } else {
        // 非数字字符，正常字符串比较
        if (aChar != bChar) return aChar.compareTo(bChar);
        aIdx++;
        bIdx++;
      }
    }
    // 处理长度不一致的情况
    return aLen.compareTo(bLen);
  }

  List<_Entry> _shown() {
    final q = _q.trim().toLowerCase();
    var out = _usingScopeSearch
        ? [..._scopeSearchRaw]
        : (q.isEmpty
            ? [..._raw]
            : _raw.where((e) => e.name.toLowerCase().contains(q)).toList());

    // Tag 过滤（图片/视频/文件统一）
    final tid = _selectedTagId;
    if (tid != null && tid.trim().isNotEmpty) {
      out = out.where((e) {
        final key = tagKeyForEntry(
          isWebDav: e.isWebDav,
          isEmby: e.isEmby,
          localPath: e.localPath,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
        );
        if (key.trim().isEmpty) return false;
        return TagStore.I.hasTag(key, tid);
      }).toList();
    }
    out.sort(_cmp);
    return out;
  }

  List<String> _imgs(List<_Entry> l) => l
      .where((e) =>
          !e.isDir &&
          !e.isWebDav &&
          e.localPath != null &&
          _isImg(e.localPath!))
      .map((e) => e.localPath!)
      .toList();
  List<String> _vids(List<_Entry> l) => l
      .where((e) =>
          !e.isDir &&
          !e.isWebDav &&
          e.localPath != null &&
          _isVid(e.localPath!))
      .map((e) => e.localPath!)
      .toList();

  Future<void> _addFilesHere() async {
    final cur = _stack.last;
    if (cur.kind != _CtxKind.local) return;
    final dir = cur.localDir;
    if (dir == null) return;

    final n = await _addFilesToDir(dir);
    if (!mounted) return;
    if (n <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未添加文件')));
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已添加 $n 个文件到：$dir')));
    await _refresh();
  }

  Future<void> _ctxEntryMenu(_Entry e, Offset pos) async {
    final items = <_CtxItem<String>>[
      if (_tagEnabled) const _CtxItem('tag', '标记Tag', Icons.sell_outlined),
      if (_isVidName(e.name) || _isImgName(e.name))
        const _CtxItem('thumb', '检查封面原因', Icons.image_search),
    ];

    final a = await _ctxMenu<String>(context, pos, items);
    switch (a) {
      case 'thumb':
        await ThumbnailInspector.inspectAndExplain(
          context,
          name: e.name,
          isWebDav: e.isWebDav,
          localPath: e.localPath,
          wdHref: e.wdHref,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
        );
        if (mounted && e.isWebDav) {
          final accId = e.wdAccountId;
          if (accId != null) {
            final acc = _wdAccMap[accId];
            final client =
                _wdClientMap[accId] ?? (acc == null ? null : WebDavClient(acc));
            final href = (e.wdHref != null && e.wdHref!.trim().isNotEmpty)
                ? e.wdHref!.trim()
                : (client != null && e.wdRelPath != null
                    ? client.resolveRel(e.wdRelPath!).toString()
                    : '');

            final key = '$accId|$href';
            _wdVideoThumbJobs.remove(key);
          }
          setState(() {}); // ✅ 刷新当前列表项
        }
        break;

      case 'tag':
        final key = tagKeyForEntry(
          isWebDav: e.isWebDav,
          isEmby: e.isEmby,
          localPath: e.localPath,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
        );
        if (key.trim().isEmpty) return;
        final meta = TagTargetMeta(
          key: key,
          name: e.name,
          kind: _tagKindForEntry(e),
          isDir: e.isDir,
          isWebDav: e.isWebDav,
          isEmby: e.isEmby,
          wdAccountId: e.wdAccountId,
          wdRelPath: e.wdRelPath,
          wdHref: e.wdHref,
          embyAccountId: e.embyAccountId,
          embyItemId: e.embyItemId,
          embyCoverUrl: e.embyCoverUrl,
          localPath: e.localPath,
        );
        await TagUI.showTagPicker(context, target: meta);
        if (!mounted) return;
        setState(() {}); // 让 TagChipsBar / 列表过滤即时刷新
        break;
    }
  }

  Future<void> _openFolder(_Entry e) async {
    if (!e.isDir) return;

    // 🔥 4. 进入下一级前，记录当前位置
    if (_scrollController.hasClients) {
      _scrollOffsets[_stack.length - 1] = _scrollController.offset;
    }

    if (e.isEmby) {
      final pth =
          e.isDir && (e.embyItemId != null && e.embyItemId!.trim().isNotEmpty)
              ? 'view:${e.embyItemId}'
              : 'favorites';
      setState(() {
        _stack.add(_NavCtx.emby(
            embyAccountId: e.embyAccountId!, embyPath: pth, title: e.name));
        _q = '';
        _searchExpanded = false;
        _clearScopeSearchState();
        _clearSelection();
      });
    } else if (e.isWebDav) {
      var rel = e.wdRelPath ?? '';
      if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      setState(() {
        _stack.add(_NavCtx.webdav(
            wdAccountId: e.wdAccountId!, wdRel: rel, title: e.name));
        _q = '';
        _searchExpanded = false;
        _clearScopeSearchState();
        _clearSelection();
      });
    } else {
      final path = e.localPath;
      if (path == null) return;
      setState(() {
        _stack.add(_NavCtx.local(path, title: e.name));
        _q = '';
        _searchExpanded = false;
        _clearScopeSearchState();
        _clearSelection();
      });
    }

    _prefillSkeletonForFolder(e);
    await _refresh(showGlobalLoading: false);

    // 🔥 5. 必须等待 UI 构建完，且确保新页面归零
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  Future<void> _openWebDavFile(_Entry e) async {
    final accs = await _loadWebDavAccountsMapShared();
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
      if (_isImgName(name)) {
        // ✅ 可选：点击图片时把“所在收藏夹”也记入历史（设置可关闭）。
        await _recordFolderHistoryIfEnabled();
        final relFile = (e.wdRelPath ?? '').toString();
        final parent = p.dirname(relFile);
        final parentRel = (parent == '.' || parent == '/')
            ? ''
            : (parent.endsWith('/') ? parent : '$parent/');
        final items = await client.list(parentRel);
        final imgs = items
            .where((x) => !x.isDir && _isImgName(x.name))
            .toList(growable: false);
        final paths = imgs
            .map((x) => _buildWebDavSource(a.id, x.relPath, isDir: false))
            .toList(growable: false);
        final idx = imgs.indexWhere((x) => x.relPath == relFile);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(
              imagePaths: paths.isEmpty
                  ? [_buildWebDavSource(a.id, relFile, isDir: false)]
                  : paths,
              initialIndex: (idx < 0) ? 0 : idx,
            ),
          ),
        );
        return;
      }

      if (_isVidName(name)) {
        final relFile = (e.wdRelPath ?? '').toString();
        final parent = p.dirname(relFile);
        final parentRel = (parent == '.' || parent == '/')
            ? ''
            : (parent.endsWith('/') ? parent : '$parent/');
        final items = await client.list(parentRel);
        final vids = items
            .where((x) => !x.isDir && _isVidName(x.name))
            .toList(growable: false);
        final paths = vids
            .map((x) => _buildWebDavSource(a.id, x.relPath, isDir: false))
            .toList(growable: false);
        final idx = vids.indexWhere((x) => x.relPath == relFile);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPlayerPage(
              videoPaths: paths.isEmpty
                  ? [_buildWebDavSource(a.id, relFile, isDir: false)]
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
      // ✅ 安全：避免把 URL 中的 BasicAuth / token 原样暴露到 UI。
      final msg = redactSensitiveText(err.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开/下载失败：$msg')));
    }
  }

  Future<bool> _onBack() async {
    if (_selectionMode) {
      setState(_clearSelection);
      return false;
    }
    if (widget.exitOnInitialContextBack &&
        widget.initialNav != null &&
        widget.initialNav!.kind != _CtxKind.root &&
        _stack.length == 2) {
      Navigator.pop(context, widget.collection);
      return false;
    }
    if (_stack.length > 1) {
      setState(() {
        _stack.removeLast();
        _q = '';
        _searchExpanded = false;
        _clearScopeSearchState();
        _clearSelection();
      });

      // 刷新数据（UI 会经历 loading 态）
      await _refresh();

      // 🔥 6. 核心：等 UI 渲染完毕后，恢复上一级的位置
      final targetDepth = _stack.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollOffsets.containsKey(targetDepth) &&
            _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollOffsets[targetDepth]!);
        }
      });

      return false;
    }
    Navigator.pop(context, widget.collection);
    return false;
  }

  Future<void> _pickView() async {
    final v = await _picker<ViewMode>(
      context,
      title: '视图模式',
      current: _active.viewMode,
      options: ViewMode.values,
      labelOf: _vmLabel,
      iconOf: _vmIcon,
    );
    if (v == null) return;
    setState(() => _active.viewMode = v);
  }

  Future<void> _pickSort() async {
    final k = await _picker<SortKey>(
      context,
      title: '排序方式',
      current: _active.sortKey,
      options: SortKey.values,
      labelOf: _skLabel,
      iconOf: _skIcon,
    );
    if (k == null) return;
    setState(() => _active.sortKey = k);

    // ✅ 当用户切换到“按大小排序”且当前为 Emby 目录时，按需补全 size=0。
    // ignore: unawaited_futures
    _hydrateEmbySizesIfNeeded();
  }

  Future<void> _showTagFilterPanel() async {
    final all = List<Tag>.from(TagStore.I.allTags)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    String q = '';
    bool searchExpanded = false;
    String? pick;
    Widget tileAll(BuildContext ctx) {
      final isAll = _selectedTagId == null || _selectedTagId!.isEmpty;
      return ListTile(
        leading: Icon(isAll ? Icons.check_circle : Icons.circle_outlined),
        title: const Text('全部'),
        onTap: () => Navigator.pop(ctx, null),
      );
    }

    Widget tileTag(BuildContext ctx, Tag t) {
      final sel = _selectedTagId == t.id;
      return ListTile(
        leading: CircleAvatar(
          radius: 10,
          backgroundColor: Color(t.colorValue),
          child: sel
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
        title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: sel ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(ctx, t.id),
      );
    }

    Future<String?> showMobile() {
      return showModalBottomSheet<String?>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState) {
              final size = MediaQuery.of(ctx2).size;
              final insets = MediaQuery.of(ctx2).viewInsets;
              final h = (size.height * 0.68).clamp(300.0, 560.0);
              final filtered = q.trim().isEmpty
                  ? all
                  : all
                      .where((t) =>
                          t.name.toLowerCase().contains(q.trim().toLowerCase()))
                      .toList();

              return AnimatedPadding(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: insets.bottom),
                child: SizedBox(
                  height: h,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '标签筛选',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx2, null),
                              child: const Text('全部'),
                            ),
                            IconButton(
                              tooltip: searchExpanded || q.trim().isNotEmpty
                                  ? '收起搜索'
                                  : '展开搜索',
                              onPressed: () => setState(() {
                                final showing =
                                    searchExpanded || q.trim().isNotEmpty;
                                if (showing) {
                                  q = '';
                                  searchExpanded = false;
                                } else {
                                  searchExpanded = true;
                                }
                              }),
                              icon: Icon(
                                searchExpanded || q.trim().isNotEmpty
                                    ? Icons.close
                                    : Icons.search,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (searchExpanded || q.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: SizedBox(
                            height: 40,
                            child: TextField(
                              autofocus: true,
                              onChanged: (v) => setState(() => q = v),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '搜索标签…',
                                prefixIcon: const Icon(Icons.search, size: 18),
                                suffixIcon: q.trim().isEmpty
                                    ? IconButton(
                                        tooltip: '收起',
                                        icon: const Icon(Icons.expand_less,
                                            size: 18),
                                        onPressed: () => setState(
                                            () => searchExpanded = false),
                                      )
                                    : IconButton(
                                        tooltip: '清除',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: () => setState(() => q = ''),
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                              ),
                            ),
                          ),
                        ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          children: [
                            tileAll(ctx2),
                            const Divider(height: 1),
                            if (filtered.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(20),
                                child: Center(child: Text('没有匹配的标签')),
                              )
                            else
                              for (final t in filtered) tileTag(ctx2, t),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }

    Future<String?> showDesktop() {
      return showGeneralDialog<String?>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'tag_filter',
        barrierColor: Colors.black26,
        transitionDuration: Duration.zero,
        pageBuilder: (ctx, _, __) {
          final size = MediaQuery.of(ctx).size;
          final w = (size.width * 0.78).clamp(280.0, 420.0);
          return StatefulBuilder(builder: (ctx2, setState) {
            final filtered = q.trim().isEmpty
                ? all
                : all
                    .where((t) =>
                        t.name.toLowerCase().contains(q.trim().toLowerCase()))
                    .toList();
            return Align(
              alignment: Alignment.centerRight,
              child: Material(
                color: Theme.of(ctx2).colorScheme.surface,
                elevation: 10,
                child: SizedBox(
                  width: w,
                  height: size.height,
                  child: SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '标签筛选',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                tooltip: searchExpanded || q.trim().isNotEmpty
                                    ? '收起搜索'
                                    : '展开搜索',
                                onPressed: () => setState(() {
                                  final showing =
                                      searchExpanded || q.trim().isNotEmpty;
                                  if (showing) {
                                    q = '';
                                    searchExpanded = false;
                                  } else {
                                    searchExpanded = true;
                                  }
                                }),
                                icon: Icon(
                                  searchExpanded || q.trim().isNotEmpty
                                      ? Icons.close
                                      : Icons.search,
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭',
                                onPressed: () => Navigator.pop(ctx2),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                        if (searchExpanded || q.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: SizedBox(
                              height: 40,
                              child: TextField(
                                onChanged: (v) => setState(() => q = v),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: '搜索标签…',
                                  prefixIcon:
                                      const Icon(Icons.search, size: 18),
                                  suffixIcon: q.trim().isEmpty
                                      ? IconButton(
                                          tooltip: '收起',
                                          icon: const Icon(Icons.expand_less,
                                              size: 18),
                                          onPressed: () => setState(
                                              () => searchExpanded = false),
                                        )
                                      : IconButton(
                                          tooltip: '清除',
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          onPressed: () =>
                                              setState(() => q = ''),
                                        ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                ),
                              ),
                            ),
                          ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView(
                            children: [
                              tileAll(ctx2),
                              const Divider(height: 1),
                              if (filtered.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Center(child: Text('没有匹配的标签')),
                                )
                              else
                                for (final t in filtered) tileTag(ctx2, t),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          });
        },
      );
    }

    final selected =
        isCompactWidth(context) ? await showMobile() : await showDesktop();

    if (!mounted) return;
    pick = selected;
    if (pick != _selectedTagId) {
      setState(() => _selectedTagId = pick);
    }
  }

  Widget build(BuildContext context) {
    final list = _shown();
    final imgs = _imgs(list);
    final vids = _vids(list);
    final hasQuery = _q.trim().isNotEmpty;
    final hasTagFilter =
        _tagEnabled && _selectedTagId != null && _selectedTagId!.isNotEmpty;
    final hasScopeInfo =
        hasQuery && _searchScope != _FolderSearchScope.currentDirectory;
    final hasFilterState = hasQuery || hasTagFilter;
    final scopedLoading = _usingScopeSearch && _scopeSearching;
    final scopedError = _usingScopeSearch ? _scopeSearchError : null;
    final selectedVisible = _selectedEntriesFrom(list);
    final selectedCount = selectedVisible.length;

    final body = _loading
        ? const AppLoadingState()
        : (scopedLoading && list.isEmpty)
            ? const AppLoadingState()
            : (scopedError != null && list.isEmpty)
                ? AppErrorState(
                    title: '搜索失败',
                    details: friendlyErrorMessage(scopedError),
                    onRetry: () => _scheduleScopeSearch(immediate: true),
                  )
                : list.isEmpty
                    ? AppEmptyState(
                        title: hasFilterState ? '没有匹配结果' : '没有内容',
                        subtitle:
                            hasFilterState ? '尝试调整筛选条件' : '试试切换排序、视图或下拉刷新',
                        icon: Icons.folder_off_outlined,
                        actionLabel: hasFilterState ? '清空筛选' : '刷新',
                        onAction: hasFilterState
                            ? () => setState(() {
                                  _q = '';
                                  _searchExpanded = false;
                                  _clearScopeSearchState();
                                  _selectedTagId = null;
                                })
                            : _refresh,
                      )
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: _buildByMode(list, imgs, vids),
                      );

    return WillPopScope(
      onWillPop: _onBack,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF7F6FF), Color(0xFFEFF4FF), Color(0xFFF6FBFF)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
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
                                          .withOpacity(0.65),
                                    ),
                                  ),
                                  Text(
                                    _title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip:
                                  _searchExpanded || hasQuery ? '收起搜索' : '展开搜索',
                              onPressed: () => setState(() {
                                final showing = _searchExpanded || hasQuery;
                                if (showing) {
                                  _q = '';
                                  _searchExpanded = false;
                                  _clearScopeSearchState();
                                } else {
                                  _searchExpanded = true;
                                }
                              }),
                              icon: Icon(
                                _searchExpanded || hasQuery
                                    ? Icons.close
                                    : Icons.search,
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
                                    value: 'history',
                                    icon: Icons.history,
                                    label: '历史记录'),
                                const TopActionMenuItem(
                                    value: 'refresh',
                                    icon: Icons.refresh,
                                    label: '刷新'),
                                if (_stack.isNotEmpty &&
                                    _stack.last.kind == _CtxKind.local)
                                  const TopActionMenuItem(
                                      value: 'add',
                                      icon: Icons.add,
                                      label: '添加文件'),
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
                              onSelected: (v) async {
                                switch (v) {
                                  case 'search_scope':
                                    await _showSearchScopePanel();
                                    break;
                                  case 'history':
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => const HistoryPage()),
                                    );
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
                                        onOpenItem: (item) =>
                                            openTagTarget(context, item),
                                        onLocateItem: (item) =>
                                            locateTagTarget(context, item),
                                      ),
                                    );
                                    break;
                                  case 'webdav':
                                    if (!mounted) return;
                                    await Navigator.push(
                                        context, WebDavPage.routeNoAnim());
                                    break;
                                  case 'emby':
                                    if (!mounted) return;
                                    await Navigator.push(
                                        context, EmbyPage.routeNoAnim());
                                    break;
                                }
                              },
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
                                      onPressed: () => setState(
                                          () => _searchExpanded = false),
                                    )
                                  : IconButton(
                                      tooltip: '清空',
                                      icon: const Icon(Icons.close),
                                      onPressed: () =>
                                          _onSearchQueryChanged(''),
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
                ),
                FilterBar(
                  children: [
                    if (_tagEnabled)
                      ControlChip(
                        icon:
                            (_selectedTagId == null || _selectedTagId!.isEmpty)
                                ? Icons.sell_outlined
                                : Icons.sell,
                        label: '标签',
                        selected: _selectedTagId != null &&
                            _selectedTagId!.isNotEmpty,
                        onTap: _showTagFilterPanel,
                      ),
                    ControlChip(
                      icon: _vmIcon(_active.viewMode),
                      label: _vmLabel(_active.viewMode),
                      selected: true,
                      onTap: _pickView,
                    ),
                    ControlChip(
                      icon: _skIcon(_active.sortKey),
                      label: _skLabel(_active.sortKey),
                      selected: true,
                      onTap: _pickSort,
                    ),
                    ControlChip(
                      icon: _active.asc
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      label: _active.asc ? '升序' : '降序',
                      selected: true,
                      onTap: () => setState(() => _active.asc = !_active.asc),
                    ),
                  ],
                ),
                if (hasFilterState)
                  Padding(
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
                                  '范围: ${_searchScope == _FolderSearchScope.singleCollection ? _searchScopeChipLabel().replaceFirst('范围: ', '') : _searchScopeBaseLabel(_searchScope)}',
                                if (hasTagFilter) '标签筛选',
                                if (scopedLoading) '搜索中…',
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _q = '';
                              _searchExpanded = false;
                              _clearScopeSearchState();
                              _selectedTagId = null;
                            }),
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: body),
                if (_selectionMode)
                  SelectionBar(
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
                        onTap: () => setState(_clearSelection),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildByMode(List<_Entry> l, List<String> imgs, List<String> vids) {
    switch (_active.viewMode) {
      case ViewMode.list:
        return ListView.builder(
          controller: _scrollController, // 🔥 3. 绑定控制器
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: l.length,
          itemBuilder: (_, i) => _listItem(l[i], l, imgs, vids),
        );
      case ViewMode.gallery:
        return GridView.builder(
          controller: _scrollController, // 🔥 3. 绑定控制器
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45),
          itemCount: l.length,
          itemBuilder: (_, i) => _cardItem(l[i], l, imgs, vids),
        );
      case ViewMode.grid:
        return GridView.builder(
          controller: _scrollController, // 🔥 3. 绑定控制器
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95),
          itemCount: l.length,
          itemBuilder: (_, i) => _cardItem(l[i], l, imgs, vids),
        );
    }
  }

  /// ✅ 核心改造：WebDAV文件预览组件【无改动，原有逻辑正常】

  Future<Map<String, EmbyAccount>> _loadEmbyAccountsMap() async {
    final list = await EmbyStore.load();
    return {for (final a in list) a.id: a};
  }

  Widget _embyThumb(_Entry e) {
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

  Future<void> _openEmbyItem(_Entry e, {List<_Entry>? pool}) async {
    final playlistPool = pool ?? _raw;
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[e.embyAccountId!];
    if (a == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Emby 配置不存在/已删除')));
      return;
    }
    final client = EmbyClient(a);

    // ✅ 强兜底：目录永远优先打开目录（避免被当成图片/视频）
    final looksDir = e.isDir || e.typeKey == 'emby_folder';
    if (looksDir && e.embyItemId != null && e.embyItemId!.trim().isNotEmpty) {
      final next = FavoriteCollection(
        id: '_tmp_emby_${DateTime.now().millisecondsSinceEpoch}',
        name: e.name,
        sources: ['emby://${a.id}/view:${e.embyItemId}'],
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

    // ✅ 图片：同目录图片组合成列表播放
    if (e.typeKey == 'emby_image' && e.embyItemId != null) {
      // ✅ 可选：点击图片时把“所在收藏夹”也记入历史（设置可关闭）。
      await _recordFolderHistoryIfEnabled();
      // 从当前目录 _raw 里抽取所有图片（同账号、非目录、typeKey=emby_image）
      final items = playlistPool
          .where((x) =>
              x.embyAccountId == e.embyAccountId &&
              !x.isDir &&
              x.embyItemId != null &&
              x.typeKey == 'emby_image')
          .toList(growable: false);

      // 组装图片 URL 列表（优先使用列表项已有封面 URL，避免部分无 tag 的 Primary 404）
      String imgUrlFor(_Entry x) {
        final preferred = _embyPreferOriginalUrl((x.embyCoverUrl ?? '').trim());
        if (preferred.isNotEmpty) return preferred;
        final id = (x.embyItemId ?? '').trim();
        if (id.isEmpty) return '';
        return client.originalImageUrl(id);
      }

      final single = imgUrlFor(e);
      final urls = items.isEmpty
          ? <String>[if (single.isNotEmpty) single]
          : items
              .map(imgUrlFor)
              .where((u) => u.trim().isNotEmpty)
              .toList(growable: false);

      // 定位到当前图片
      final idx = items.isEmpty
          ? 0
          : items.indexWhere((x) => x.embyItemId == e.embyItemId);
      final fallbackSingle =
          single.isNotEmpty ? single : client.originalImageUrl(e.embyItemId!);

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths: urls.isEmpty ? <String>[fallbackSingle] : urls,
            initialIndex: (idx < 0) ? 0 : idx,
          ),
        ),
      );
      return;
    }

    // ✅ 视频：播放（从当前列表中抽取同账号的可播放项形成播放列表）
    try {
      final items = playlistPool
          .where((x) =>
              x.embyAccountId == e.embyAccountId &&
              !x.isDir &&
              x.embyItemId != null &&
              x.typeKey != 'emby_image' &&
              x.typeKey != 'emby_folder')
          .toList(growable: false);

      // ✅ 关键修正：播放器内部会把 emby:// 源解析为真实 streamUrl。
      // 设计原因：
      // - 如果这里直接传 streamUrl，历史记录会把“stream?...api_key=...”当成标题，导致你截图里的乱码；
      // - 统一用 emby:// 作为“稳定 key”，历史与 Tag 都能复用同一套逻辑。
      final urls = items
          .map((x) =>
              'emby://${a.id}/item:${x.embyItemId!}?name=${Uri.encodeComponent(x.name)}')
          .toList(growable: false);
      final idx = items.indexWhere((x) => x.embyItemId == e.embyItemId);

      // ✅ 修复：播放视频时不应把“目录”本身写入历史。
      // 历史记录的主目标是“播放过的媒体”；目录记录会造成“目录 + 视频”两条同时出现，
      // 容易被误解为“把目录里的内容都加入历史”。
      //
      // 说明：
      // - 目录历史仍保留用于「打开图片」场景（更符合“看完回到目录继续翻”的需求）。
      // - 如果未来确实需要“视频也带目录上下文”，建议改为把 ctx 写入媒体历史条目的扩展字段，
      //   而不是单独插入一条 folder 历史。

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            videoPaths: urls.isEmpty
                ? [
                    'emby://${a.id}/item:${e.embyItemId!}?name=${Uri.encodeComponent(e.name)}'
                  ]
                : urls,
            initialIndex: (idx < 0) ? 0 : idx,
          ),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      // ✅ 安全：避免把 Emby api_key / token 等敏感信息原样暴露到 UI。
      final msg = redactSensitiveText(err.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：$msg')));
    }
  }

  Future<List<_Entry>> _loadEmby(String accountId, String path) async {
    final accMap = await _loadEmbyAccountsMap();
    final a = accMap[accountId];
    if (a == null) {
      return [
        _Entry(
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

    final out = <_Entry>[];

    void _sortEmbyOut() {
      // ✅ Emby 排序：在列表接口补齐“加入日期/大小”后，直接复用统一排序逻辑。
      // 设计原因：
      // - 统一体验：与本地/WebDAV 排序行为保持一致；
      // - 日期：使用 Emby 的 DateCreated 作为“加入日期”参与排序；
      // - 大小：优先使用 MediaSources[0].Size（若无则为 0）。
      out.sort(_cmp);
    }

    try {
      if (path == 'favorites') {
        final items = await client.listFavorites();
        if (items.isNotEmpty) {
          for (final it in items) {
            final cover = client.bestCoverUrl(
              it,
              maxWidth: _active.viewMode == ViewMode.grid ? 420 : 220,
            );

            // ✅ 目录优先判定，避免 PhotoAlbum / UserView 等被当成图片
            final isDir = _embyTypeIsDir(it.type);
            final isImg = _embyTypeIsImage(it.type);

            out.add(
              _Entry(
                isDir: isDir,
                name: it.name.isEmpty ? '未命名' : it.name,
                size: isDir ? 0 : it.size,
                // ✅ Emby 日期排序增强：优先 DateCreated（加入库时间），兜底 DateModified。
                modified: it.dateCreated ??
                    it.dateModified ??
                    DateTime.fromMillisecondsSinceEpoch(0),
                typeKey: isDir
                    ? 'emby_folder'
                    : (isImg ? 'emby_image' : 'emby_video'),
                origin: null,
                embyAccountId: accountId,
                embyItemId: it.id,
                embyCoverUrl: cover,
              ),
            );
          }
          _sortEmbyOut();
          return out;
        }

        // favorites empty -> show views
        final views = await client.listViews();
        if (views.isEmpty) {
          out.add(
            _Entry(
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

        for (final v in views) {
          out.add(
            _Entry(
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
        _sortEmbyOut();
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
            _Entry(
              isDir: isDir,
              name: it.name.isEmpty ? '未命名' : it.name,
              size: isDir ? 0 : it.size,
              // ✅ Emby 日期排序增强：优先 DateCreated（加入库时间），兜底 DateModified。
              modified: it.dateCreated ??
                  it.dateModified ??
                  DateTime.fromMillisecondsSinceEpoch(0),
              typeKey:
                  isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
              origin: null,
              embyAccountId: a.id,
              embyItemId: it.id,
              embyCoverUrl: cover,
            ),
          );
        }
        _sortEmbyOut();
        return out;
      }

      // fallback
      final items = await client.listFavorites();
      for (final it in items) {
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
            // ✅ Emby 日期排序增强：优先 DateCreated（加入库时间），兜底 DateModified。
            modified: it.dateCreated ??
                it.dateModified ??
                DateTime.fromMillisecondsSinceEpoch(0),
            typeKey:
                isDir ? 'emby_folder' : (isImg ? 'emby_image' : 'emby_video'),
            origin: null,
            embyAccountId: accountId,
            embyItemId: it.id,
            embyCoverUrl: cover,
          ),
        );
      }
      _sortEmbyOut();
      return out;
    } catch (e) {
      out.add(
        _Entry(
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

  Widget _webDavThumb(_Entry e) {
    if (e.isDir) return const _FolderPreviewBox();

    final accId = e.wdAccountId;
    if (accId == null) return const _CoverPlaceholder();

    final acc = _wdAccMap[accId];
    if (acc == null) return const _CoverPlaceholder();

    final client = _wdClientMap[accId] ?? WebDavClient(acc);

    // Prefer stored href (absolute or relative) when available; otherwise build from relPath
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
          // ✅ 修正：使用新方法名 + Duration.zero
          return ThumbCache.getOrCreateVideoPreviewFrame(
              cached.path, Duration.zero);
        }
        if (!_wdAutoVideoThumb) return null;
        return _getWebDavVideoThumbFile(client, href, e.name,
            maxBytes: _wdVideoThumbMaxBytes, expectedSize: e.size);
      });

      return FutureBuilder<File?>(
          future: fut,
          builder: (_, snap) {
            if (snap.data != null) {
              return _ProportionalPreviewBox(
                  child: Image.file(snap.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _VideoPlaceholder()));
            }
            return const _VideoPlaceholder();
          });
    }

    return const _CoverPlaceholder();
  }

  bool _isMediaName(String name) => _isImgName(name) || _isVidName(name);

  /// ✅ 原有：本地文件夹递归查找封面
  Future<_CoverInfo?> _findCoverInDir(String dirPath) async {
    const maxScan = 2500;
    var scanned = 0;

    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return null;

      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        scanned++;
        if (scanned > maxScan) break;

        if (ent is File) {
          final name = ent.path.split(Platform.pathSeparator).last;
          if (!_isMediaName(name)) continue;

          final isVideo = _isVidName(name);
          return _CoverInfo.local(ent.path, isVideo: isVideo);
        }
      }
    } catch (_) {}
    return null;
  }

  /// ✅ 新增：WebDAV文件夹递归查找封面【和本地逻辑完全一致】
  Future<_CoverInfo?> _findCoverInWebDavDir(
      String accountId, String relPath) async {
    const maxScan = 2500;
    var scanned = 0;
    try {
      final accs = await _loadWebDavAccountsMapShared();
      final acc = accs[accountId];
      if (acc == null) return null;
      final client = WebDavClient(acc);

      // 递归查找逻辑
      final queue = <String>[relPath];
      while (queue.isNotEmpty && scanned < maxScan) {
        final curRel = queue.removeAt(0);
        final list = await client.list(curRel);
        for (final item in list) {
          scanned++;
          if (scanned > maxScan) break;
          if (item.isDir) {
            var childRel = item.relPath;
            if (!childRel.endsWith('/')) childRel = '$childRel/';
            queue.add(childRel);
          } else {
            if (_isMediaName(item.name)) {
              return _CoverInfo.webdav(
                wdAccountId: accountId,
                wdRelPath: item.relPath,
                wdHref: item.href, // 关键：用真实 href
                isVideo: _isVidName(item.name),
              );
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// ✅ 带 TTL 的文件夹封面结果获取（Local/WebDAV/Emby 都适用）
  Future<_CoverInfo?> _getFolderCoverInfo(_Entry e) async {
    if (!e.isDir) return null;
    final key = _folderCoverCacheKey(e);

    final cache = _folderCoverCache;
    final cached =
        (cache == null || key.isEmpty) ? null : cache.getIfFresh(key);
    if (cached != null) return cached;

    // 同一目录并发去重
    final fut = _dirCoverJobs.putIfAbsent(key, () async {
      _CoverInfo? info;

      if (e.isEmby) {
        // ✅ Emby 子目录封面：按 Emby 行为递归取“第一张图片”作为封面
        // 说明：
        // - 仅靠 /Items/{Id}/Images/Primary 对“自动生成封面”的目录经常返回 404，导致列表没封面
        // - 因此这里用 API：/Users/{UserId}/Items?ParentId=...&Recursive=true&IncludeItemTypes=Photo&Limit=1
        final accMap = await _loadEmbyAccountsMap();
        final a = accMap[e.embyAccountId ?? ''];
        if (a != null && (e.embyItemId ?? '').trim().isNotEmpty) {
          try {
            final client = EmbyClient(a);
            final auto = await client.pickAutoFolderCoverUrl(
              folderId: e.embyItemId!.trim(),
              maxWidth: 420,
              quality: 85,
              fallbackToVideo: true,
            );
            // ⚠️ 注意：e.embyCoverUrl 可能是目录自身 Primary（无 tag）——这类 URL 在“自动生成封面目录”上经常 404。
            // 因此只有当原 URL 明确带 tag（或你确认它可用）时才回落使用。
            final fallback = (e.embyCoverUrl ?? '').trim();
            final safeFallback = fallback.contains('tag=') ? fallback : '';
            final useUrl =
                (auto ?? '').trim().isNotEmpty ? auto!.trim() : safeFallback;
            if (useUrl.isNotEmpty) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: useUrl);
            }
          } catch (_) {
            // 忽略网络/权限错误，回落到原有 url
            final url = (e.embyCoverUrl ?? '').trim();
            if (url.isNotEmpty && url.contains('tag=')) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: url);
            }
          }
        } else {
          final url = (e.embyCoverUrl ?? '').trim();
          if (url.isNotEmpty && url.contains('tag=')) {
            info = _CoverInfo.emby(
                embyAccountId: e.embyAccountId ?? '', embyCoverUrl: url);
          }
        }
      } else if (e.isWebDav) {
        final accId = e.wdAccountId;
        var rel = e.wdRelPath;
        if (accId != null && rel != null) {
          rel = _normWebDavDirRel(rel);
          info = await _findCoverInWebDavDir(accId, rel);
        }
      } else {
        final dir = (e.localPath ?? '').trim();
        if (dir.isNotEmpty) info = await _findCoverInDir(dir);
      }

      if (info != null && cache != null && key.isNotEmpty) {
        // ignore: unawaited_futures
        cache.put(key, info);
      }
      return info;
    });

    try {
      return await fut;
    } finally {
      _dirCoverJobs.remove(key);
    }
  }

  /// ✅ 核心改造：重命名+兼容本地+WebDAV 文件夹封面加载

  Widget _embyFolderThumb(_Entry e) {
    final url = e.embyCoverUrl;
    if (url != null && url.trim().isNotEmpty) {
      return _ProportionalPreviewBox(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
                child: Icon(Icons.video_library_outlined, size: 28)),
          ),
        ),
      );
    }

    // fallback icon
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Icon(Icons.video_library_outlined, size: 28),
      ),
    );
  }

  /// ✅ 兼容本地 + WebDAV + Emby 的文件夹封面
  /// - Local：递归查找首个媒体文件作为封面
  /// - WebDAV：递归查找首个媒体文件作为封面
  /// - Emby：用统一的库图标占位（收藏列表里每个条目会有自己的封面）
  Widget _entryDirThumb(_Entry e) {
    if (!e.isDir) return const _CoverPlaceholder();

    // ✅ 统一：先读“结果缓存（带 TTL）”，miss 才实际扫描/请求
    return FutureBuilder<_CoverInfo?>(
      future: _getFolderCoverInfo(e),
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) {
          // Emby folder：没有封面时用专用占位
          if (e.isEmby) return _embyFolderThumb(e);
          return const _FolderCoverPlaceholder();
        }

        if (info.source == 'emby') {
          // 直接用缓存的 embyCoverUrl
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
          final mockEntry = _Entry(
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

        // local
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

  bool _isImageEntry(_Entry e) {
    if (e.isDir) return false;
    if (e.typeKey == 'emby_image') return true;
    if (e.isEmby) return false;
    if (e.isWebDav) return _isImgName(e.name);
    if (e.localPath != null) return _isImg(e.localPath!);
    return _isImgName(e.name);
  }

  String _entryKindLabel(_Entry e) =>
      e.isDir ? '目录' : (_isImageEntry(e) ? '图片' : '视频');

  String _entrySubtitle(_Entry e, {required bool includeSize}) {
    final kind = _entryKindLabel(e);
    final sizePart = (!includeSize || e.isDir || e.size <= 0)
        ? kind
        : '$kind · ${_fmtSize(e.size)}';
    final showOrigin = _usingScopeSearch ? (e.origin ?? '').trim() : '';
    if (showOrigin.isEmpty) return sizePart;
    return '$sizePart · $showOrigin';
  }

  Widget _listItem(_Entry e, List<_Entry> visibleEntries, List<String> imgs,
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
          onTap: () async {
            // open edit dialog by popping back to list
            await ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
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
          onTap: () => Navigator.push(context, EmbyPage.routeNoAnim()),
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
          onTap: () => Navigator.push(context, EmbyPage.routeNoAnim()),
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
    } else if ((e.localPath ?? '').trim().isNotEmpty && _isImg(e.localPath!)) {
      leading = _ProportionalPreviewBox(
        child: Image.file(
          File(e.localPath!),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
        ),
      );
    } else if ((e.localPath ?? '').trim().isNotEmpty && _isVid(e.localPath!)) {
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
            ? Theme.of(context).colorScheme.primary.withOpacity(0.10)
            : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? BorderSide(
                  color:
                      Theme.of(context).colorScheme.primary.withOpacity(0.55),
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

  Widget _cardItem(_Entry e, List<_Entry> visibleEntries, List<String> imgs,
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
          onTap: () => Navigator.push(context, EmbyPage.routeNoAnim()),
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
      preview = _entryDirThumb(e); // ✅ 修改：调用兼容版封面方法
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
    } else if (_isImg(e.localPath!)) {
      preview = _ProportionalPreviewBox(
        child: Image.file(File(e.localPath!),
            errorBuilder: (_, __, ___) => const _CoverPlaceholder()),
      );
      badge = Icons.image_outlined;
    } else if (_isVid(e.localPath!)) {
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
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.6),
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
                          color: Colors.black.withOpacity(0.32),
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
                          color: Colors.black.withOpacity(0.35),
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

/// =========================
/// Cover preview (local: root media else child media)
/// WebDAV sources: 已支持加载预览图
/// =========================
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined));
}

class _ProportionalPreviewBox extends StatelessWidget {
  final Widget child;
  const _ProportionalPreviewBox({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: child,
      ),
    );
  }
}

class _CoverInfo {
  /// source: 'local' | 'webdav' | 'emby'
  final String source;

  // local 用
  final String? localPath;

  // webdav 用
  final String? wdAccountId;
  final String? wdRelPath; // 用于定位
  final String? wdHref; // 用于预览/下载（http(s) href）

  // emby 用
  final String? embyAccountId;
  final String? embyCoverUrl;

  final bool isVideo;

  const _CoverInfo.local(this.localPath, {required this.isVideo})
      : source = 'local',
        wdAccountId = null,
        wdRelPath = null,
        wdHref = null,
        embyAccountId = null,
        embyCoverUrl = null;

  const _CoverInfo.webdav({
    required this.wdAccountId,
    required this.wdRelPath,
    required this.wdHref,
    required this.isVideo,
  })  : source = 'webdav',
        localPath = null,
        embyAccountId = null,
        embyCoverUrl = null;

  const _CoverInfo.emby({
    required this.embyAccountId,
    required this.embyCoverUrl,
  })  : source = 'emby',
        localPath = null,
        wdAccountId = null,
        wdRelPath = null,
        wdHref = null,
        isVideo = false;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'localPath': localPath,
        'wdAccountId': wdAccountId,
        'wdRelPath': wdRelPath,
        'wdHref': wdHref,
        'embyAccountId': embyAccountId,
        'embyCoverUrl': embyCoverUrl,
        'isVideo': isVideo,
      };

  static _CoverInfo? fromJson(Map<String, dynamic> j) {
    final src = (j['source'] ?? '').toString();
    final isVideo = j['isVideo'] == true;
    if (src == 'local') {
      final p = (j['localPath'] ?? '').toString();
      if (p.trim().isEmpty) return null;
      return _CoverInfo.local(p, isVideo: isVideo);
    }
    if (src == 'webdav') {
      final acc = (j['wdAccountId'] ?? '').toString();
      final rel = (j['wdRelPath'] ?? '').toString();
      final href = (j['wdHref'] ?? '').toString();
      if (acc.trim().isEmpty || rel.trim().isEmpty || href.trim().isEmpty)
        return null;
      return _CoverInfo.webdav(
          wdAccountId: acc, wdRelPath: rel, wdHref: href, isVideo: isVideo);
    }
    if (src == 'emby') {
      final acc = (j['embyAccountId'] ?? '').toString();
      final url = (j['embyCoverUrl'] ?? '').toString();
      if (acc.trim().isEmpty || url.trim().isEmpty) return null;
      return _CoverInfo.emby(embyAccountId: acc, embyCoverUrl: url);
    }
    return null;
  }
}

/// Folder cover result cache (memory + SharedPreferences + TTL)
class _FolderCoverCache {
  _FolderCoverCache._(this._sp, {required this.ttl});
  final SharedPreferences _sp;
  final Duration ttl;
  static const String _k = 'folder_cover_cache_v1';
  final Map<String, Map<String, dynamic>> _mem =
      <String, Map<String, dynamic>>{};

  static Future<_FolderCoverCache> init(
      {Duration ttl = const Duration(hours: 12)}) async {
    final sp = await SharedPreferences.getInstance();
    final c = _FolderCoverCache._(sp, ttl: ttl);
    c._load();
    return c;
  }

  void _load() {
    final raw = _sp.getString(_k);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      for (final e in m.entries) {
        final v = e.value;
        if (v is Map) _mem[e.key] = v.cast<String, dynamic>();
      }
    } catch (_) {
      // ignore corrupted cache
    }
  }

  bool _isFresh(int tsMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - tsMs <= ttl.inMilliseconds;
  }

  _CoverInfo? getIfFresh(String key) {
    final v = _mem[key];
    if (v == null) return null;
    final ts = v['ts'];
    final cover = v['cover'];
    if (ts is! int || cover is! Map) return null;
    if (!_isFresh(ts)) return null;
    return _CoverInfo.fromJson(cover.cast<String, dynamic>());
  }

  Future<void> put(String key, _CoverInfo info) async {
    _mem[key] = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'cover': info.toJson(),
    };
    await _flush();
  }

  Future<void> invalidate(String key) async {
    _mem.remove(key);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _sp.setString(_k, jsonEncode(_mem));
    } catch (_) {
      // ignore
    }
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
            scheme.primary.withOpacity(0.10),
            scheme.secondary.withOpacity(0.08),
            scheme.tertiary.withOpacity(0.06),
          ],
        ),
      ),
      child: Center(
        child: Icon(Icons.folder_outlined,
            color: scheme.onSurface.withOpacity(0.55), size: 26),
      ),
    );
  }
}

class _FolderPreviewBox extends StatelessWidget {
  const _FolderPreviewBox();
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.folder_outlined, size: 46));
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.play_circle_outline, size: 42),
    );
  }
}

class _PreviewTarget {
  final String path;
  final bool isImage;
  const _PreviewTarget(this.path, this.isImage);
}

/// ✅ 核心改造：移除WebDAV预览屏蔽，支持WebDAV封面加载
class _MultiSourcePreview extends StatefulWidget {
  final List<String> sources;
  const _MultiSourcePreview(this.sources);

  @override
  State<_MultiSourcePreview> createState() => _MultiSourcePreviewState();
}

class _MultiSourcePreviewState extends State<_MultiSourcePreview>
    with AutomaticKeepAliveClientMixin {
  Future<_PreviewTarget?>? _future;
  Future<Map<String, WebDavAccount>>? _accFuture;
  final Map<String, Future<File>> _webDavCoverFuture = {};
  final Map<String, Future<File?>> _webDavVideoThumbFuture = {};
  final Map<String, File> _webDavCoverFile = {};
  final Map<String, File> _webDavVideoThumbFile = {};

  @override
  void initState() {
    super.initState();
    _future = _pickFromSources(widget.sources);
    // 账号/客户端全局缓存：这里只拿一个稳定的 Future，避免滚动/重建时 FutureBuilder 反复 reset。
    _accFuture = _loadWebDavAccountsMapShared();
  }

  @override
  void didUpdateWidget(covariant _MultiSourcePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSources(oldWidget.sources, widget.sources)) {
      _future = _pickFromSources(widget.sources);
    }
  }

  bool _sameSources(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.sources.isEmpty) return const _CoverPlaceholder();

    // 关键优化：Future 只创建一次，避免滚动回收/重建时反复扫描 WebDAV 与刷新封面。
    return FutureBuilder<_PreviewTarget?>(
      future: _future,
      builder: (_, s) {
        final t = s.data;
        if (t == null) return const _CoverPlaceholder();

        // WebDAV
        if (_isWebDavSource(t.path)) {
          final ref = _parseWebDavSource(t.path);
          if (ref != null && !ref.isDir) {
            return FutureBuilder<Map<String, WebDavAccount>>(
              future: _accFuture,
              builder: (_, accSnap) {
                final accMap = accSnap.data;
                if (accMap == null) return const _CoverPlaceholder();

                final acc = accMap[ref.accountId];
                if (acc == null) return const _CoverPlaceholder();

                final client =
                    WebDavManager.instance.getClient(ref.accountId) ??
                        WebDavClient(acc);
                final href = client.resolveRel(ref.relPath).toString();

                // WebDAV 图片：使用【持久化封面缓存】避免滚动回收后再次走网络。
                if (t.isImage) {
                  final cached = _webDavCoverFile[href];
                  if (cached != null && cached.existsSync()) {
                    return _ProportionalPreviewBox(
                      child: Image.file(
                        cached,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
                      ),
                    );
                  }
                  final coverFuture = _webDavCoverFuture.putIfAbsent(
                    href,
                    () => client
                        .ensureCoverCached(href, p.basename(ref.relPath))
                        .then((f) {
                      // 记录已完成的文件，后续滚动回来可同步显示，避免 FutureBuilder 一帧白闪。
                      _webDavCoverFile[href] = f;
                      return f;
                    }),
                  );
                  return FutureBuilder<File>(
                    future: coverFuture,
                    builder: (_, snap) {
                      final f = snap.data;
                      if (f != null && f.existsSync()) {
                        return _ProportionalPreviewBox(
                          child: Image.file(
                            f,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const _CoverPlaceholder(),
                          ),
                        );
                      }
                      return const _CoverPlaceholder();
                    },
                  );
                }

                // WebDAV 视频：走 Scheme A（prefix 抽帧，失败再全量）
                final cachedV = _webDavVideoThumbFile[href];
                if (cachedV != null &&
                    cachedV.existsSync() &&
                    cachedV.lengthSync() > 0) {
                  return _ProportionalPreviewBox(
                    child: Image.file(
                      cachedV,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                    ),
                  );
                }
                final vFuture = _webDavVideoThumbFuture.putIfAbsent(
                  href,
                  () => _getWebDavVideoThumbFile(
                    client,
                    href,
                    p.basename(ref.relPath),
                    maxBytes: 12 * 1024 * 1024,
                  ).then((f) {
                    if (f != null) _webDavVideoThumbFile[href] = f;
                    return f;
                  }),
                );
                return FutureBuilder<File?>(
                  future: vFuture,
                  builder: (_, snap) {
                    final f = snap.data;
                    if (f != null && f.existsSync() && f.lengthSync() > 0) {
                      return _ProportionalPreviewBox(
                        child: Image.file(
                          f,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const _VideoPlaceholder(),
                        ),
                      );
                    }
                    return const _VideoPlaceholder();
                  },
                );
              },
            );
          }
        }

        // 本地资源原有逻辑
        return t.isImage
            ? _ProportionalPreviewBox(
                child: Image.file(File(t.path),
                    errorBuilder: (_, __, ___) => const _CoverPlaceholder()),
              )
            : FutureBuilder<File?>(
                future: ThumbCache.getOrCreateVideoPreviewFrame(
                    t.path, Duration.zero),
                builder: (_, snap) {
                  final f = snap.data;
                  if (f != null && f.existsSync() && f.lengthSync() > 0) {
                    return _ProportionalPreviewBox(
                      child: Image.file(
                        f,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                      ),
                    );
                  }
                  return const _VideoPlaceholder();
                },
              );
      },
    );
  }

  Future<_PreviewTarget?> _pickFromSources(List<String> sources) async {
    for (final s in sources) {
      if (_isWebDavSource(s)) {
        final target = await _pickFromWebDavSource(s);
        if (target != null) return target;
      } else {
        final target = await _pickFromFolder(s);
        if (target != null) return target;
      }
    }
    return null;
  }

  /// ✅ 新增：从WebDAV来源中查找封面
  Future<_PreviewTarget?> _pickFromWebDavSource(String source) async {
    final ref = _parseWebDavSource(source);
    if (ref == null || !ref.isDir) return null;

    final accMap = await _loadWebDavAccountsMapShared();
    final acc = accMap[ref.accountId];
    if (acc == null) return null;

    final client = WebDavClient(acc);

    const preferredCoverNames = <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
      'folder.jpg',
      'folder.jpeg',
      'folder.png',
      'folder.webp',
      'thumb.jpg',
      'thumb.jpeg',
      'thumb.png',
      'thumb.webp',
      'poster.jpg',
      'poster.jpeg',
      'poster.png',
      'poster.webp',
    ];

    // ✅ 先做“首层快速选择”，避免 WebDAV 大目录 BFS 导致卡顿
    var start = ref.relPath;
    if (start.isNotEmpty && !start.endsWith('/')) start = '$start/';

    const maxFirst = 350;
    const maxFirstDirs = 80;

    WebDavItem? firstImage;
    WebDavItem? firstVideo;
    final firstDirs = <String>[];

    try {
      final list = await client.list(start);
      var seen = 0;
      for (final item in list) {
        if (seen++ >= maxFirst) break;

        if (item.isDir) {
          var child = item.relPath;
          if (!child.endsWith('/')) child = '$child/';
          if (firstDirs.length < maxFirstDirs) firstDirs.add(child);
          continue;
        }

        final name = (item.name).toLowerCase();

        // 1) 命名封面文件优先
        if (preferredCoverNames.contains(name) && _isImgName(item.name)) {
          return _PreviewTarget(
              _buildWebDavSource(ref.accountId, item.relPath, isDir: false),
              true);
        }

        // 2) 兜底：首层第一张图片 / 第一条视频
        if (firstImage == null && _isImgName(item.name)) firstImage = item;
        if (firstVideo == null && _isVidName(item.name)) firstVideo = item;
      }
    } catch (_) {
      // ignore
    }

    if (firstImage != null) {
      return _PreviewTarget(
          _buildWebDavSource(ref.accountId, firstImage!.relPath, isDir: false),
          true);
    }
    if (firstVideo != null) {
      return _PreviewTarget(
          _buildWebDavSource(ref.accountId, firstVideo!.relPath, isDir: false),
          false);
    }

    // 3) 有限 BFS：先图后视频（限制扫描数量，避免列表滚动时卡顿）
    const maxScan = 900;
    const maxDepth = 2;

    var scanned = 0;
    var depth = 0;
    var cur = List<String>.from(firstDirs);

    WebDavItem? fallbackVideo;

    try {
      while (cur.isNotEmpty && scanned < maxScan && depth < maxDepth) {
        final next = <String>[];

        // pass A: images
        for (final dirRel in cur) {
          if (scanned >= maxScan) break;
          final list = await client.list(dirRel);
          for (final item in list) {
            scanned++;
            if (scanned > maxScan) break;

            if (item.isDir) {
              var child = item.relPath;
              if (!child.endsWith('/')) child = '$child/';
              next.add(child);
              continue;
            }

            if (_isImgName(item.name)) {
              return _PreviewTarget(
                  _buildWebDavSource(ref.accountId, item.relPath, isDir: false),
                  true);
            }

            if (fallbackVideo == null && _isVidName(item.name)) {
              fallbackVideo = item;
            }
          }
        }

        // pass B: videos (only if no image found)
        if (fallbackVideo != null) {
          return _PreviewTarget(
              _buildWebDavSource(ref.accountId, fallbackVideo!.relPath,
                  isDir: false),
              false);
        }

        cur = next;
        depth++;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {}

    return null;
  }

  Future<_PreviewTarget?> _pickFromFolder(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return null;

    // ✅ 优先策略：命名封面文件 → 首层图片 → 首层视频 → 再做有限深度的 BFS
    const preferredCoverNames = <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
      'folder.jpg',
      'folder.jpeg',
      'folder.png',
      'folder.webp',
      'thumb.jpg',
      'thumb.jpeg',
      'thumb.png',
      'thumb.webp',
      'poster.jpg',
      'poster.jpeg',
      'poster.png',
      'poster.webp',
    ];

    const maxFirstEntries = 400; // 首层最多扫描多少个条目（防止超大目录卡顿）
    const maxFirstSubDirs = 60;

    File? firstImage;
    File? firstVideo;
    final firstLevelDirs = <Directory>[];

    try {
      var seen = 0;
      await for (final e in dir.list(followLinks: false)) {
        if (seen++ >= maxFirstEntries) break;

        if (e is File) {
          final name = p.basename(e.path).toLowerCase();

          // 1) 目录下存在 cover.xxx / folder.xxx 等，直接作为封面
          if (preferredCoverNames.contains(name) && _isImg(e.path)) {
            return _PreviewTarget(e.path, true);
          }

          // 2) 兜底：记住首层第一张图片 / 第一条视频（保持“稳定封面”，不随排序变化太大）
          if (firstImage == null && _isImg(e.path)) {
            firstImage = e;
          } else if (firstVideo == null && _isVid(e.path)) {
            firstVideo = e;
          }
        } else if (e is Directory) {
          if (firstLevelDirs.length < maxFirstSubDirs) firstLevelDirs.add(e);
        }
      }
    } catch (_) {
      // ignore
    }

    if (firstImage != null) return _PreviewTarget(firstImage!.path, true);
    if (firstVideo != null) return _PreviewTarget(firstVideo!.path, false);

    // 3) 有限深度 BFS：先找图片，再找视频（限制 folder/file 数量，避免列表滚动时卡顿）
    const maxDepth = 2, maxFolders = 40, maxFiles = 800;

    var depth = 0, folders = 0, files = 0;
    var cur = List<Directory>.from(firstLevelDirs);

    while (cur.isNotEmpty &&
        depth < maxDepth &&
        folders < maxFolders &&
        files < maxFiles) {
      final next = <Directory>[];

      // pass A: images
      for (final d in cur) {
        if (folders >= maxFolders || files >= maxFiles) break;
        folders++;
        try {
          await for (final e in d.list(followLinks: false)) {
            if (files >= maxFiles) break;
            if (e is File) {
              files++;
              if (_isImg(e.path)) return _PreviewTarget(e.path, true);
            } else if (e is Directory) {
              next.add(e);
            }
          }
        } catch (_) {
          continue;
        }
      }

      // pass B: videos
      for (final d in cur) {
        if (files >= maxFiles) break;
        try {
          await for (final e in d.list(followLinks: false)) {
            if (files >= maxFiles) break;
            if (e is File) {
              files++;
              if (_isVid(e.path)) return _PreviewTarget(e.path, false);
            }
          }
        } catch (_) {
          continue;
        }
      }

      cur = next;
      depth++;
      // 让出事件循环，避免长时间占用 UI
      await Future<void>.delayed(Duration.zero);
    }

    return null;
  }
}

/// =========================
/// No-animation dialogs / menus
/// =========================
Future<T?> _panel<T>(BuildContext context, Widget child,
    {Color barrier = Colors.black26}) {
  return showAdaptivePanel<T>(
    context: context,
    child: child,
    barrierColor: barrier,
    barrierLabel: 'panel',
  );
}

Future<String?> _textInput(BuildContext context,
    {required String title, required String hint, String? initial}) {
  final c = TextEditingController(text: initial ?? '');
  return _panel<String>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
                controller: c,
                autofocus: true,
                decoration: InputDecoration(hintText: hint),
                onSubmitted: (_) => Navigator.pop(context, c.text.trim())),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, c.text.trim()),
                  child: const Text('确定')),
            ]),
          ]),
        ),
      ),
    ),
  );
}

Future<bool> _confirm(BuildContext context,
    {required String title, required String message}) async {
  final res = await _panel<bool>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(message),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确定')),
            ]),
          ]),
        ),
      ),
    ),
  );
  return res ?? false;
}

// =========================
// Local file edit helpers (Favorites)
// =========================
Future<bool> _deleteLocalFileWithConfirm(
    BuildContext context, String filePath) async {
  final name = p.basename(filePath);
  final ok = await _confirm(
    context,
    title: '删除文件',
    message: '确定删除本地文件：\n$name\n\n此操作不可恢复。',
  );
  if (!ok) return false;
  try {
    final f = File(filePath);
    if (!await f.exists()) return false;
    await f.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Pick files and copy into targetDir (no move). Returns copied count.
Future<int> _addFilesToDir(String targetDir) async {
  final dir = Directory(targetDir);
  if (!await dir.exists()) return 0;

  final res = await FilePicker.platform.pickFiles(
    dialogTitle: '选择要添加的文件（将复制到当前目录）',
    allowMultiple: true,
    type: FileType.custom,
    allowedExtensions:
        [..._imgExts, ..._vidExts].map((e) => e.substring(1)).toList(),
  );
  if (res == null || res.files.isEmpty) return 0;

  int ok = 0;
  for (final f in res.files) {
    final srcPath = f.path;
    if (srcPath == null) continue;
    final src = File(srcPath);
    if (!await src.exists()) continue;

    final base = p.basename(srcPath);
    var dst = p.join(targetDir, base);

    if (await File(dst).exists()) {
      final name = p.basenameWithoutExtension(base);
      final ext = p.extension(base);
      int i = 1;
      while (await File(dst).exists()) {
        dst = p.join(targetDir, '$name($i)$ext');
        i++;
      }
    }

    try {
      await src.copy(dst);
      ok++;
    } catch (_) {}
  }
  return ok;
}

class _CtxItem<T> {
  final T value;
  final String label;
  final IconData icon;
  const _CtxItem(this.value, this.label, this.icon);
}

Future<T?> _ctxMenu<T>(
    BuildContext context, Offset pos, List<_CtxItem<T>> items) {
  // App-friendly: full-screen bottom sheet style, no animation.
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'ctx',
    barrierColor: Colors.black54,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, __) {
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Theme.of(ctx).colorScheme.surface,
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height,
              width: double.infinity,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('选择操作',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (c, i) {
                        final it = items[i];
                        return ListTile(
                          leading: Icon(it.icon),
                          title: Text(it.label),
                          onTap: () => Navigator.of(ctx).pop(it.value),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<T?> _picker<T>(
  BuildContext context, {
  required String title,
  required T current,
  required List<T> options,
  required String Function(T) labelOf,
  required IconData Function(T) iconOf,
}) {
  Widget optionsBody(BuildContext ctx) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        for (final o in options)
          InkWell(
            onTap: () => Navigator.of(ctx).pop(o),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Icon(iconOf(o), size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(labelOf(o))),
                if (o == current) const Icon(Icons.check, size: 18),
              ]),
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }

  if (isCompactWidth(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final insets = MediaQuery.of(ctx).viewInsets;
        final maxH = (size.height * 0.58).clamp(220.0, 420.0);
        final estimated = options.length * 52.0 + 80.0;
        final h = estimated.clamp(180.0, maxH);
        return AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: SizedBox(
            height: h,
            child: optionsBody(ctx),
          ),
        );
      },
    );
  }

  return _panel<T>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: optionsBody(context),
      ),
    ),
  );
}

/// Edit sources (no animation). Returns a fully updated FavoriteCollection.
/// - Added: WebDAV source add (root/dir/file)
Future<FavoriteCollection?> _editSourcesDialog(
    BuildContext context, FavoriteCollection c) {
  final work = c.copy();
  return showAdaptivePanel<FavoriteCollection>(
    context: context,
    barrierColor: Colors.black26,
    barrierLabel: 'edit',
    child: StatefulBuilder(builder: (ctx2, setState) {
      Future<void> addLocal() async {
        final dir = await FilePicker.platform
            .getDirectoryPath(dialogTitle: '选择要加入的文件夹');
        if (dir == null) return;
        final norm = p.normalize(dir);
        if (!work.sources.contains(norm))
          setState(() => work.sources.add(norm));
      }

      Future<void> addWebDav() async {
        final src = await WebDavPickSourcePage.pick(context);
        if (src == null) return;
        if (!work.sources.contains(src)) setState(() => work.sources.add(src));
      }

      Future<void> addEmby() async {
        final src = await EmbyPickSourcePage.pick(context);
        if (src == null) return;
        if (!work.sources.contains(src)) setState(() => work.sources.add(src));
      }

      void rm(String s) => setState(() => work.sources.remove(s));

      return Center(
        child: Material(
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                child: Row(children: [
                  Expanded(
                      child: Text('编辑收藏夹：${work.name}',
                          style: Theme.of(ctx2).textTheme.titleMedium)),
                  IconButton(
                      onPressed: addLocal,
                      tooltip: '添加本地文件夹',
                      icon: const Icon(Icons.create_new_folder_outlined)),
                  IconButton(
                      onPressed: addWebDav,
                      tooltip: '添加 WebDAV（本体/目录/文件）',
                      icon: const Icon(Icons.cloud_outlined)),
                  IconButton(
                      onPressed: addEmby,
                      tooltip: '添加 Emby（收藏）',
                      icon: const Icon(Icons.video_library_outlined)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: work.sources.isEmpty
                    ? const Center(
                        child: Text('还没有添加来源。\n右上角按钮可添加本地或 WebDAV。',
                            textAlign: TextAlign.center))
                    : ListView.separated(
                        itemCount: work.sources.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = work.sources[i];
                          final isWd = _isWebDavSource(s);
                          final isEmby = _isEmbySource(s);
                          final title = (isWd || isEmby)
                              ? s
                              : (p.basename(s).isEmpty ? s : p.basename(s));
                          final subtitle =
                              isWd ? 'WebDAV' : (isEmby ? 'Emby' : s);
                          return ListTile(
                            leading: Icon(
                              isWd
                                  ? Icons.cloud_outlined
                                  : (isEmby
                                      ? Icons.video_library_outlined
                                      : Icons.folder_outlined),
                            ),
                            title: Text(title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(subtitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                                onPressed: () => rm(s),
                                tooltip: '移除',
                                icon: const Icon(Icons.close)),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx2),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx2, work),
                      child: const Text('保存')),
                ]),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

// =========================
// Hidden Tag Filter helpers
// =========================

class _ActiveTagBanner extends StatelessWidget {
  final String tagId;
  final VoidCallback onClear;

  const _ActiveTagBanner({required this.tagId, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final tag = TagStore.I.tagById(tagId);
    final name = tag?.name ?? tagId;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withOpacity(0.6))),
        ),
        child: Row(
          children: [
            const Icon(Icons.filter_alt_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已筛选：$name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('清除'),
            ),
          ],
        ),
      ),
    );
  }
}

extension _TagStoreLookupX on TagStore {
  Tag? tagById(String id) {
    for (final t in allTags) {
      if (t.id == id) return t;
    }
    return null;
  }
}
