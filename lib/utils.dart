import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math'; // 确保引入 max
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ===============================
/// App Settings (新：应用级设置)
/// ===============================
/// 设计目标：
/// 1) “最小改动”地补齐播放器/收藏夹的关键设置项；
/// 2) 统一用 SharedPreferences 持久化，避免引入复杂依赖；
/// 3) 所有 key 均带前缀，降低未来冲突风险。
class AppSettings {
  AppSettings._();

  static const String _kPrefix = 'glacier_settings_';

  // --- 字幕 ---
  static const String _kSubtitleFontSize = '${_kPrefix}subtitle_font_size';
  static const String _kSubtitleBottomOffset =
      '${_kPrefix}subtitle_bottom_offset';

  // --- 交互 ---
  static const String _kDoubleTapSeekSeconds =
      '${_kPrefix}double_tap_seek_seconds';
  static const String _kLongPressSpeedMultiplier =
      '${_kPrefix}long_press_speed_multiplier';
  static const String _kLongPressSpeedEnabled =
      '${_kPrefix}long_press_speed_enabled';

  // --- 播放器（视频）---
  // 说明：
  // - 默认“播放完暂停”，更贴近常见观影习惯（也避免自动跳集导致错过片尾彩蛋）。
  // - 若开启“播放完自动下一集”，则会持久化，下一次播放也会沿用。
  static const String _kVideoAutoNextAfterEnd =
      '${_kPrefix}video_auto_next_after_end';
  // 控制栏隐藏时，是否显示底部细进度条（默认开启）。
  static const String _kVideoMiniProgressWhenHidden =
      '${_kPrefix}video_mini_progress_when_hidden';
  // 播放器目录功能开关（默认开启）。
  static const String _kVideoCatalogEnabled =
      '${_kPrefix}video_catalog_enabled';

  // --- 图片查看器 ---
  // 说明：是否允许使用音量键翻页（上一张/下一张）。
  // - 这是一个可选项：避免与系统音量调节冲突；
  // - 开启后：音量+ 下一张，音量- 上一张。
  static const String _kImageVolumeKeyPaging =
      '${_kPrefix}image_volume_key_paging';

  // --- 收藏夹 ---
  static const String _kAutoEnterLastFavorite =
      '${_kPrefix}auto_enter_last_favorite';
  static const String _kLastFavoriteId = '${_kPrefix}last_favorite_id';

  // --- 历史记录 ---
  static const String _kHistoryEnabled = '${_kPrefix}history_enabled';

  // --- 历史记录增强（已废弃） ---
  // 说明：旧版本曾支持“打开图片时记录上级目录到历史”。
  // 按最新需求已移除该功能，因此不再读取/写入该设置。
  // 这里保留 key 仅用于兼容旧数据，避免 SharedPreferences 膨胀或冲突。
  static const String _kHistoryRecordFolderOnImageOpen =
      '${_kPrefix}history_record_folder_on_image_open';

  // --- 标签(Tag) ---
  static const String _kTagEnabled = '${_kPrefix}tag_enabled';

  // --- 文件夹页搜索范围 ---
  // 取值：currentDirectory/currentCollection/allCollections/singleCollection
  static const String _kFolderSearchScope = '${_kPrefix}folder_search_scope';
  static const String _kFolderSearchSingleCollectionId =
      '${_kPrefix}folder_search_single_collection_id';

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  /// 字幕字号（默认 22）。
  static Future<double> getSubtitleFontSize() async {
    final sp = await _sp();
    return sp.getDouble(_kSubtitleFontSize) ?? 22.0;
  }

  static Future<void> setSubtitleFontSize(double v) async {
    final sp = await _sp();
    await sp.setDouble(_kSubtitleFontSize, v.clamp(12.0, 48.0));
  }

  /// 字幕距底部偏移（默认 36）。
  static Future<double> getSubtitleBottomOffset() async {
    final sp = await _sp();
    return sp.getDouble(_kSubtitleBottomOffset) ?? 36.0;
  }

  static Future<void> setSubtitleBottomOffset(double v) async {
    final sp = await _sp();
    await sp.setDouble(_kSubtitleBottomOffset, v.clamp(0.0, 200.0));
  }

  /// 双击快进/快退秒数（默认 10）。
  static Future<int> getDoubleTapSeekSeconds() async {
    final sp = await _sp();
    return sp.getInt(_kDoubleTapSeekSeconds) ?? 10;
  }

  static Future<void> setDoubleTapSeekSeconds(int v) async {
    final sp = await _sp();
    await sp.setInt(_kDoubleTapSeekSeconds, v.clamp(5, 60));
  }

  /// 长按倍速开关（默认开启）。
  static Future<bool> getLongPressSpeedEnabled() async {
    final sp = await _sp();
    return sp.getBool(_kLongPressSpeedEnabled) ?? true;
  }

  static Future<void> setLongPressSpeedEnabled(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kLongPressSpeedEnabled, v);
  }

  /// 长按倍速乘数（默认 2.0）。
  static Future<double> getLongPressSpeedMultiplier() async {
    final sp = await _sp();
    return sp.getDouble(_kLongPressSpeedMultiplier) ?? 2.0;
  }

  static Future<void> setLongPressSpeedMultiplier(double v) async {
    final sp = await _sp();
    await sp.setDouble(_kLongPressSpeedMultiplier, v.clamp(1.25, 4.0));
  }

  /// 播放结束行为：是否“自动下一集”（默认 false：播放完暂停）。
  static Future<bool> getVideoAutoNextAfterEnd() async {
    final sp = await _sp();
    return sp.getBool(_kVideoAutoNextAfterEnd) ?? false;
  }

  static Future<void> setVideoAutoNextAfterEnd(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kVideoAutoNextAfterEnd, v);
  }

  /// 控制栏隐藏时，是否显示底部细进度条（默认 true）。
  static Future<bool> getVideoMiniProgressWhenHidden() async {
    final sp = await _sp();
    return sp.getBool(_kVideoMiniProgressWhenHidden) ?? true;
  }

  static Future<void> setVideoMiniProgressWhenHidden(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kVideoMiniProgressWhenHidden, v);
  }

  /// 播放器目录功能开关（默认 true）。
  static Future<bool> getVideoCatalogEnabled() async {
    final sp = await _sp();
    return sp.getBool(_kVideoCatalogEnabled) ?? true;
  }

  static Future<void> setVideoCatalogEnabled(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kVideoCatalogEnabled, v);
  }

  /// 图片查看器：是否启用“音量键翻页”（默认关闭）。
  static Future<bool> getImageVolumeKeyPaging() async {
    final sp = await _sp();
    return sp.getBool(_kImageVolumeKeyPaging) ?? false;
  }

  static Future<void> setImageVolumeKeyPaging(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kImageVolumeKeyPaging, v);
  }

  /// 是否自动进入上次选择的收藏夹（默认关闭）。
  static Future<bool> getAutoEnterLastFavorite() async {
    final sp = await _sp();
    return sp.getBool(_kAutoEnterLastFavorite) ?? false;
  }

  static Future<void> setAutoEnterLastFavorite(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kAutoEnterLastFavorite, v);
  }

  static Future<String?> getLastFavoriteId() async {
    final sp = await _sp();
    final v = sp.getString(_kLastFavoriteId);
    if (v == null || v.trim().isEmpty) return null;
    return v;
  }

  static Future<void> setLastFavoriteId(String? id) async {
    final sp = await _sp();
    if (id == null || id.trim().isEmpty) {
      await sp.remove(_kLastFavoriteId);
      return;
    }
    await sp.setString(_kLastFavoriteId, id.trim());
  }

  /// 历史记录开关（默认开启）。
  static Future<bool> getHistoryEnabled() async {
    final sp = await _sp();
    return sp.getBool(_kHistoryEnabled) ?? true;
  }

  // ⚠️ 已移除：get/setHistoryRecordFolderOnImageOpen

  static Future<void> setHistoryEnabled(bool v) async {
    final sp = await _sp();
    await sp.setBool(_kHistoryEnabled, v);
  }

  static Future<bool> getTagEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kTagEnabled) ?? true;
  }

  static Future<void> setTagEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kTagEnabled, v);
  }

  static Future<String> getFolderSearchScope() async {
    final sp = await SharedPreferences.getInstance();
    final raw = (sp.getString(_kFolderSearchScope) ?? '').trim();
    const allowed = <String>{
      'currentDirectory',
      'currentCollection',
      'allCollections',
      'singleCollection',
    };
    if (!allowed.contains(raw)) return 'currentCollection';
    return raw;
  }

  static Future<void> setFolderSearchScope(String value) async {
    final sp = await SharedPreferences.getInstance();
    const allowed = <String>{
      'currentDirectory',
      'currentCollection',
      'allCollections',
      'singleCollection',
    };
    final v = allowed.contains(value) ? value : 'currentCollection';
    await sp.setString(_kFolderSearchScope, v);
  }

  static Future<String?> getFolderSearchSingleCollectionId() async {
    final sp = await SharedPreferences.getInstance();
    final v = (sp.getString(_kFolderSearchSingleCollectionId) ?? '').trim();
    if (v.isEmpty) return null;
    return v;
  }

  static Future<void> setFolderSearchSingleCollectionId(String? id) async {
    final sp = await SharedPreferences.getInstance();
    final v = (id ?? '').trim();
    if (v.isEmpty) {
      await sp.remove(_kFolderSearchSingleCollectionId);
      return;
    }
    await sp.setString(_kFolderSearchSingleCollectionId, v);
  }
}

/// ===============================
/// App History (新：播放历史)
/// ===============================
/// 说明：
/// - 仅记录“视频播放”行为（路径/时间/进度），用于右上角“历史”入口。
/// - 采用 JSON 存 SharedPreferences，保持依赖最小。
class AppHistory {
  AppHistory._();

  static const String _kHistoryKey = 'glacier_history_v1';
  static const int _maxEntries = 200;

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static Future<List<Map<String, dynamic>>> load() async {
    final sp = await _sp();
    final raw = sp.getString(_kHistoryKey);
    if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return <Map<String, dynamic>>[];
      final list =
          j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      // ✅ 历史数据“温和修复/去噪”
      // 说明：历史记录早期版本曾在「播放视频」前插入一条“目录(folder)记录”，
      // 导致历史里出现“目录 + 视频”两条紧挨着的情况。
      // 这会被用户误解为“把目录里的内容都加入历史”。
      //
      // 现在已在入口逻辑侧修复，但旧数据仍可能残留。
      // 这里做一次轻量清理：若某条 media 记录后紧跟 folder 记录，且时间非常接近且来源一致，则丢弃该 folder。
      final normalized = _normalize(list);
      if (normalized.length != list.length) {
        // ✅ 只在确实发生清理时回写，避免每次 load 都产生写放大。
        // ignore: unawaited_futures
        _save(normalized);
      }
      return normalized;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static List<Map<String, dynamic>> _normalize(
      List<Map<String, dynamic>> list) {
    if (list.length < 2) return list;

    const int windowMs = 10 * 1000; // 10s: 足够覆盖“点开即播放”的场景，且不至于误删太多。

    bool _isEmby(String p) => p.startsWith('emby://');
    bool _isWebDav(String p) => p.startsWith('webdav://');

    String _hostOf(String p) {
      try {
        return Uri.parse(p).host;
      } catch (_) {
        // 退化：scheme://host/...
        final i = p.indexOf('://');
        if (i < 0) return '';
        final rest = p.substring(i + 3);
        final slash = rest.indexOf('/');
        return slash < 0 ? rest : rest.substring(0, slash);
      }
    }

    final out = <Map<String, dynamic>>[];

    for (int i = 0; i < list.length; i++) {
      final cur = list[i];
      // 默认保留
      var drop = false;

      if (i > 0) {
        final prev = out.isEmpty ? null : out.last;
        // 注意：由于 out 是逐条 append，所以 prev 对应原 list 的 i-1（在没有 drop 的情况下）。
        if (prev != null) {
          final prevKind = (prev['kind'] ?? 'media').toString();
          final curKind = (cur['kind'] ?? 'media').toString();

          if (prevKind == 'media' && curKind == 'folder') {
            final prevT = int.tryParse((prev['t'] ?? '').toString()) ?? 0;
            final curT = int.tryParse((cur['t'] ?? '').toString()) ?? 0;
            final dt = (prevT - curT).abs();

            if (prevT > 0 && curT > 0 && dt <= windowMs) {
              final prevPath = (prev['path'] ?? '').toString();
              final ctxKind = (cur['ctxKind'] ?? '').toString();

              // Emby：同账号即可认为同一来源（无法从 itemId 反推目录层级）
              if (ctxKind == 'emby' && _isEmby(prevPath)) {
                final accId = (cur['embyAccountId'] ?? '').toString();
                if (accId.isNotEmpty && _hostOf(prevPath) == accId) {
                  drop = true;
                }
              }

              // WebDAV：同账号即可认为同一来源
              if (ctxKind == 'webdav' && _isWebDav(prevPath)) {
                final accId = (cur['wdAccountId'] ?? '').toString();
                if (accId.isNotEmpty && _hostOf(prevPath) == accId) {
                  drop = true;
                }
              }

              // Local：若 media path 位于该目录下，认为同一来源
              if (ctxKind == 'local') {
                final dir = (cur['localDir'] ?? '').toString();
                if (dir.isNotEmpty && !prevPath.contains('://')) {
                  try {
                    final normDir = p.normalize(dir);
                    final normPath = p.normalize(prevPath);
                    if (p.isWithin(normDir, normPath)) drop = true;
                  } catch (_) {
                    // ignore
                  }
                }
              }
            }
          }
        }
      }

      if (!drop) out.add(cur);
    }

    return out;
  }

  static Future<void> _save(List<Map<String, dynamic>> list) async {
    final sp = await _sp();
    await sp.setString(_kHistoryKey, jsonEncode(list));
  }

  /// 写入/更新一条历史。
  /// - path：播放源（本地路径 / webdav://... / emby://...）。
  /// - title：展示用标题（通常取文件名或媒体名）。
  /// - positionMs：可选，记录退出时进度。
  static Future<void> upsert({
    required String path,
    required String title,
    int? positionMs,
    String kind = 'media',
    String? favId,
    String? coverPath,
  }) async {
    if (path.trim().isEmpty) return;
    if (!await AppSettings.getHistoryEnabled()) return;

    // ✅ 防御性处理：避免异常/恶意输入导致历史表膨胀或 UI 渲染异常。
    var safeTitle = title.trim();
    if (safeTitle.isEmpty) safeTitle = '未命名';
    // 控制标题长度，避免极端情况下 SharedPreferences 写入过大。
    if (safeTitle.length > 160) safeTitle = '${safeTitle.substring(0, 160)}…';

    final now = DateTime.now().millisecondsSinceEpoch;
    final list = await load();

    // 设计原因：同一资源重复播放时，只保留最新一条，避免历史刷屏。
    list.removeWhere((e) => (e['path'] ?? '') == path);

    list.insert(0, <String, dynamic>{
      'kind': kind,
      'path': path,
      'title': safeTitle,
      't': now,
      if (positionMs != null) 'pos': positionMs,
      if (favId != null && favId.trim().isNotEmpty) 'favId': favId,
      if (coverPath != null && coverPath.trim().isNotEmpty) 'cover': coverPath,
    });

    if (list.length > _maxEntries) {
      list.removeRange(_maxEntries, list.length);
    }

    await _save(list);
  }

  /// 记录“收藏夹/目录”进入历史。
  /// 说明：与媒体历史共用同一张表，靠 kind 区分。
  static Future<void> upsertFolder({
    required String favId,
    required String title,
    String? coverPath,
  }) async {
    final path = 'fav://$favId';
    await upsert(
      path: path,
      title: title,
      kind: 'fav',
      favId: favId,
      coverPath: coverPath,
    );
  }

  /// 记录“目录（上级目录）”进入历史。
  ///
  /// ✅ 为什么要单独做：
  /// - 用户需求是“打开图片后记录图片的上级目录”，而不是记录收藏夹；
  /// - 目录需要能从历史一键还原到对应位置，因此要保存导航上下文。
  ///
  /// 参数 ctx 说明：
  /// - local：localDir
  /// - webdav：wdAccountId + wdRel（目录相对路径，建议以 / 结尾）
  /// - emby：embyAccountId + embyPath（favorites / view:xxx 等）
  static Future<void> upsertFolderCtx({
    required dynamic ctx,
    required String title,
    String? coverPath,
  }) async {
    try {
      // ctx 是 pages.dart 的 _NavCtx，为了最小改动这里不强依赖类型，只读取字段。
      final kind = (ctx.kind ?? '').toString();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!await AppSettings.getHistoryEnabled()) return;

      final list = await load();

      // 生成一个稳定 key，用于去重。
      String path;
      final entry = <String, dynamic>{
        'kind': 'folder',
        'title': title,
        't': now,
      };

      if (kind.contains('local')) {
        final dir = (ctx.localDir ?? '').toString().trim();
        if (dir.isEmpty) return;
        path = 'folder://local/$dir';
        entry['ctxKind'] = 'local';
        entry['localDir'] = dir;
      } else if (kind.contains('webdav')) {
        final accId = (ctx.wdAccountId ?? '').toString().trim();
        var rel = (ctx.wdRel ?? '').toString().trim();
        if (accId.isEmpty) return;
        if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
        path = 'folder://webdav/$accId/$rel';
        entry['ctxKind'] = 'webdav';
        entry['wdAccountId'] = accId;
        entry['wdRel'] = rel;
      } else if (kind.contains('emby')) {
        final accId = (ctx.embyAccountId ?? '').toString().trim();
        final pth = (ctx.embyPath ?? '').toString().trim();
        if (accId.isEmpty) return;
        path = 'folder://emby/$accId/${pth.isEmpty ? 'favorites' : pth}';
        entry['ctxKind'] = 'emby';
        entry['embyAccountId'] = accId;
        entry['embyPath'] = pth.isEmpty ? 'favorites' : pth;
      } else {
        return;
      }

      entry['path'] = path;
      if (coverPath != null && coverPath.trim().isNotEmpty)
        entry['cover'] = coverPath;

      list.removeWhere((e) => (e['path'] ?? '') == path);
      list.insert(0, entry);
      if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
      await _save(list);
    } catch (_) {
      // 历史增强是“锦上添花”，失败不影响主流程。
    }
  }

  static Future<void> removeAt(int index) async {
    final list = await load();
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await _save(list);
  }

  static Future<void> clear() async {
    final sp = await _sp();
    await sp.remove(_kHistoryKey);
  }

  /// 更新已有记录的进度（如果记录不存在则忽略）。
  static Future<void> updateProgress(
      {required String path, required int positionMs}) async {
    if (path.trim().isEmpty) return;
    if (!await AppSettings.getHistoryEnabled()) return;

    final list = await load();
    final idx = list.indexWhere((e) => (e['path'] ?? '') == path);
    if (idx < 0) return;
    list[idx]['pos'] = positionMs;
    await _save(list);
  }
}

// 保留你原有的 WebDavBackgroundHttpPool 类...
// (如果此处省略了 WebDavBackgroundHttpPool 代码，请确保你保留了它)

/// ===============================
/// Persistent Store (新：永久存储管理)
/// ===============================
class PersistentStore {
  PersistentStore._();
  static final PersistentStore instance = PersistentStore._();

  static Directory? _docDir;

  /// 获取 App 的“文档目录”。
  /// 系统【绝对不会】自动清理这里的文件，适合长期保存封面和 WebDAV 缓存。
  Future<Directory> get _baseDir async {
    // 关键修改：从 getApplicationSupportDirectory 改为 getApplicationDocumentsDirectory
    _docDir ??= await getApplicationDocumentsDirectory();
    return _docDir!;
  }

  /// 获取特定类型的缓存目录
  /// [type]: 'thumbs' (封面), 'media' (原文件)
  Future<Directory> getDir(String type) async {
    final base = await _baseDir;
    final dir = Directory(p.join(base.path, 'glacier_store', type));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 生成稳定的文件名 key (SHA1)
  String makeKey(String input) {
    return sha1.convert(utf8.encode(input)).toString();
  }

  /// 获取本地文件句柄（无论是否存在）
  Future<File> getFile(String key, String type, String ext) async {
    final dir = await getDir(type);
    final safeExt = ext.startsWith('.') ? ext : '.$ext';
    return File(p.join(dir.path, '$key$safeExt'));
  }
}

/// ===============================
/// Thumb Cache (重构版)
/// ===============================
class ThumbCache {
  static final Map<String, Future<File?>> _inflight = {};

  /// Backward-compatible API used by video.dart
  /// Returns cached thumb if exists, otherwise null (no creation).
  static Future<File?> getCachedVideoThumb(String videoPath) async {
    // ✅ 重要修复：cacheOnly=true 时必须“只读缓存”，绝不能触发抽帧生成。
    // 否则会导致：
    // - 目录/列表快速滚动时大量触发抽帧 → 卡顿
    // - WebDAV/Emby 等非本地路径无法抽帧 → 永远占位，且持续尝试
    try {
      // 与 getOrCreateVideoPreviewFrame 默认参数保持一致（0ms, 320x180, step=1s）。
      const width = 320;
      const height = 180;
      const posMs = 0;
      final keyStr = '$videoPath|$posMs|$width|$height';
      final key = PersistentStore.instance.makeKey(keyStr);
      final out = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');
      if (!await out.exists()) return null;
      if (await out.length() <= 0) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Backward-compatible API used by video.dart
  /// Always tries to create a thumb (first frame at 0ms) if missing.
  static Future<File?> getOrCreateVideoThumb(String videoPath) async {
    try {
      final f = await getOrCreateVideoPreviewFrame(videoPath, Duration.zero);
      if (f == null) return null;
      if (!await f.exists()) return null;
      if (await f.length() <= 0) return null;
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 获取或生成视频缩略图（永久保存）
  static Future<File?> getOrCreateVideoPreviewFrame(
    String videoPath,
    Duration position, {
    Duration step = const Duration(seconds: 1),
    int width = 320,
    int height = 180,
    bool fastSeek = true,
  }) async {
    if (videoPath.isEmpty) return null;

    // 为了命中率，将时间取整 (quantize)
    final qMs = (position.inMilliseconds / step.inMilliseconds).round() *
        step.inMilliseconds;
    final posQ = Duration(milliseconds: max(0, qMs));

    // 生成唯一 Key
    final keyStr = '$videoPath|${posQ.inMilliseconds}|$width|$height';
    final key = PersistentStore.instance.makeKey(keyStr);

    // 从 'thumbs' 目录获取文件
    final out = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');

    // 1. 检查本地是否已有缓存（永久存在）
    if (await out.exists() && await out.length() > 0) {
      return out;
    }

    // 2. 防止并发重复生成
    if (_inflight.containsKey(key)) return _inflight[key];

    final task = (() async {
      try {
        // 如果是 WebDAV 视频，通常需要先确保本地有文件才能由 video_thumbnail 库截图
        // 这里暂时假设 videoPath 是本地路径，或者是已挂载路径
        // *如果是纯 WebDAV URL，video_thumbnail 在 Android 上可能无法直接工作，
        // 需要结合下面的 WebDavFileCache 先下载部分头文件*

        final bytes = await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          timeMs: posQ.inMilliseconds,
          maxWidth: width,
          quality: 75,
        );

        if (bytes == null || bytes.isEmpty) return null;

        // 写入永久目录
        await out.writeAsBytes(bytes, flush: true);
        return out;
      } catch (e) {
        debugPrint('Thumb gen error: $e');
        return null;
      } finally {
        _inflight.remove(key);
      }
    })();

    _inflight[key] = task;
    return task;
  }
}

/// ===============================
/// WebDAV File Cache (新功能：大文件缓存)
/// ===============================
class WebDavFileCache {
  /// 下载并缓存 WebDAV 文件（图片或视频）
  /// 返回本地 File 对象。如果已存在则直接返回。
  static Future<File> downloadAndCache(String webDavUrl,
      {String? customName}) async {
    final ext = p.extension(customName ?? webDavUrl).toLowerCase();
    final key = PersistentStore.instance.makeKey(webDavUrl);

    // 存放在 'media' 子目录
    final file = await PersistentStore.instance.getFile(key, 'media', ext);

    if (await file.exists()) {
      debugPrint('✅ Cache hit (WebDAV): ${file.path}');
      return file;
    }

    debugPrint('⬇️ Downloading WebDAV asset: $webDavUrl');

    // 使用 HttpClient 下载
    // 建议：这里可以使用 WebDavBackgroundHttpPool.instance.client (如果是后台下载)
    // 或者新建 Client 以获得最大速度
    final request = await HttpClient().getUrl(Uri.parse(webDavUrl));
    final response = await request.close(); // 流式写入，防止内存溢出
    final sink = file.openWrite();
    await response.pipe(sink);
    await sink.close();

    debugPrint('✅ Download complete: ${file.path}');
    return file;
  }
}

/// ===============================
/// Cover Cache (新：收藏夹封面缓存，解决滚动回收后重复加载)
/// ===============================
/// - 缓存 inflight Future，避免并发重复扫描
/// - 结果缓存使用简易 LRU，防止无限增长
class CoverCache {
  CoverCache._();
  static final CoverCache instance = CoverCache._();

  /// 最大缓存条目数（按需调整）
  static const int maxEntries = 400;

  final Map<String, Future<dynamic>> _inflight = {};
  final LinkedHashMap<String, dynamic> _lru = LinkedHashMap();

  T? getResult<T>(String key) {
    if (!_lru.containsKey(key)) return null;
    final v = _lru.remove(key);
    // refresh LRU
    _lru[key] = v;
    return v as T;
  }

  Future<T?> getOrCreate<T>(String key, Future<T?> Function() loader,
      {bool cacheNull = false}) {
    final cached = getResult<T>(key);
    if (cached != null) return Future.value(cached);

    if (_inflight.containsKey(key)) return _inflight[key] as Future<T?>;

    final fut = (() async {
      try {
        final r = await loader();
        if (r != null || cacheNull) {
          _put(key, r);
        }
        return r;
      } finally {
        _inflight.remove(key);
      }
    })();

    _inflight[key] = fut;
    return fut;
  }

  void invalidate(String key) {
    _inflight.remove(key);
    _lru.remove(key);
  }

  void _put(String key, dynamic value) {
    if (_lru.length >= maxEntries) {
      final oldestKey = _lru.keys.first;
      _lru.remove(oldestKey);
    }
    _lru[key] = value;
  }

  /// 为 sources 生成稳定 key（避免 key 过长）
  static String keyForSources(List<String> sources) {
    final joined = sources.join('|');
    return sha1.convert(utf8.encode(joined)).toString();
  }
}

// ✅ 已移除“跟随系统/深色/浅色”主题切换：
// 需求：删除跟随系统浅色模式深色模式。
// 这里保留文件结构不做大改动，因此直接移除全局 ThemeMode 通知器。

/// ===============================
/// URI 组件安全解码（增强：避免“中文/百分号”等文件名导致解码异常）
/// ===============================
/// 设计原因：
/// - Dart 的 Uri.queryParameters 会**自动解码一次**；如果再次对“已经是明文”的字符串调用 Uri.decodeComponent，
///   当文件名本身包含 '%'（例如：`进度100%`）时会抛出 FormatException，进而触发上层兜底逻辑，
///   最常见的表现就是历史/标题回退为“Emby 媒体”等默认文案。
/// - 为了遵守“最小改动”，这里提供统一的安全解码：
///   1) 仅当字符串包含 '%' 才尝试 decode；
///   2) 解码失败则返回原字符串，保证 UI 至少可读、可搜索。
String safeDecodeUriComponent(String input) {
  final s = input;
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

/// ===============================
/// 敏感信息脱敏（日志/错误展示安全）
/// ===============================
/// 设计目标：
/// - 避免把 WebDAV BasicAuth（user:pass@）/ Emby api_key 等敏感信息
///   直接展示在 SnackBar / debugPrint 里（易被截图/日志收集）。
/// - 尽量“只脱敏不改语义”，便于定位问题。
String redactSensitiveText(String input) {
  var s = input;

  // 1) URL userInfo: scheme://user:pass@host -> scheme://***:***@host
  s = s.replaceAllMapped(
    RegExp(r':\/\/([^\/\s:@]+):([^\/\s@]+)@'),
    (_) => '://***:***@',
  );

  // 2) 常见 token/api_key 参数：...?api_key=xxx -> ...?api_key=***
  s = s.replaceAllMapped(
    RegExp(r'([?&](?:api_key|apikey|token|access_token|x-emby-token)=)[^&\s]+',
        caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  return s;
}
