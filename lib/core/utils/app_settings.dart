import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  SharedPreferences? _prefs;
  bool _initialized = false;
  Future<void>? _initFuture;

  static const String _kPrefix = 'glacier_settings_';
  static const String _kSubtitleFontSize = '${_kPrefix}subtitle_font_size';
  static const String _kSubtitleBottomOffset =
      '${_kPrefix}subtitle_bottom_offset';
  static const String _kSubtitleBackgroundOpacity =
      '${_kPrefix}subtitle_background_opacity';
  static const String _kSubtitleOutlineEnabled =
      '${_kPrefix}subtitle_outline_enabled';
  static const String _kDoubleTapSeekSeconds =
      '${_kPrefix}double_tap_seek_seconds';
  static const String _kLongPressSpeedMultiplier =
      '${_kPrefix}long_press_speed_multiplier';
  static const String _kLongPressSpeedEnabled =
      '${_kPrefix}long_press_speed_enabled';
  static const String _kVideoAutoNextAfterEnd =
      '${_kPrefix}video_auto_next_after_end';
  static const String _kVideoMiniProgressWhenHidden =
      '${_kPrefix}video_mini_progress_when_hidden';
  static const String _kVideoCatalogEnabled =
      '${_kPrefix}video_catalog_enabled';
  static const String _kVideoEpisodeNavButtonsEnabled =
      '${_kPrefix}video_episode_nav_buttons_enabled';
  static const String _kVideoLockPauseSeekEnabled =
      '${_kPrefix}video_lock_pause_seek_enabled';
  static const String _kVideoCatalogLocateCurrentOnOpen =
      '${_kPrefix}video_catalog_locate_current_on_open';
  static const String _kEmbyImageDominantThresholdPercent =
      '${_kPrefix}emby_image_dominant_threshold_percent';
  static const String _kEmbyImageLibrarySimpleModeEnabled =
      '${_kPrefix}emby_image_library_simple_mode_enabled';
  static const String _kVideoResumeEnabled = '${_kPrefix}video_resume_enabled';
  static const String _kVideoResumeHintEnabled =
      '${_kPrefix}video_resume_hint_enabled';
  static const String _kImageVolumeKeyPaging =
      '${_kPrefix}image_volume_key_paging';
  static const String _kImageExitLocateEnabled =
      '${_kPrefix}image_exit_locate_enabled';
  static const String _kAutoEnterLastFavorite =
      '${_kPrefix}auto_enter_last_favorite';
  static const String _kLastFavoriteId = '${_kPrefix}last_favorite_id';
  static const String _kFavoritePerDirectoryDisplaySettingsEnabled =
      '${_kPrefix}favorite_per_directory_display_settings_enabled';
  static const String _kFavoritePerDirectoryDisplaySettingsState =
      '${_kPrefix}favorite_per_directory_display_settings_state_v1';
  static const String _kEmbyExclusiveFavoritesUiEnabled =
      '${_kPrefix}emby_exclusive_favorites_ui_enabled';
  static const String _kHistoryEnabled = '${_kPrefix}history_enabled';
  static const String _kTagEnabled = '${_kPrefix}tag_enabled';
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

  static Future<double> getSubtitleFontSize() async {
    return instance._read((sp) => sp.getDouble(_kSubtitleFontSize) ?? 22.0);
  }

  static Future<void> setSubtitleFontSize(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kSubtitleFontSize, v.clamp(12.0, 48.0)),
    );
  }

  static Future<double> getSubtitleBottomOffset() async {
    return instance._read((sp) => sp.getDouble(_kSubtitleBottomOffset) ?? 36.0);
  }

  static Future<void> setSubtitleBottomOffset(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kSubtitleBottomOffset, v.clamp(0.0, 200.0)),
    );
  }

  static Future<double> getSubtitleBackgroundOpacity() async {
    return instance._read(
      (sp) => sp.getDouble(_kSubtitleBackgroundOpacity) ?? 0.55,
    );
  }

  static Future<void> setSubtitleBackgroundOpacity(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kSubtitleBackgroundOpacity, v.clamp(0.0, 1.0)),
    );
  }

  static Future<bool> getSubtitleOutlineEnabled() async {
    return instance._read((sp) => sp.getBool(_kSubtitleOutlineEnabled) ?? true);
  }

  static Future<void> setSubtitleOutlineEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kSubtitleOutlineEnabled, v));
  }

  static Future<int> getDoubleTapSeekSeconds() async {
    return instance._read((sp) => sp.getInt(_kDoubleTapSeekSeconds) ?? 10);
  }

  static Future<void> setDoubleTapSeekSeconds(int v) async {
    await _writeAndNotify(
      (sp) => sp.setInt(_kDoubleTapSeekSeconds, v.clamp(5, 60)),
    );
  }

  static Future<bool> getLongPressSpeedEnabled() async {
    return instance._read((sp) => sp.getBool(_kLongPressSpeedEnabled) ?? true);
  }

  static Future<void> setLongPressSpeedEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kLongPressSpeedEnabled, v));
  }

  static Future<double> getLongPressSpeedMultiplier() async {
    return instance
        ._read((sp) => sp.getDouble(_kLongPressSpeedMultiplier) ?? 2.0);
  }

  static Future<void> setLongPressSpeedMultiplier(double v) async {
    await _writeAndNotify(
      (sp) => sp.setDouble(_kLongPressSpeedMultiplier, v.clamp(1.25, 4.0)),
    );
  }

  static Future<bool> getVideoAutoNextAfterEnd() async {
    return instance._read((sp) => sp.getBool(_kVideoAutoNextAfterEnd) ?? false);
  }

  static Future<void> setVideoAutoNextAfterEnd(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoAutoNextAfterEnd, v));
  }

  static Future<bool> getVideoMiniProgressWhenHidden() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoMiniProgressWhenHidden) ?? true);
  }

  static Future<void> setVideoMiniProgressWhenHidden(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoMiniProgressWhenHidden, v),
    );
  }

  static Future<bool> getVideoCatalogEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoCatalogEnabled) ?? true);
  }

  static Future<void> setVideoCatalogEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoCatalogEnabled, v));
  }

  static Future<bool> getVideoEpisodeNavButtonsEnabled() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoEpisodeNavButtonsEnabled) ?? true);
  }

  static Future<void> setVideoEpisodeNavButtonsEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoEpisodeNavButtonsEnabled, v),
    );
  }

  static Future<bool> getVideoLockPauseSeekEnabled() async {
    return instance
        ._read((sp) => sp.getBool(_kVideoLockPauseSeekEnabled) ?? true);
  }

  static Future<void> setVideoLockPauseSeekEnabled(bool v) async {
    await _writeAndNotify(
      (sp) => sp.setBool(_kVideoLockPauseSeekEnabled, v),
    );
  }

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

  static Future<bool> getVideoResumeEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoResumeEnabled) ?? true);
  }

  static Future<void> setVideoResumeEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoResumeEnabled, v));
  }

  static Future<bool> getVideoResumeHintEnabled() async {
    return instance._read((sp) => sp.getBool(_kVideoResumeHintEnabled) ?? true);
  }

  static Future<void> setVideoResumeHintEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kVideoResumeHintEnabled, v));
  }

  static Future<bool> getImageVolumeKeyPaging() async {
    return instance._read((sp) => sp.getBool(_kImageVolumeKeyPaging) ?? false);
  }

  static Future<void> setImageVolumeKeyPaging(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kImageVolumeKeyPaging, v));
  }

  static Future<bool> getImageExitLocateEnabled() async {
    return instance._read((sp) => sp.getBool(_kImageExitLocateEnabled) ?? true);
  }

  static Future<void> setImageExitLocateEnabled(bool v) async {
    await _writeAndNotify((sp) => sp.setBool(_kImageExitLocateEnabled, v));
  }

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

  static Future<bool> getHistoryEnabled() async {
    return instance._read((sp) => sp.getBool(_kHistoryEnabled) ?? true);
  }

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
