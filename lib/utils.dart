import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math'; // 确保引入 max
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/logging/app_logger.dart';
import 'core/network/http_client_factory.dart';
import 'core/network/network_runner.dart';
import 'core/utils/redaction.dart' as core_redaction;

class AppHistoryFolderCtx {
  final String kind;
  final String? localDir;
  final String? wdAccountId;
  final String wdRel;
  final String? embyAccountId;
  final String embyPath;

  const AppHistoryFolderCtx.local(String dir)
      : kind = 'local',
        localDir = dir,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const AppHistoryFolderCtx.webdav({
    required String accountId,
    required String rel,
  })  : kind = 'webdav',
        localDir = null,
        wdAccountId = accountId,
        wdRel = rel,
        embyAccountId = null,
        embyPath = '';

  const AppHistoryFolderCtx.emby({
    required String accountId,
    String path = 'favorites',
  })  : kind = 'emby',
        localDir = null,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = accountId,
        embyPath = path;
}

/// ===============================
/// App Settings (新：应用级设置)
/// ===============================
/// 设计目标：
/// 1) “最小改动”地补齐播放器/收藏夹的关键设置项；
/// 2) 统一用 SharedPreferences 持久化，避免引入复杂依赖；
/// 3) 所有 key 均带前缀，降低未来冲突风险。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  SharedPreferences? _prefs;
  bool _initialized = false;
  Future<void>? _initFuture;

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
  // 播放器“上下集”按钮开关（默认开启）。
  static const String _kVideoEpisodeNavButtonsEnabled =
      '${_kPrefix}video_episode_nav_buttons_enabled';
  // 锁定后是否仍允许“暂停 + 进度条拖动”（仅保留轻量控制，不展开完整控制层）。
  static const String _kVideoLockPauseSeekEnabled =
      '${_kPrefix}video_lock_pause_seek_enabled';
  // 打开播放器目录时，是否自动定位到当前播放项附近。
  static const String _kVideoCatalogLocateCurrentOnOpen =
      '${_kPrefix}video_catalog_locate_current_on_open';
  // Emby 混合库里“图片主导”的判定阈值（百分比）。
  static const String _kEmbyImageDominantThresholdPercent =
      '${_kPrefix}emby_image_dominant_threshold_percent';
  // Emby 图片库简化模式：目录优先、图片就近展示（默认开启）。
  static const String _kEmbyImageLibrarySimpleModeEnabled =
      '${_kPrefix}emby_image_library_simple_mode_enabled';
  // 是否自动从历史进度续播（默认开启）。
  static const String _kVideoResumeEnabled = '${_kPrefix}video_resume_enabled';
  // 断点续播提示开关（默认开启）。
  static const String _kVideoResumeHintEnabled =
      '${_kPrefix}video_resume_hint_enabled';

  // --- 图片查看器 ---
  // 说明：是否允许使用音量键翻页（上一张/下一张）。
  // - 这是一个可选项：避免与系统音量调节冲突；
  // - 开启后：音量+ 上一张，音量- 下一张。
  static const String _kImageVolumeKeyPaging =
      '${_kPrefix}image_volume_key_paging';
  // 图片查看器退出后，列表是否自动定位到最后浏览的图片（默认开启）。
  static const String _kImageExitLocateEnabled =
      '${_kPrefix}image_exit_locate_enabled';

  // --- 收藏夹 ---
  static const String _kAutoEnterLastFavorite =
      '${_kPrefix}auto_enter_last_favorite';
  static const String _kLastFavoriteId = '${_kPrefix}last_favorite_id';
  static const String _kFavoritePerDirectoryDisplaySettingsEnabled =
      '${_kPrefix}favorite_per_directory_display_settings_enabled';
  static const String _kFavoritePerDirectoryDisplaySettingsState =
      '${_kPrefix}favorite_per_directory_display_settings_state_v1';
  static const String _kEmbyExclusiveFavoritesUiEnabled =
      '${_kPrefix}emby_exclusive_favorites_ui_enabled';

  // --- 历史记录 ---
  static const String _kHistoryEnabled = '${_kPrefix}history_enabled';

  // --- 标签(Tag) ---
  static const String _kTagEnabled = '${_kPrefix}tag_enabled';

  // --- 文件夹页搜索范围 ---
  // 取值：currentDirectory/currentCollection/allCollections/singleCollection
  static const String _kFolderSearchScope = '${_kPrefix}folder_search_scope';
  static const String _kFolderSearchSingleCollectionId =
      '${_kPrefix}folder_search_single_collection_id';

  static Future<SharedPreferences> _sp() async {
    await instance.init();
    return instance._prefs!;
  }

  Future<void> init() {
    final pending = _initFuture;
    if (pending != null) return pending;
    final future = () async {
      _prefs ??= await SharedPreferences.getInstance();
      _initialized = true;
    }();
    _initFuture = future;
    return future;
  }

  bool get isInitialized => _initialized;

  Future<T> _read<T>(T Function(SharedPreferences sp) reader) async {
    final sp = await _sp();
    return reader(sp);
  }

  static Future<void> _writeAndNotify(
    Future<void> Function(SharedPreferences sp) writer,
  ) async {
    final sp = await _sp();
    await writer(sp);
    instance.notifyListeners();
  }

  /// 字幕字号（默认 22）。
  static Future<double> getSubtitleFontSize() async {
    return instance._read((sp) => sp.getDouble(_kSubtitleFontSize) ?? 22.0);
  }

  static Future<void> setSubtitleFontSize(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kSubtitleFontSize, v.clamp(12.0, 48.0)),
    );
  }

  /// 字幕距底部偏移（默认 36）。
  static Future<double> getSubtitleBottomOffset() async {
    return instance._read((sp) => sp.getDouble(_kSubtitleBottomOffset) ?? 36.0);
  }

  static Future<void> setSubtitleBottomOffset(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kSubtitleBottomOffset, v.clamp(0.0, 200.0)),
    );
  }

  /// 双击快进/快退秒数（默认 10）。
  static Future<int> getDoubleTapSeekSeconds() async {
    return instance._read((sp) => sp.getInt(_kDoubleTapSeekSeconds) ?? 10);
  }

  static Future<void> setDoubleTapSeekSeconds(int v) async {
    await _writeAndNotify(
      (sp) => sp.setInt(_kDoubleTapSeekSeconds, v.clamp(5, 60)),
    );
  }

  /// 长按倍速开关（默认开启）。
  static Future<bool> getLongPressSpeedEnabled() async {
    return instance._read((sp) => sp.getBool(_kLongPressSpeedEnabled) ?? true);
  }

  static Future<void> setLongPressSpeedEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kLongPressSpeedEnabled, v));
  }

  /// 长按倍速乘数（默认 2.0）。
  static Future<double> getLongPressSpeedMultiplier() async {
    return instance
        ._read((sp) => sp.getDouble(_kLongPressSpeedMultiplier) ?? 2.0);
  }

  static Future<void> setLongPressSpeedMultiplier(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kLongPressSpeedMultiplier, v.clamp(1.25, 4.0)),
    );
  }

  /// 播放结束行为：是否“自动下一集”（默认 false：播放完暂停）。
  static Future<bool> getVideoAutoNextAfterEnd() async {
    return instance._read((sp) => sp.getBool(_kVideoAutoNextAfterEnd) ?? false);
  }

  static Future<void> setVideoAutoNextAfterEnd(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoAutoNextAfterEnd, v));
  }

  /// 控制栏隐藏时，是否显示底部细进度条（默认 true）。
  static Future<bool> getVideoMiniProgressWhenHidden() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoMiniProgressWhenHidden) ?? true);
  }

  static Future<void> setVideoMiniProgressWhenHidden(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoMiniProgressWhenHidden, v),
    );
  }

  /// 播放器目录功能开关（默认 true）。
  static Future<bool> getVideoCatalogEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoCatalogEnabled) ?? true);
  }

  static Future<void> setVideoCatalogEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoCatalogEnabled, v));
  }

  /// 播放器“上下集”按钮开关（默认 true）。
  static Future<bool> getVideoEpisodeNavButtonsEnabled() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoEpisodeNavButtonsEnabled) ?? true);
  }

  static Future<void> setVideoEpisodeNavButtonsEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoEpisodeNavButtonsEnabled, v),
    );
  }

  /// 锁定后是否仍允许“暂停 + 进度条拖动”（默认 true）。
  static Future<bool> getVideoLockPauseSeekEnabled() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoLockPauseSeekEnabled) ?? true);
  }

  static Future<void> setVideoLockPauseSeekEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoLockPauseSeekEnabled, v),
    );
  }

  /// 目录打开时是否自动定位当前播放项（默认 true）。
  static Future<bool> getVideoCatalogLocateCurrentOnOpen() async {
    return instance._read(
      (sp) => sp.getBool(_kVideoCatalogLocateCurrentOnOpen) ?? true,
    );
  }

  static Future<void> setVideoCatalogLocateCurrentOnOpen(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoCatalogLocateCurrentOnOpen, v),
    );
  }

  /// Emby 混合库里“图片主导”判定阈值（默认 67）。
  /// - 取值范围：50~90（越高越不容易触发图片主导）。
  static Future<int> getEmbyImageDominantThresholdPercent() async {
    return instance._read((sp) {
      final raw = sp.getInt(_kEmbyImageDominantThresholdPercent) ?? 67;
      return raw.clamp(50, 90);
    });
  }

  static Future<void> setEmbyImageDominantThresholdPercent(int v) async {
    await _writeAndNotify(
      (sp) => sp.setInt(_kEmbyImageDominantThresholdPercent, v.clamp(50, 90)),
    );
  }

  /// Emby 图片库简化模式（默认 true）。
  static Future<bool> getEmbyImageLibrarySimpleModeEnabled() async {
    return instance._read(
      (sp) => sp.getBool(_kEmbyImageLibrarySimpleModeEnabled) ?? true,
    );
  }

  static Future<void> setEmbyImageLibrarySimpleModeEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kEmbyImageLibrarySimpleModeEnabled, v),
    );
  }

  /// 是否自动从历史进度续播（默认 true）。
  static Future<bool> getVideoResumeEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoResumeEnabled) ?? true);
  }

  static Future<void> setVideoResumeEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoResumeEnabled, v));
  }

  /// 断点续播提示开关（默认 true）。
  static Future<bool> getVideoResumeHintEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoResumeHintEnabled) ?? true);
  }

  static Future<void> setVideoResumeHintEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoResumeHintEnabled, v));
  }

  /// 图片查看器：是否启用“音量键翻页”（默认关闭）。
  static Future<bool> getImageVolumeKeyPaging() async {
    return instance._read((sp) => sp.getBool(_kImageVolumeKeyPaging) ?? false);
  }

  static Future<void> setImageVolumeKeyPaging(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kImageVolumeKeyPaging, v));
  }

  /// 图片查看器：退出后是否自动定位到最后浏览图片（默认开启）。
  static Future<bool> getImageExitLocateEnabled() async {
    return instance._read((sp) => sp.getBool(_kImageExitLocateEnabled) ?? true);
  }

  static Future<void> setImageExitLocateEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kImageExitLocateEnabled, v));
  }

  /// 是否自动进入上次选择的收藏夹（默认关闭）。
  static Future<bool> getAutoEnterLastFavorite() async {
    return instance._read((sp) => sp.getBool(_kAutoEnterLastFavorite) ?? false);
  }

  static Future<void> setAutoEnterLastFavorite(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kAutoEnterLastFavorite, v));
  }

  static Future<bool> getEmbyExclusiveFavoritesUiEnabled() async {
    return instance._read(
      (sp) => sp.getBool(_kEmbyExclusiveFavoritesUiEnabled) ?? false,
    );
  }

  static Future<void> setEmbyExclusiveFavoritesUiEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kEmbyExclusiveFavoritesUiEnabled, v),
    );
  }

  static Future<String?> getLastFavoriteId() async {
    return instance._read((sp) {
      final v = sp.getString(_kLastFavoriteId);
      if (v == null || v.trim().isEmpty) return null;
      return v;
    });
  }

  static Future<void> setLastFavoriteId(String? id) async {
    await _writeAndNotify((sp) async {
      if (id == null || id.trim().isEmpty) {
        await sp.remove(_kLastFavoriteId);
        return;
      }
      await sp.setString(_kLastFavoriteId, id.trim());
    });
  }

  /// 收藏夹：每个目录独立记忆视图/排序/升降序（默认关闭）。
  static Future<bool> getFavoritePerDirectoryDisplaySettingsEnabled() async {
    return instance._read(
      (sp) => sp.getBool(_kFavoritePerDirectoryDisplaySettingsEnabled) ?? false,
    );
  }

  static Future<void> setFavoritePerDirectoryDisplaySettingsEnabled(
      bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kFavoritePerDirectoryDisplaySettingsEnabled, v),
    );
  }

  /// 收藏夹目录显示状态（按目录记忆的视图/排序/升降序）。
  /// - key: 目录唯一标识（如 local://... / webdav://... / emby://...）
  /// - value: LayerSettings 的 json（v/s/a）
  static Future<Map<String, dynamic>>
      getFavoritePerDirectoryDisplaySettingsState() async {
    return instance._read((sp) {
      final raw = sp.getString(_kFavoritePerDirectoryDisplaySettingsState);
      if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
      try {
        final j = jsonDecode(raw);
        if (j is! Map) return <String, dynamic>{};
        return j.cast<String, dynamic>();
      } catch (_) {
        return <String, dynamic>{};
      }
    });
  }

  static Future<void> setFavoritePerDirectoryDisplaySettingsState(
      Map<String, dynamic> data) async {
    await _writeAndNotify((sp) async {
      if (data.isEmpty) {
        await sp.remove(_kFavoritePerDirectoryDisplaySettingsState);
        return;
      }
      await sp.setString(
        _kFavoritePerDirectoryDisplaySettingsState,
        jsonEncode(data),
      );
    });
  }

  /// 历史记录开关（默认开启）。
  static Future<bool> getHistoryEnabled() async {
    return instance._read((sp) => sp.getBool(_kHistoryEnabled) ?? true);
  }

  // ⚠️ 已移除：get/setHistoryRecordFolderOnImageOpen

  static Future<void> setHistoryEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kHistoryEnabled, v));
  }

  static Future<bool> getTagEnabled() async {
    return instance._read((sp) => sp.getBool(_kTagEnabled) ?? true);
  }

  static Future<void> setTagEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kTagEnabled, v));
  }

  static Future<String> getFolderSearchScope() async {
    return instance._read((sp) {
      final raw = (sp.getString(_kFolderSearchScope) ?? '').trim();
      const allowed = <String>{
        'currentDirectory',
        'currentCollection',
        'allCollections',
        'singleCollection',
      };
      if (!allowed.contains(raw)) return 'currentCollection';
      return raw;
    });
  }

  static Future<void> setFolderSearchScope(String value) async {
    await _writeAndNotify((sp) {
      const allowed = <String>{
        'currentDirectory',
        'currentCollection',
        'allCollections',
        'singleCollection',
      };
      final v = allowed.contains(value) ? value : 'currentCollection';
      return sp.setString(_kFolderSearchScope, v);
    });
  }

  static Future<String?> getFolderSearchSingleCollectionId() async {
    return instance._read((sp) {
      final v = (sp.getString(_kFolderSearchSingleCollectionId) ?? '').trim();
      if (v.isEmpty) return null;
      return v;
    });
  }

  static Future<void> setFolderSearchSingleCollectionId(String? id) async {
    await _writeAndNotify((sp) async {
      final v = (id ?? '').trim();
      if (v.isEmpty) {
        await sp.remove(_kFolderSearchSingleCollectionId);
        return;
      }
      await sp.setString(_kFolderSearchSingleCollectionId, v);
    });
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
  static const Duration _kSaveDebounce = Duration(milliseconds: 350);

  static List<Map<String, dynamic>>? _cache;
  static Future<void>? _loadFuture;
  static Timer? _saveTimer;
  static Future<void> _writeQueue = Future<void>.value();
  static bool _dirty = false;

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static List<Map<String, dynamic>> _cloneList(
    List<Map<String, dynamic>> list,
  ) {
    return list.map((e) => Map<String, dynamic>.from(e)).toList(growable: true);
  }

  static Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final pending = _loadFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = () async {
      final sp = await _sp();
      final raw = sp.getString(_kHistoryKey);
      if (raw == null || raw.trim().isEmpty) {
        _cache = <Map<String, dynamic>>[];
        return;
      }
      try {
        final j = jsonDecode(raw);
        if (j is! List) {
          _cache = <Map<String, dynamic>>[];
          return;
        }
        final list =
            j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        final normalized = _normalize(list);
        _cache = normalized;
        if (normalized.length != list.length) {
          _scheduleSave();
        }
      } catch (_) {
        _cache = <Map<String, dynamic>>[];
      }
    }();

    _loadFuture = future;
    try {
      await future;
    } finally {
      if (identical(_loadFuture, future)) {
        _loadFuture = null;
      }
    }
  }

  static Future<void> _persistSnapshot(List<Map<String, dynamic>> list) async {
    final sp = await _sp();
    if (list.isEmpty) {
      await sp.remove(_kHistoryKey);
      return;
    }
    await sp.setString(_kHistoryKey, jsonEncode(list));
  }

  static void _scheduleSave() {
    if (_cache == null) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_kSaveDebounce, () {
      unawaited(_flushDirty());
    });
  }

  static Future<void> _flushDirty() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty || _cache == null) return;

    final snapshot = _cloneList(_cache!);
    _dirty = false;
    final write = _writeQueue.then((_) => _persistSnapshot(snapshot));
    _writeQueue = write.catchError((_) {});
    await write;

    if (_dirty && _saveTimer == null) {
      _scheduleSave();
    }
  }

  @visibleForTesting
  static Future<void> debugResetForTest() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _cache = null;
    _loadFuture = null;
    _dirty = false;
    _writeQueue = Future<void>.value();
  }

  static Future<List<Map<String, dynamic>>> load() async {
    await _ensureLoaded();
    return _cloneList(_cache ?? const <Map<String, dynamic>>[]);
  }

  static List<Map<String, dynamic>> _normalize(
      List<Map<String, dynamic>> list) {
    if (list.length < 2) return list;

    const int windowMs = 10 * 1000; // 10s: 足够覆盖“点开即播放”的场景，且不至于误删太多。

    bool isEmbyPath(String p) => p.startsWith('emby://');
    bool isWebDavPath(String p) => p.startsWith('webdav://');

    String hostOf(String p) {
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
              if (ctxKind == 'emby' && isEmbyPath(prevPath)) {
                final accId = (cur['embyAccountId'] ?? '').toString();
                if (accId.isNotEmpty && hostOf(prevPath) == accId) {
                  drop = true;
                }
              }

              // WebDAV：同账号即可认为同一来源
              if (ctxKind == 'webdav' && isWebDavPath(prevPath)) {
                final accId = (cur['wdAccountId'] ?? '').toString();
                if (accId.isNotEmpty && hostOf(prevPath) == accId) {
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
    await _ensureLoaded();
    final list = _cache!;

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

    _scheduleSave();
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
    required AppHistoryFolderCtx ctx,
    required String title,
    String? coverPath,
  }) async {
    try {
      final kind = ctx.kind.trim();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!await AppSettings.getHistoryEnabled()) return;

      await _ensureLoaded();
      final list = _cache!;

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
        var rel = ctx.wdRel.trim();
        if (accId.isEmpty) return;
        if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
        path = 'folder://webdav/$accId/$rel';
        entry['ctxKind'] = 'webdav';
        entry['wdAccountId'] = accId;
        entry['wdRel'] = rel;
      } else if (kind.contains('emby')) {
        final accId = (ctx.embyAccountId ?? '').toString().trim();
        final pth = ctx.embyPath.trim();
        if (accId.isEmpty) return;
        path = 'folder://emby/$accId/${pth.isEmpty ? 'favorites' : pth}';
        entry['ctxKind'] = 'emby';
        entry['embyAccountId'] = accId;
        entry['embyPath'] = pth.isEmpty ? 'favorites' : pth;
      } else {
        return;
      }

      entry['path'] = path;
      if (coverPath != null && coverPath.trim().isNotEmpty) {
        entry['cover'] = coverPath;
      }

      list.removeWhere((e) => (e['path'] ?? '') == path);
      list.insert(0, entry);
      if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
      _scheduleSave();
    } catch (_) {
      // 历史增强是“锦上添花”，失败不影响主流程。
    }
  }

  static Future<void> removeAt(int index) async {
    await _ensureLoaded();
    final list = _cache!;
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    _scheduleSave();
    await _flushDirty();
  }

  static Future<void> clear() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _cache = <Map<String, dynamic>>[];
    _dirty = false;
    final write = _writeQueue.then((_) async {
      final sp = await _sp();
      await sp.remove(_kHistoryKey);
    });
    _writeQueue = write.catchError((_) {});
    await write;
  }

  /// 更新已有记录的进度（如果记录不存在则忽略）。
  static Future<void> updateProgress(
      {required String path, required int positionMs}) async {
    if (path.trim().isEmpty) return;
    if (!await AppSettings.getHistoryEnabled()) return;

    await _ensureLoaded();
    final list = _cache!;
    final idx = list.indexWhere((e) => (e['path'] ?? '') == path);
    if (idx < 0) return;
    list[idx]['pos'] = positionMs;
    _scheduleSave();
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
    final normalizedExt = ext.trim();
    final safeExt = normalizedExt.isEmpty
        ? ''
        : (normalizedExt.startsWith('.') ? normalizedExt : '.$normalizedExt');
    return File(p.join(dir.path, '$key$safeExt'));
  }
}

/// ===============================
/// Thumb Cache (重构版)
/// ===============================
class ThumbCache {
  static final Map<String, Future<File?>> _inflight = {};
  static final Map<String, int> _failedUntilMs = <String, int>{};
  static const int _failureCooldownMs = 2 * 60 * 1000;

  static bool _looksRemoteSource(String path) {
    final p = path.trim().toLowerCase();
    return p.startsWith('http://') ||
        p.startsWith('https://') ||
        p.startsWith('webdav://') ||
        p.startsWith('emby://');
  }

  static bool _isFailureCoolingDown(String key) {
    final until = _failedUntilMs[key];
    if (until == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= now) {
      _failedUntilMs.remove(key);
      return false;
    }
    return true;
  }

  static void _rememberFailure(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _failedUntilMs[key] = now + _failureCooldownMs;
  }

  static void _clearFailure(String key) {
    _failedUntilMs.remove(key);
  }

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

    if (_isFailureCoolingDown(key)) return null;

    if (_looksRemoteSource(videoPath)) {
      _rememberFailure(key);
      return null;
    }

    // 从 'thumbs' 目录获取文件
    final out = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');

    // 1. 检查本地是否已有缓存（永久存在）
    if (await out.exists() && await out.length() > 0) {
      _clearFailure(key);
      return out;
    }

    try {
      final f = File(videoPath);
      if (!await f.exists()) {
        _rememberFailure(key);
        return null;
      }
    } catch (_) {
      _rememberFailure(key);
      return null;
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
        _clearFailure(key);
        return out;
      } catch (e) {
        AppLogger.error('thumbnail generation failed', error: e, tag: 'thumb');
        _rememberFailure(key);
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
      {String? customName, Map<String, String>? headers}) async {
    final ext = p.extension(customName ?? webDavUrl).toLowerCase();
    final key = PersistentStore.instance.makeKey(webDavUrl);

    // 存放在 'media' 子目录
    final file = await PersistentStore.instance.getFile(key, 'media', ext);

    if (await file.exists()) {
      AppLogger.info('webdav cache hit: ${redactSensitiveText(file.path)}',
          tag: 'cache');
      return file;
    }

    AppLogger.info('downloading webdav asset: $webDavUrl', tag: 'cache');

    final uri = Uri.parse(webDavUrl);
    final requestHeaders = <String, String>{
      if (headers != null) ...headers,
    };
    final userInfo = uri.userInfo.trim();
    if (userInfo.isNotEmpty &&
        !requestHeaders.containsKey(HttpHeaders.authorizationHeader)) {
      final token = base64Encode(utf8.encode(userInfo));
      requestHeaders[HttpHeaders.authorizationHeader] = 'Basic $token';
    }

    final tmp = File('${file.path}.download');
    if (await tmp.exists()) {
      await tmp.delete();
    }

    final client = HttpClientFactory.createForeground();
    IOSink? sink;
    try {
      final request = await NetworkRunner.run(
        () => client.getUrl(uri),
        label: 'webdav-cache-open',
      );
      requestHeaders.forEach(request.headers.set);
      final response = await NetworkRunner.run(
        () => request.close(),
        label: 'webdav-cache-close',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'WebDAV download failed: ${response.statusCode}',
          uri: uri,
        );
      }

      sink = tmp.openWrite();
      await response.pipe(sink);
      await sink.close();
      sink = null;

      if (await tmp.length() <= 0) {
        throw const HttpException('WebDAV download produced empty file');
      }

      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);

      AppLogger.info(
          'webdav download complete: ${redactSensitiveText(file.path)}',
          tag: 'cache');
      return file;
    } catch (_) {
      if (sink != null) {
        await sink.close();
      }
      if (await tmp.exists()) {
        await tmp.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
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
  static const Object _nullSentinel = Object();

  /// 最大缓存条目数（按需调整）
  static const int maxEntries = 400;

  final Map<String, Future<dynamic>> _inflight = {};
  final LinkedHashMap<String, dynamic> _lru = LinkedHashMap();

  T? getResult<T>(String key) {
    if (!_lru.containsKey(key)) return null;
    final v = _lru.remove(key);
    // refresh LRU
    _lru[key] = v;
    if (identical(v, _nullSentinel)) return null;
    return v as T;
  }

  Future<T?> getOrCreate<T>(String key, Future<T?> Function() loader,
      {bool cacheNull = false}) {
    if (_lru.containsKey(key)) {
      return Future<T?>.value(getResult<T>(key));
    }

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
    _lru[key] = value ?? _nullSentinel;
  }

  /// 为 sources 生成稳定 key（避免 key 过长）
  static String keyForSources(List<String> sources) {
    final joined = sources.join('|');
    return sha1.convert(utf8.encode(joined)).toString();
  }
}

@visibleForTesting
void debugResetThumbCacheFailures() {
  ThumbCache._failedUntilMs.clear();
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
  return core_redaction.redactSensitiveText(input);
}
