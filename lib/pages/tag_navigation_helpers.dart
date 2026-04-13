import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../emby.dart';
import '../image.dart';
import '../sources/refs.dart';
import '../video.dart';
import '../webdav.dart';
import '../tag/tag_models.dart';
import 'tag_source_helpers.dart';

typedef OpenTagFolderCallback = Future<void> Function(
  BuildContext context, {
  required String title,
  required String source,
});

/// Tag 管理页/详情页点击条目时，复用现有页面打开逻辑。
/// - 本地：图片/视频跳到 viewer；其它文件：提示路径（避免引入平台相关打开插件）
/// - WebDAV：图片/视频跳到 viewer；其它文件：下载到用户选择目录
Future<void> openTagTarget(
  BuildContext context,
  TagTargetMeta meta, {
  required OpenTagFolderCallback openFolder,
}) async {
  if (tagMetaIsEmby(meta)) {
    final ref = parseTagEmbyRef(meta);
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
      if (!context.mounted) return;
      await openFolder(
        context,
        title: meta.name,
        source: buildEmbySource(account.id, 'view:$folderId'),
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
    final isDirByApi = itemType.isNotEmpty && tagEmbyTypeIsDir(itemType);
    final isImageByApi = itemType.isNotEmpty && tagEmbyTypeIsImage(itemType);
    final isImageByMeta = meta.kind == TagKind.image;
    final isVideoByMeta = meta.kind == TagKind.video;

    Future<bool> tryOpenSingleImage() async {
      final single = buildEmbySource(account.id, 'item:$itemId').trim();
      if (single.isEmpty) return false;
      final aspectRatios = <double?>[
        current?.primaryImageAspectRatio,
      ];
      if (!context.mounted) return true;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            imagePaths: [single],
            initialIndex: 0,
            sourceKeys: [single],
            sourceAspectRatios: aspectRatios,
          ),
        ),
      );
      return true;
    }

    if (!isDirByApi && !meta.isDir && itemType.isEmpty) {
      try {
        final selfChildren = await client.listChildren(parentId: itemId);
        if (selfChildren.isNotEmpty) {
          if (!context.mounted) return;
          await openFolder(
            context,
            title: meta.name,
            source: buildEmbySource(account.id, 'view:$itemId'),
          );
          return;
        }
      } catch (_) {}
    }

    if (isDirByApi || meta.isDir) {
      if (!context.mounted) return;
      await openFolder(
        context,
        title: (current != null && current.name.isNotEmpty)
            ? current.name
            : meta.name,
        source: buildEmbySource(account.id, 'view:$itemId'),
      );
      return;
    }

    if (isImageByApi || isImageByMeta) {
      final imgs = siblings
          .where(
              (it) => !tagEmbyTypeIsDir(it.type) && tagEmbyTypeIsImage(it.type))
          .toList(growable: false);
      if (imgs.isNotEmpty) {
        final imageSources = <String>[];
        final aspectRatios = <double?>[];
        var idx = 0;
        for (final it in imgs) {
          final source = buildEmbySource(account.id, 'item:${it.id}').trim();
          if (source.isEmpty) continue;
          if (it.id == itemId) idx = imageSources.length;
          imageSources.add(source);
          aspectRatios.add(it.primaryImageAspectRatio);
        }
        if (imageSources.isNotEmpty) {
          if (!context.mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImageViewerPage(
                imagePaths: imageSources,
                initialIndex: idx.clamp(0, imageSources.length - 1),
                sourceKeys: imageSources,
                sourceAspectRatios: aspectRatios,
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
          if (!context.mounted) return;
          await openFolder(
            context,
            title: meta.name,
            source: buildEmbySource(account.id, 'view:$itemId'),
          );
          return;
        }
      } catch (_) {
        if (await tryOpenSingleImage()) return;
        if (!context.mounted) return;
        await openFolder(
          context,
          title: meta.name,
          source: buildEmbySource(account.id, 'view:$itemId'),
        );
        return;
      }
    }

    if (isVideoByMeta || !isImageByApi && !isImageByMeta) {
      final vids = siblings
          .where((it) =>
              !tagEmbyTypeIsDir(it.type) && !tagEmbyTypeIsImage(it.type))
          .toList(growable: false);

      final paths = vids.map((it) {
        final nm = it.name.trim().isEmpty ? meta.name : it.name.trim();
        return buildEmbySource(account.id, 'item:${it.id}', name: nm);
      }).toList(growable: false);
      final idx = vids.indexWhere((it) => it.id == itemId);

      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            videoPaths: paths.isEmpty
                ? [buildEmbySource(account.id, 'item:$itemId', name: meta.name)]
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

  if (!tagMetaIsWebDav(meta)) {
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
      await openFolder(context, title: meta.name, source: lp);
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

  final wd = parseTagWebDavRef(meta);
  final wdIsDir = wd?.isDir ?? false;
  if (wd != null && (meta.isDir || wdIsDir)) {
    var rel = wd.relPath.trim();
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
    await openFolder(
      context,
      title: meta.name,
      source: buildWebDavSourceWithDir(wd.accountId, rel, isDir: true),
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

Future<void> locateTagTarget(
  BuildContext context,
  TagTargetMeta meta, {
  required OpenTagFolderCallback openFolder,
}) async {
  if (tagMetaIsEmby(meta)) {
    final ref = parseTagEmbyRef(meta);
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
      if (!context.mounted) return;
      await openFolder(
        context,
        title: '定位：${meta.name}',
        source: buildEmbySource(account.id, 'view:$folderId'),
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
    if (itemType.isNotEmpty && tagEmbyTypeIsDir(itemType)) {
      if (!context.mounted) return;
      await openFolder(
        context,
        title: '定位：${meta.name}',
        source: buildEmbySource(account.id, 'view:$itemId'),
      );
      return;
    }
    try {
      final selfChildren = await client.listChildren(parentId: itemId);
      if (selfChildren.isNotEmpty) {
        if (!context.mounted) return;
        await openFolder(
          context,
          title: '定位：${meta.name}',
          source: buildEmbySource(account.id, 'view:$itemId'),
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
    if (!context.mounted) return;
    await openFolder(
      context,
      title: '定位：${meta.name}',
      source: buildEmbySource(account.id, sourcePath),
    );
    return;
  }

  if (tagMetaIsWebDav(meta)) {
    final wd = parseTagWebDavRef(meta);
    if (wd == null) return;
    var rel = wd.relPath.trim();
    if (!meta.isDir) {
      final parent = p.dirname(rel);
      rel = (parent == '.' || parent == '/') ? '' : parent;
    }
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';

    await openFolder(
      context,
      title: '定位：${meta.name}',
      source: buildWebDavSourceWithDir(wd.accountId, rel, isDir: true),
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

  await openFolder(
    context,
    title: '定位：${meta.name}',
    source: dir,
  );
}
