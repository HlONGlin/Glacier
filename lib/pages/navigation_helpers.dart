import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/favorite_models.dart';
import '../pages.dart' show FolderDetailPage;
import 'folder_detail_models.dart';
import 'media_helpers.dart';

typedef OpenFolderFromSource = Future<void> Function(
  BuildContext context, {
  required String title,
  required String source,
});

Future<void> openTagSourceAsFolder(
  BuildContext context, {
  required String title,
  required String source,
}) async {
  final normalizedTitle = title.trim().isEmpty ? 'Tag 目录' : title.trim();
  NavCtx? nav;
  if (isPageEmbySource(source)) {
    final ref = parsePageEmbySource(source);
    if (ref != null) {
      nav = NavCtx.emby(
        embyAccountId: ref.accountId,
        embyPath: ref.path.trim().isEmpty ? 'favorites' : ref.path.trim(),
        title: normalizedTitle,
      );
    }
  } else if (isPageWebDavSource(source)) {
    final ref = parsePageWebDavSource(source);
    if (ref != null) {
      var rel = ref.relPath;
      if (ref.isDir && rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
      nav = NavCtx.webdav(
        wdAccountId: ref.accountId,
        wdRel: rel,
        title: normalizedTitle,
      );
    }
  } else {
    var dir = source.trim();
    if (dir.isNotEmpty) {
      try {
        final fileType = FileSystemEntity.typeSync(dir, followLinks: false);
        if (fileType != FileSystemEntityType.directory) {
          dir = p.dirname(dir);
        }
      } catch (_) {
        dir = p.dirname(dir);
      }
      if (dir.trim().isNotEmpty) {
        nav = NavCtx.local(dir.trim(), title: normalizedTitle);
      }
    }
  }
  final collection = FavoriteCollection(
    id: '_tmp_tag_${DateTime.now().millisecondsSinceEpoch}',
    name: normalizedTitle,
    sources: [source],
    layer1: LayerSettings(viewMode: ViewMode.gallery),
    layer2: LayerSettings(viewMode: ViewMode.list),
  );
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => FolderDetailPage(
        collection: collection,
        initialNav: nav,
        exitOnInitialContextBack: true,
      ),
    ),
  );
}
