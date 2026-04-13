import 'package:shared_preferences/shared_preferences.dart';

class AppFeatureFlags {
  AppFeatureFlags._();

  static const String _prefix = 'glacier_feature_flag_';
  static const String videoSourceResolve = '${_prefix}video_source_resolve';
  static const String rangeDownload = '${_prefix}range_download';
  static const String coverCache = '${_prefix}cover_cache';
  static const String resumePlayback = '${_prefix}resume_playback';

  static Future<bool> isEnabled(String key, {bool defaultValue = true}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? defaultValue;
  }

  static Future<void> setEnabled(String key, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, enabled);
  }
}
