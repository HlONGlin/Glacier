import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/favorite_models.dart';
import 'tag_source_helpers.dart';
import '../sources/refs.dart';
import '../core/utils/app_shared.dart';
import '../emby.dart';
import '../webdav.dart';

const kPageImageExts = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

const kPageVideoExts = <String>{
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
  '.265',
};

bool isPageImagePath(String path) =>
    kPageImageExts.contains(p.extension(path).toLowerCase());

bool isPageVideoPath(String path) =>
    kPageVideoExts.contains(p.extension(path).toLowerCase());

bool isPageImageName(String name) =>
    kPageImageExts.contains(p.extension(name).toLowerCase());

bool isPageVideoName(String name) =>
    kPageVideoExts.contains(p.extension(name).toLowerCase());

String pageViewModeLabel(ViewMode viewMode) =>
    const ['列表', '画廊', '网格'][viewMode.index];

String pageSortKeyLabel(SortKey sortKey) =>
    const ['名称', '日期', '大小', '类型'][sortKey.index];

IconData pageViewModeIcon(ViewMode viewMode) => const [
      Icons.view_list,
      Icons.photo_library_outlined,
      Icons.grid_view
    ][viewMode.index];

IconData pageSortKeyIcon(SortKey sortKey) => const [
      Icons.sort_by_alpha,
      Icons.calendar_today_outlined,
      Icons.data_usage_outlined,
      Icons.category_outlined,
    ][sortKey.index];

EmbyPathSourceRef? parsePageEmbySource(String source) =>
    parseEmbySourcePath(source);

WebDavSourceRef? parsePageWebDavSource(String source) =>
    parseWebDavSourceForPage(source);

String buildPageWebDavSource(String accountId, String relPath,
        {required bool isDir}) =>
    buildWebDavSourceWithDir(accountId, relPath, isDir: isDir);

bool isPageWebDavSource(String source) => isWebDavSource(source);

bool isPageEmbySource(String source) => isEmbySource(source);

Future<Map<String, WebDavAccount>> loadPageWebDavAccountsMap() async {
  if (!WebDavManager.instance.isLoaded) {
    await WebDavManager.instance.reload(notify: false);
  }
  return WebDavManager.instance.accountsMap;
}

const Duration _kPageAccountMapReuseWindow = Duration(seconds: 12);

Future<Map<String, WebDavAccount>>? _pageWebDavAccountsMapFuture;
Map<String, WebDavAccount>? _pageWebDavAccountsMapCache;
DateTime? _pageWebDavAccountsMapCachedAt;

Future<Map<String, WebDavAccount>> loadPageWebDavAccountsMapShared() async {
  final cached = _pageWebDavAccountsMapCache;
  final cachedAt = _pageWebDavAccountsMapCachedAt;
  if (cached != null &&
      cachedAt != null &&
      DateTime.now().difference(cachedAt) <= _kPageAccountMapReuseWindow) {
    return cached;
  }

  final inFlight = _pageWebDavAccountsMapFuture;
  if (inFlight != null) return inFlight;

  final future = loadPageWebDavAccountsMap();
  _pageWebDavAccountsMapFuture = future;
  try {
    final map = await future;
    _pageWebDavAccountsMapCache = map;
    _pageWebDavAccountsMapCachedAt = DateTime.now();
    return map;
  } finally {
    if (identical(_pageWebDavAccountsMapFuture, future)) {
      _pageWebDavAccountsMapFuture = null;
    }
  }
}

Future<Map<String, EmbyAccount>>? _pageEmbyAccountsMapFuture;
Map<String, EmbyAccount>? _pageEmbyAccountsMapCache;
DateTime? _pageEmbyAccountsMapCachedAt;

Future<Map<String, EmbyAccount>> loadPageEmbyAccountsMapShared() async {
  final cached = _pageEmbyAccountsMapCache;
  final cachedAt = _pageEmbyAccountsMapCachedAt;
  if (cached != null &&
      cachedAt != null &&
      DateTime.now().difference(cachedAt) <= _kPageAccountMapReuseWindow) {
    return cached;
  }

  final inFlight = _pageEmbyAccountsMapFuture;
  if (inFlight != null) return inFlight;

  final future = EmbyStore.load().then((accounts) => <String, EmbyAccount>{
        for (final account in accounts) account.id: account,
      });
  _pageEmbyAccountsMapFuture = future;
  try {
    final map = await future;
    _pageEmbyAccountsMapCache = map;
    _pageEmbyAccountsMapCachedAt = DateTime.now();
    return map;
  } finally {
    if (identical(_pageEmbyAccountsMapFuture, future)) {
      _pageEmbyAccountsMapFuture = null;
    }
  }
}

Future<File?> getPageWebDavVideoThumbFile(
  WebDavClient client,
  String href,
  String name, {
  required int maxBytes,
  int? expectedSize,
}) async {
  File? thumb;

  try {
    final prefix =
        await client.ensureCachedForThumb(href, name, maxBytes: maxBytes);
    if (await prefix.exists() && await prefix.length() > 0) {
      thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
          prefix.path, Duration.zero);
      if (thumb != null) return thumb;
    }
  } catch (_) {}

  if (expectedSize != null && expectedSize > 0) {
    try {
      final moovInTail =
          await client.probeMoovInTail(href, fileSize: expectedSize);
      if (!moovInTail) return thumb;
    } catch (_) {}
  }

  try {
    final full =
        await client.ensureCached(href, name, expectedSize: expectedSize);
    if (await full.exists() && await full.length() > 0) {
      thumb = await ThumbCache.getOrCreateVideoPreviewFrame(
          full.path, Duration.zero);
    }
  } catch (_) {}

  return thumb;
}
