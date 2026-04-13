import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'image.dart';
import 'video.dart';
import 'webdav.dart';
import 'emby.dart';
import 'emby/exclusive_ui.dart';
import 'debug/thumbnail_inspector.dart';
import 'models/favorite_models.dart';
import 'pages/folder_detail_controller.dart' as folder_detail_controller;
import 'pages/folder_detail_models.dart';
import 'pages/media_helpers.dart';
import 'pages/navigation_helpers.dart';
import 'pages/tag_navigation_helpers.dart';
import 'pages/tag_source_helpers.dart';
import 'stores/favorite_store.dart';
import 'tag/tag_models.dart';

// 👇👇👇 重点修改这两行 👇👇👇
import 'core/utils/app_shared.dart'; // 必须直接引入，去掉 "as utils"
import 'tag.dart';
import 'sources/refs.dart';
// 👆👆👆 重点修改这两行 👆👆👆

part 'pages/settings_page.dart';
part 'pages/history_page.dart';
part 'pages/favorites_page.dart';
part 'pages/folder_cover_cache.dart';
part 'pages/folder_previews.dart';
part 'pages/folder_scope_search.dart';
part 'pages/folder_entry_helpers.dart';
part 'pages/folder_navigation_helpers.dart';
part 'pages/folder_load_helpers.dart';
part 'pages/folder_detail_host.dart';
part 'pages/folder_detail_state.dart';
part 'pages/folder_detail_rendering.dart';
part 'pages/folder_detail_toolbar.dart';
part 'pages/folder_detail_emby.dart';
part 'pages/folder_detail_cover_resolution.dart';
part 'pages/folder_detail_open_actions.dart';
part 'pages/shared_navigation_helpers.dart';
part 'pages/emby_only_favorites_page.dart';
part 'pages/dialog_helpers.dart';
// ===== app_pages.dart (auto-grouped) =====

// --- from pages.dart ---

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

bool _isImg(String path) => isPageImagePath(path);
bool _isVid(String path) => isPageVideoPath(path);

String _vmLabel(ViewMode v) => pageViewModeLabel(v);
String _skLabel(SortKey k) => pageSortKeyLabel(k);
IconData _vmIcon(ViewMode v) => pageViewModeIcon(v);
IconData _skIcon(SortKey k) => pageSortKeyIcon(k);
bool _isImgName(String name) => isPageImageName(name);
bool _isVidName(String name) => isPageVideoName(name);

int compareNaturalText(String a, String b) =>
    folder_detail_controller.compareNaturalText(a, b);

typedef _EmbyRef = EmbyPathSourceRef;
typedef _WebDavRef = WebDavSourceRef;

// 放在 const _imgExts = <String>{...} 这行代码的后面即可
extension CharExt on String {
  bool get isDigit => length == 1 && codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
}

/// =========================
/// FolderDetailPage
/// depth==0: virtual root (flatten sources first level)
/// depth>=1: real folder (use layer2 settings)
/// =========================
class FolderDetailPage extends StatelessWidget {
  final FavoriteCollection collection;

  /// 可选：用于从“历史记录/外部入口”直接打开到某个目录上下文。
  ///
  /// 设计原因：
  /// - 用户希望“点击图片后，把上级目录记入历史”，因此历史点击需要能还原到对应目录。
  /// - 为了最小改动，这里复用现有 FolderDetailPage 的导航栈，而不是新建一套页面。
  final NavCtx? initialNav;
  final bool exitOnInitialContextBack;
  const FolderDetailPage(
      {super.key,
      required this.collection,
      this.initialNav,
      this.exitOnInitialContextBack = false});

  @override
  Widget build(BuildContext context) {
    return _FolderDetailPageHost(
      collection: collection,
      initialNav: initialNav,
      exitOnInitialContextBack: exitOnInitialContextBack,
    );
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
