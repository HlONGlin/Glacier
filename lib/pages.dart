import 'dart:async';
import 'dart:collection';
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
import 'emby_exclusive_ui.dart';
import 'thumbnail_inspector.dart';
import 'models/favorite_models.dart';
import 'pages_tag_source_helpers.dart';
import 'stores/favorite_store.dart';

// 👇👇👇 重点修改这两行 👇👇👇
import 'utils.dart'; // 必须直接引入，去掉 "as utils"
import 'tag.dart';
import 'source_refs.dart';
// 👆👆👆 重点修改这两行 👆👆👆

part 'pages/settings_page.dart';
part 'pages/history_page.dart';
part 'pages/folder_detail_controller.dart';
part 'pages/favorites_page.dart';
part 'pages/folder_detail_models.dart';
part 'pages/folder_cover_cache.dart';
part 'pages/folder_previews.dart';
part 'pages/folder_scope_search.dart';
part 'pages/folder_entry_helpers.dart';
part 'pages/folder_navigation_helpers.dart';
part 'pages/folder_load_helpers.dart';
// ===== app_pages.dart (auto-grouped) =====

// --- from pages.dart ---

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

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

/// Tag 管理页/详情页点击条目时，复用现有页面打开逻辑。
/// - 本地：图片/视频跳到 viewer；其它文件：提示路径（避免引入平台相关打开插件）
/// - WebDAV：图片/视频跳到 viewer；其它文件：下载到用户选择目录
Future<void> openTagTarget(BuildContext context, TagTargetMeta meta) async {
  // Emby
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
      await _openTagSourceAsFolder(
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
          await _openTagSourceAsFolder(
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
      await _openTagSourceAsFolder(
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
          await _openTagSourceAsFolder(
            context,
            title: meta.name,
            source: buildEmbySource(account.id, 'view:$itemId'),
          );
          return;
        }
      } catch (_) {
        if (await tryOpenSingleImage()) return;
        if (!context.mounted) return;
        await _openTagSourceAsFolder(
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

  // Local
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
  final wd = parseTagWebDavRef(meta);
  final wdIsDir = wd?.isDir ?? false;
  if (wd != null && (meta.isDir || wdIsDir)) {
    var rel = wd.relPath.trim();
    if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
    await _openTagSourceAsFolder(
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

Future<void> locateTagTarget(BuildContext context, TagTargetMeta meta) async {
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
      await _openTagSourceAsFolder(
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
      await _openTagSourceAsFolder(
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
        await _openTagSourceAsFolder(
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
    await _openTagSourceAsFolder(
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

    await _openTagSourceAsFolder(
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

  await _openTagSourceAsFolder(
    context,
    title: '定位：${meta.name}',
    source: dir,
  );
}

Route _embyPageRouteNoAnimWithUi() {
  return EmbyPage.routeNoAnim(
    openExclusiveUi: (ctx, {Set<String>? scopedAccountIds}) {
      final scoped = scopedAccountIds
          ?.map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      return Navigator.push(
        ctx,
        MaterialPageRoute(
          builder: (_) => EmbyExclusiveFavoritesPage(
            accountIds: (scoped == null || scoped.isEmpty) ? null : scoped,
            openFolder: (openCtx, {required title, required source}) {
              return _openTagSourceAsFolder(openCtx,
                  title: title, source: source);
            },
            openSettings: (openCtx) {
              return Navigator.push(
                openCtx,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> _openEmbyPageWithUi(BuildContext context) async {
  await Navigator.push(context, _embyPageRouteNoAnimWithUi());
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

typedef _EmbyRef = EmbyPathSourceRef;
typedef _WebDavRef = WebDavSourceRef;

_EmbyRef? _parseEmbySource(String s) => parseEmbySourcePath(s);

_WebDavRef? _parseWebDavSource(String s) => parseWebDavSourceForPage(s);

String _buildWebDavSource(String accountId, String relPath,
        {required bool isDir}) =>
    buildWebDavSourceWithDir(accountId, relPath, isDir: isDir);

// 放在 const _imgExts = <String>{...} 这行代码的后面即可
extension CharExt on String {
  bool get isDigit => length == 1 && codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
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

// ===============================
// Source 前缀判断（收藏夹/多来源预览用）
//
// 设计原因：收藏夹 sources 目前用字符串存储来源，使用前缀区分类型。
// 这里做成顶层方法，方便 _CollectionCard / _MultiSourcePreview 等多个组件复用。
// ===============================
bool _isWebDavSource(String s) => isWebDavSource(s);
bool _isEmbySource(String s) => isEmbySource(s);

class _EmbyCollectionProjection {
  final FavoriteCollection base;
  final List<String> embySources;
  final List<_EmbyRef> refs;

  const _EmbyCollectionProjection({
    required this.base,
    required this.embySources,
    required this.refs,
  });

  Set<String> get accountIds => refs.map((e) => e.accountId).toSet();
}

class _EmbyOnlyFavoritesPage extends StatefulWidget {
  const _EmbyOnlyFavoritesPage();

  @override
  State<_EmbyOnlyFavoritesPage> createState() => _EmbyOnlyFavoritesPageState();
}

class _EmbyOnlyFavoritesPageState extends State<_EmbyOnlyFavoritesPage> {
  static const Color _bg = Color(0xFF0C111A);
  static const Color _panel = Color(0xFF171D2A);
  static const Color _text = Color(0xFFF2F5FF);
  static const Color _sub = Color(0xFF97A0B6);
  static const SystemUiOverlayStyle _statusStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  );

  bool _loading = true;
  Object? _loadError;
  String _query = '';
  int _tab = 0;

  List<FavoriteCollection> _allCollections = const [];
  List<_EmbyCollectionProjection> _items = const [];
  Map<String, EmbyAccount> _accountMap = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  List<_EmbyCollectionProjection> _buildProjection(
      List<FavoriteCollection> collections) {
    final out = <_EmbyCollectionProjection>[];
    for (final c in collections) {
      final embySources =
          c.sources.where((s) => _isEmbySource(s)).toList(growable: false);
      if (embySources.isEmpty) continue;
      final refs = embySources
          .map(_parseEmbySource)
          .whereType<_EmbyRef>()
          .toList(growable: false);
      if (refs.isEmpty) continue;
      out.add(_EmbyCollectionProjection(
          base: c, embySources: embySources, refs: refs));
    }
    out.sort((a, b) =>
        a.base.name.toLowerCase().compareTo(b.base.name.toLowerCase()));
    return out;
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final collections = await FavoriteStore.load();
      final embyAccs = await EmbyStore.load();
      final map = <String, EmbyAccount>{for (final a in embyAccs) a.id: a};
      if (!mounted) return;
      setState(() {
        _allCollections = collections;
        _accountMap = map;
        _items = _buildProjection(collections);
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
    }
  }

  List<_EmbyCollectionProjection> _filtered() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items.where((it) {
      if (it.base.name.toLowerCase().contains(q)) return true;
      for (final id in it.accountIds) {
        final n = (_accountMap[id]?.name ?? id).toLowerCase();
        if (n.contains(q)) return true;
      }
      return false;
    }).toList(growable: false);
  }

  Future<void> _openProjection(_EmbyCollectionProjection p) async {
    await AppSettings.setLastFavoriteId(p.base.id);
    final embyOnly = p.base.copy()..sources = List<String>.from(p.embySources);
    if (!mounted) return;
    final updated = await Navigator.push<FavoriteCollection>(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailPage(collection: embyOnly)),
    );
    if (updated == null) return;
    final idx = _allCollections.indexWhere((e) => e.id == p.base.id);
    if (idx < 0) return;
    final merged = _allCollections[idx].copy();
    merged.layer1 = updated.layer1.copy();
    merged.layer2 = updated.layer2.copy();
    merged.sources = [
      ...merged.sources.where((s) => !_isEmbySource(s)),
      ...updated.sources.where((s) => _isEmbySource(s)),
    ];
    _allCollections[idx] = merged;
    await FavoriteStore.save(_allCollections);
    await _reload();
  }

  String _headerTitle() {
    if (_accountMap.isEmpty) return 'Emby';
    if (_accountMap.length == 1) return _accountMap.values.first.name;
    return 'Emby';
  }

  Map<String, List<_EmbyCollectionProjection>> _groupByAccount(
      List<_EmbyCollectionProjection> list) {
    final out = <String, List<_EmbyCollectionProjection>>{};
    for (final it in list) {
      final names = it.accountIds
          .map((id) => (_accountMap[id]?.name ?? id).trim())
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final key = names.isEmpty ? '媒体' : names.first;
      out.putIfAbsent(key, () => <_EmbyCollectionProjection>[]).add(it);
    }
    return out;
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF252D3D),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _sub,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _headerBar() {
    return Row(
      children: [
        IconButton(
          onPressed: () {},
          icon:
              const Icon(Icons.account_circle_outlined, color: _text, size: 30),
        ),
        Expanded(
          child: Text(
            _headerTitle(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: () => _openEmbyPageWithUi(context),
          icon: const Icon(Icons.settings_outlined, color: _text),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, {VoidCallback? onMore}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: _text,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (onMore != null)
          TextButton(
            onPressed: onMore,
            child: const Text('更多', style: TextStyle(color: _sub)),
          ),
      ],
    );
  }

  Widget _cover(List<String> sources) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox.expand(child: _MultiSourcePreview(sources)),
    );
  }

  Widget _shelfCard(_EmbyCollectionProjection p, {double width = 175}) {
    final accountNames =
        p.accountIds.map((id) => _accountMap[id]?.name ?? id).toList();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openProjection(p),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.62,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _cover(p.embySources),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              p.base.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _text, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip('来源 ${p.embySources.length}'),
                if (accountNames.isNotEmpty) _chip(accountNames.first),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stateView({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onAction,
    String actionLabel = '重试',
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _sub, size: 42),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _text, fontSize: 18)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _sub, fontSize: 13)),
            if (onAction != null) ...[
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF313C56)),
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _homeTab(List<_EmbyCollectionProjection> shown) {
    final grouped = _groupByAccount(shown);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 26),
        children: [
          _headerBar(),
          const SizedBox(height: 10),
          _sectionTitle('媒体库'),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            child: shown.isEmpty
                ? const Center(
                    child: Text('暂无媒体库',
                        style: TextStyle(color: _sub, fontSize: 13)))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _shelfCard(shown[i]),
                  ),
          ),
          const SizedBox(height: 8),
          _sectionTitle('继续观看'),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text('暂无可继续观看内容',
                  style: TextStyle(color: _sub, fontSize: 13)),
            )
          else
            Row(
              children: [
                Expanded(
                    child: _shelfCard(shown.first, width: double.infinity)),
                if (shown.length > 1) ...[
                  const SizedBox(width: 10),
                  Expanded(child: _shelfCard(shown[1], width: double.infinity)),
                ],
              ],
            ),
          const SizedBox(height: 14),
          for (final entry in grouped.entries) ...[
            _sectionTitle(entry.key),
            const SizedBox(height: 8),
            SizedBox(
              height: 170,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entry.value.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _shelfCard(entry.value[i]),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _searchTab(List<_EmbyCollectionProjection> shown) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              _headerBar(),
              const SizedBox(height: 10),
              TextField(
                style: const TextStyle(color: _text),
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: _panel,
                  hintText: '搜索收藏夹或 Emby 账号',
                  hintStyle: const TextStyle(color: _sub),
                  prefixIcon: const Icon(Icons.search, color: _sub),
                  suffixIcon: _query.trim().isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => setState(() => _query = ''),
                          icon: const Icon(Icons.close, color: _sub),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? _stateView(
                  icon: Icons.search_off_outlined,
                  title: '没有匹配结果',
                  subtitle: '试试其他关键词',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final it = shown[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openProjection(it),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 96,
                                height: 60,
                                child: _MultiSourcePreview(it.embySources),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                it.base.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    const TextStyle(color: _text, fontSize: 15),
                              ),
                            ),
                            const Icon(Icons.chevron_right, color: _sub),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _favoritesTab(List<_EmbyCollectionProjection> shown) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: _headerBar(),
        ),
        Expanded(
          child: shown.isEmpty
              ? _stateView(
                  icon: Icons.star_border_rounded,
                  title: '没有 Emby 收藏',
                  subtitle: '去收藏夹里添加 Emby 来源后再回来',
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  itemCount: shown.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.95,
                  ),
                  itemBuilder: (_, i) {
                    final it = shown[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openProjection(it),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _cover(it.embySources)),
                            const SizedBox(height: 8),
                            Text(
                              it.base.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(color: _text, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    final shown = _filtered();
    final body = () {
      if (_loading) {
        return const Center(
            child: CircularProgressIndicator(color: Colors.white));
      }
      if (_loadError != null) {
        return _stateView(
          icon: Icons.cloud_off_outlined,
          title: '加载 Emby 收藏夹失败',
          subtitle: friendlyErrorMessage(_loadError!),
          onAction: _reload,
        );
      }
      if (_items.isEmpty) {
        return _stateView(
          icon: Icons.video_library_outlined,
          title: '暂无 Emby 收藏夹',
          subtitle: '请先在收藏夹里添加 Emby 来源',
          onAction: () => _openEmbyPageWithUi(context),
          actionLabel: '去 Emby 设置',
        );
      }
      switch (_tab) {
        case 1:
          return _searchTab(shown);
        case 2:
          return _favoritesTab(shown);
        default:
          return _homeTab(shown);
      }
    }();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _statusStyle,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(child: body),
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            color: _panel,
            border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
          ),
          child: SafeArea(
            top: false,
            child: BottomNavigationBar(
              backgroundColor: _panel,
              type: BottomNavigationBarType.fixed,
              currentIndex: _tab,
              selectedItemColor: _text,
              unselectedItemColor: _sub,
              selectedFontSize: 13,
              unselectedFontSize: 13,
              onTap: (i) => setState(() => _tab = i),
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined), label: '主页'),
                BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.star_outline_rounded), label: '收藏'),
              ],
            ),
          ),
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
  // ignore: library_private_types_in_public_api
  // ignore: library_private_types_in_public_api
  final _NavCtx? initialNav;
  final bool exitOnInitialContextBack;
  // ignore: library_private_types_in_public_api
  const FolderDetailPage(
      {super.key,
      required this.collection,
      this.initialNav,
      this.exitOnInitialContextBack = false});
  @override
  // ignore: library_private_types_in_public_api
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  late final FolderDetailController _controller;
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

  String get _q => _controller.query;
  set _q(String value) => _controller.query = value;

  bool get _searchExpanded => _controller.searchExpanded;
  set _searchExpanded(bool value) => _controller.searchExpanded = value;
  _FolderSearchScope _searchScope = _FolderSearchScope.currentCollection;
  String? _singleSearchCollectionId;
  List<FavoriteCollection> _searchCollections = const <FavoriteCollection>[];
  bool _searchCollectionsLoaded = false;
  bool _scopeSearching = false;
  Object? _scopeSearchError;
  List<_Entry> get _scopeSearchRaw => _controller.scopeSearchRaw;
  set _scopeSearchRaw(List<_Entry> value) => _controller.scopeSearchRaw = value;
  final Map<String, List<_Entry>> _scopeSearchCache = <String, List<_Entry>>{};
  Timer? _scopeSearchDebounce;
  int _scopeSearchToken = 0;
  static const int _maxScopeSearchResults = 400;
  String? get _selectedTagId => _controller.selectedTagId;
  set _selectedTagId(String? value) => _controller.selectedTagId = value;

  bool _tagEnabled = true; // 由设置控制，避免用户不需要时被打扰
  bool get _selectionMode => _controller.selectionMode;
  set _selectionMode(bool value) => _controller.selectionMode = value;

  Set<String> get _selectedEntryKeys => _controller.selectedEntryKeys;
  final Map<String, GlobalKey> _entryAnchorKeys = <String, GlobalKey>{};

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

  void _syncEntryAnchorKeys(List<_Entry> visibleEntries) {
    final aliveKeys = visibleEntries
        .map(_imageSourceKeyForEntry)
        .where((k) => k.trim().isNotEmpty)
        .toSet();
    _entryAnchorKeys.removeWhere((k, _) => !aliveKeys.contains(k));
  }

  int _gridCrossAxisCount({
    required double viewportWidth,
    required double horizontalPadding,
    required double maxCrossAxisExtent,
    required double crossAxisSpacing,
  }) {
    final usableWidth =
        (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
    int count = ((usableWidth + crossAxisSpacing) /
            (maxCrossAxisExtent + crossAxisSpacing))
        .floor();
    if (count < 1) count = 1;
    return count;
  }

  double _estimateScrollOffsetForIndex(int index) {
    final viewportWidth = MediaQuery.of(context).size.width;
    if (index <= 0) return 0;
    switch (_active.viewMode) {
      case ViewMode.list:
        const topPadding = 8.0;
        const estimatedItemExtent = 88.0;
        return topPadding + index * estimatedItemExtent;
      case ViewMode.gallery:
        const horizontalPadding = 12.0;
        const maxCrossAxisExtent = 420.0;
        const crossAxisSpacing = 12.0;
        const mainAxisSpacing = 12.0;
        const childAspectRatio = 1.45;
        final crossAxisCount = _gridCrossAxisCount(
          viewportWidth: viewportWidth,
          horizontalPadding: horizontalPadding,
          maxCrossAxisExtent: maxCrossAxisExtent,
          crossAxisSpacing: crossAxisSpacing,
        );
        final usableWidth =
            (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
        final tileWidth =
            (usableWidth - (crossAxisCount - 1) * crossAxisSpacing) /
                crossAxisCount;
        final tileHeight = tileWidth / childAspectRatio;
        final row = index ~/ crossAxisCount;
        return horizontalPadding + row * (tileHeight + mainAxisSpacing);
      case ViewMode.grid:
        const horizontalPadding = 12.0;
        const maxCrossAxisExtent = 220.0;
        const crossAxisSpacing = 10.0;
        const mainAxisSpacing = 10.0;
        const childAspectRatio = 0.95;
        final crossAxisCount = _gridCrossAxisCount(
          viewportWidth: viewportWidth,
          horizontalPadding: horizontalPadding,
          maxCrossAxisExtent: maxCrossAxisExtent,
          crossAxisSpacing: crossAxisSpacing,
        );
        final usableWidth =
            (viewportWidth - horizontalPadding * 2).clamp(1.0, 20000.0);
        final tileWidth =
            (usableWidth - (crossAxisCount - 1) * crossAxisSpacing) /
                crossAxisCount;
        final tileHeight = tileWidth / childAspectRatio;
        final row = index ~/ crossAxisCount;
        return horizontalPadding + row * (tileHeight + mainAxisSpacing);
    }
  }

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
        // ignore: unawaited_futures
        _maybeLocateAfterImageViewer(key);
      });
      return;
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    final roughOffset =
        _estimateScrollOffsetForIndex(index).clamp(0.0, maxExtent);
    try {
      _scrollController.jumpTo(roughOffset);
    } catch (_) {
      // ignored
    }
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

  bool _isEntrySelected(_Entry e) =>
      _controller.isSelected(e, keyOf: _entrySelectionKey);

  void _clearSelection() {
    _controller.clearSelection();
  }

  void _toggleSelection(_Entry e) {
    _controller.toggleSelection(e, keyOf: _entrySelectionKey);
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
    if (!mounted) return null;
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
  final bool _wdAutoVideoThumb = true;
  // WebDAV 远程缩略图前缀下载阈值：过大容易抢占带宽/连接，影响起播。
  // 2MB-4MB 通常足够覆盖大多数文件头部信息；遇到 moov 在尾部会由 probeMoovInTail 决定是否全量下载。
  final int _wdVideoThumbMaxBytes = 4 * 1024 * 1024; // 4MB
  final Map<String, Future<File?>> _wdVideoThumbJobs =
      <String, Future<File?>>{};

  bool get _favoritePerDirectoryDisplaySettingsEnabled =>
      _controller.favoritePerDirectoryDisplaySettingsEnabled;
  set _favoritePerDirectoryDisplaySettingsEnabled(bool value) =>
      _controller.favoritePerDirectoryDisplaySettingsEnabled = value;

  LinkedHashMap<String, LayerSettings> get _perDirectoryDisplaySettings =>
      _controller.perDirectoryDisplaySettings;
  static const int _maxPerDirectoryDisplaySettingsEntries =
      FolderDetailController.maxPerDirectoryDisplaySettingsEntries;

  String _displaySettingsKeyForCtx(_NavCtx ctx) {
    return _controller.displaySettingsKeyForCtx(ctx);
  }

  String _normalizePersistedDisplaySettingsKey(String rawKey) {
    return _controller.normalizePersistedDisplaySettingsKey(rawKey);
  }

  LayerSettings _ensurePerDirectoryLayerSettings(String key) {
    return _controller.ensurePerDirectoryLayerSettings(
      key,
      seed: widget.collection.layer2,
    );
  }

  LayerSettings get _active {
    if (_stack.length == 1) return widget.collection.layer1;
    if (!_favoritePerDirectoryDisplaySettingsEnabled) {
      return widget.collection.layer2;
    }
    final key = _displaySettingsKeyForCtx(_stack.last);
    if (key.isEmpty) return widget.collection.layer2;
    return _ensurePerDirectoryLayerSettings(key);
  }

  Map<String, dynamic> _buildPerDirectoryDisplaySettingsJson() {
    return _controller.buildPerDirectoryDisplaySettingsJson();
  }

  Future<void> _persistPerDirectoryDisplaySettings() async {
    if (!_favoritePerDirectoryDisplaySettingsEnabled) return;
    try {
      await AppSettings.setFavoritePerDirectoryDisplaySettingsState(
        _buildPerDirectoryDisplaySettingsJson(),
      );
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loadPerDirectoryDisplaySettings() async {
    bool enabled = false;
    final loaded = <String, LayerSettings>{};
    try {
      enabled =
          await AppSettings.getFavoritePerDirectoryDisplaySettingsEnabled();
      if (enabled) {
        final raw =
            await AppSettings.getFavoritePerDirectoryDisplaySettingsState();
        for (final e in raw.entries) {
          final key = _normalizePersistedDisplaySettingsKey(e.key);
          if (key.isEmpty) continue;
          loaded[key] = LayerSettings.fromJson(e.value);
          if (loaded.length >= _maxPerDirectoryDisplaySettingsEntries) break;
        }
      }
    } catch (_) {
      enabled = false;
      loaded.clear();
    }
    if (!mounted) return;
    final disableFromEnabled =
        _favoritePerDirectoryDisplaySettingsEnabled && !enabled;
    // Turning OFF per-directory mode should fall back to one unified layer2.
    // Use current directory settings so the on-screen result does not jump.
    final fallbackUnified = disableFromEnabled ? _active.copy() : null;
    setState(() {
      if (fallbackUnified != null && _stack.length > 1) {
        widget.collection.layer2 = fallbackUnified;
      }
      _favoritePerDirectoryDisplaySettingsEnabled = enabled;
      _perDirectoryDisplaySettings
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _reloadDynamicSettings() async {
    bool tagEnabled = _tagEnabled;
    try {
      tagEnabled = await AppSettings.getTagEnabled();
    } catch (_) {}
    if (mounted && tagEnabled != _tagEnabled) {
      setState(() => _tagEnabled = tagEnabled);
    }
    await _loadPerDirectoryDisplaySettings();
  }

  void _refreshFolderDetailState() {
    if (!mounted) return;
    setState(() {});
  }

  void _updateActiveLayerSettings(
      void Function(LayerSettings settings) updater) {
    setState(() {
      final active = _active;
      updater(active);
      // In unified mode, folder display writes to collection.layer2.
      // In per-directory mode, active already points to a directory entry map.
      if (_stack.length > 1 && !_favoritePerDirectoryDisplaySettingsEnabled) {
        widget.collection.layer2 = active.copy();
      }
    });
    // ignore: unawaited_futures
    _persistPerDirectoryDisplaySettings();
  }

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
    _controller = FolderDetailController(collection: widget.collection)
      ..addListener(() {
        if (mounted) setState(() {});
      });
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

    // ignore: unawaited_futures
    _reloadDynamicSettings();
    _refresh();

    // Folder cover cache init (async)
    // ignore: unawaited_futures
    _initFolderCoverCache();
    // TagStore：用于标签筛选（隐藏式筛选面板）
    // ignore: unawaited_futures
    TagStore.I.ensureLoaded().then((_) => mounted ? setState(() {}) : null);
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
    _controller.dispose();
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
    if (l.contains('photo') || l.contains('image') || l.contains('picture')) {
      return true;
    }

    const imgTypes = <String>{
      'Photo',
      'Image',
    };
    return imgTypes.contains(raw);
  }

  List<_Entry> _shown() {
    return _controller.shown(
      activeSettings: _active,
      tagKeyOf: _entrySelectionKeyRaw,
    );
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
        if (!mounted) return;
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
        if (!mounted) return;
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
                  ? [_buildWebDavSource(a.id, relFile, isDir: false)]
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
    _updateActiveLayerSettings((s) => s.viewMode = v);
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
    _updateActiveLayerSettings((s) => s.sortKey = k);

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

    final compact = isCompactWidth(context);
    final selected = compact ? await showMobile() : await showDesktop();

    if (!mounted) return;
    pick = selected;
    if (pick != _selectedTagId) {
      setState(() => _selectedTagId = pick);
    }
  }

  @override
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _onBack();
        },
        child: Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF7F6FF),
                  Color(0xFFEFF4FF),
                  Color(0xFFF6FBFF)
                ],
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
                                            .withValues(alpha: 0.65),
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
                                tooltip: _searchExpanded || hasQuery
                                    ? '收起搜索'
                                    : '展开搜索',
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
                                      value: 'settings',
                                      icon: Icons.settings_outlined,
                                      label: '设置'),
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
                                            builder: (_) =>
                                                const HistoryPage()),
                                      );
                                      break;
                                    case 'settings':
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const SettingsPage()),
                                      );
                                      await _reloadDynamicSettings();
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
                                      await _openEmbyPageWithUi(context);
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
                          icon: (_selectedTagId == null ||
                                  _selectedTagId!.isEmpty)
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
                        onTap: () => _updateActiveLayerSettings(
                          (s) => s.asc = !s.asc,
                        ),
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
                      title:
                          selectedCount > 0 ? '已选择 $selectedCount 项' : '选择模式',
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
      ),
    );
  }

  Widget _buildByMode(List<_Entry> l, List<String> imgs, List<String> vids) {
    _syncEntryAnchorKeys(l);
    final usedAnchorKeys = <String>{};

    Widget itemWithAnchor(_Entry entry, Widget child) {
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
          controller: _scrollController, // 🔥 3. 绑定控制器
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
          controller: _scrollController, // 🔥 3. 绑定控制器
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
          controller: _scrollController, // 🔥 3. 绑定控制器
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
    // ✅ 强兜底：目录永远优先打开目录（避免被当成图片/视频）
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
              buildEmbySource(a.id, 'item:${x.embyItemId!}', name: x.name))
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
                ? [buildEmbySource(a.id, 'item:${e.embyItemId!}', name: e.name)]
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

    void sortEmbyOut() {
      // ✅ Emby 排序：在列表接口补齐“加入日期/大小”后，直接复用统一排序逻辑。
      // 设计原因：
      // - 统一体验：与本地/WebDAV 排序行为保持一致；
      // - 日期：使用 Emby 的 DateCreated 作为“加入日期”参与排序；
      // - 大小：优先使用 MediaSources[0].Size（若无则为 0）。
      out.sort(
          (a, b) => _controller.compareEntries(a, b, activeSettings: _active));
    }

    try {
      if (path == 'favorites') {
        // Emby 根入口：优先展示媒体库（Views）；无媒体库时再回退到收藏。
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
              embyAspectRatio: it.primaryImageAspectRatio,
            ),
          );
        }
        sortEmbyOut();
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
            embyAspectRatio: it.primaryImageAspectRatio,
          ),
        );
      }
      sortEmbyOut();
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
            // 普通媒体库里的 Emby 目录封面很多是稳定可用的 Cover/Thumb URL，
            // 不一定显式带 `tag=`。这里优先使用自动封面兜底，但只要原始封面 URL 非空，
            // 就继续保留为次选，避免把本来能显示的库封面过滤掉。
            final fallback = (e.embyCoverUrl ?? '').trim();
            final useUrl =
                (auto ?? '').trim().isNotEmpty ? auto!.trim() : fallback;
            if (useUrl.isNotEmpty) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: useUrl);
            }
          } catch (_) {
            // 忽略网络/权限错误，回落到原有 url
            final url = (e.embyCoverUrl ?? '').trim();
            if (url.isNotEmpty) {
              info = _CoverInfo.emby(
                  embyAccountId: e.embyAccountId ?? '', embyCoverUrl: url);
            }
          }
        } else {
          final url = (e.embyCoverUrl ?? '').trim();
          if (url.isNotEmpty) {
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
              color: Colors.black.withValues(alpha: 0.06),
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
        color: Colors.black.withValues(alpha: 0.06),
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
          onTap: () {
            // open edit dialog by popping back to list
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
        if (!work.sources.contains(norm)) {
          setState(() => work.sources.add(norm));
        }
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
