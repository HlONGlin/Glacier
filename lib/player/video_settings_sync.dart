part of '../video.dart';

class _DesktopVideoSettingsValues {
  final double font;
  final double bottom;
  final double backgroundOpacity;
  final bool outlineEnabled;
  final bool longPressEnabled;
  final double longPressMultiplier;
  final bool miniProgress;
  final bool catalogEnabled;
  final bool autoNext;

  const _DesktopVideoSettingsValues({
    required this.font,
    required this.bottom,
    required this.backgroundOpacity,
    required this.outlineEnabled,
    required this.longPressEnabled,
    required this.longPressMultiplier,
    required this.miniProgress,
    required this.catalogEnabled,
    required this.autoNext,
  });
}

class _MobileVideoSettingsValues {
  final double subtitleFont;
  final double subtitleBottom;
  final double subtitleBackgroundOpacity;
  final bool subtitleOutlineEnabled;
  final bool longPressEnabled;
  final double longPressMultiplier;
  final bool autoNext;
  final bool resumeEnabled;
  final bool miniProgress;
  final bool catalogEnabled;
  final bool episodeNavButtonsEnabled;
  final bool lockPauseSeekEnabled;
  final bool catalogLocateCurrentOnOpen;
  final int doubleTapSeekSeconds;

  const _MobileVideoSettingsValues({
    required this.subtitleFont,
    required this.subtitleBottom,
    required this.subtitleBackgroundOpacity,
    required this.subtitleOutlineEnabled,
    required this.longPressEnabled,
    required this.longPressMultiplier,
    required this.autoNext,
    required this.resumeEnabled,
    required this.miniProgress,
    required this.catalogEnabled,
    required this.episodeNavButtonsEnabled,
    required this.lockPauseSeekEnabled,
    required this.catalogLocateCurrentOnOpen,
    required this.doubleTapSeekSeconds,
  });
}

Future<_DesktopVideoSettingsValues> _loadDesktopVideoSettingsValues() async {
  final values = await Future.wait<Object?>([
    AppSettings.getSubtitleFontSize(),
    AppSettings.getSubtitleBottomOffset(),
    AppSettings.getSubtitleBackgroundOpacity(),
    AppSettings.getSubtitleOutlineEnabled(),
    AppSettings.getLongPressSpeedEnabled(),
    AppSettings.getLongPressSpeedMultiplier(),
    AppSettings.getVideoMiniProgressWhenHidden(),
    AppSettings.getVideoCatalogEnabled(),
    AppSettings.getVideoAutoNextAfterEnd(),
  ]);
  return _DesktopVideoSettingsValues(
    font: values[0] as double,
    bottom: values[1] as double,
    backgroundOpacity: values[2] as double,
    outlineEnabled: values[3] as bool,
    longPressEnabled: values[4] as bool,
    longPressMultiplier: values[5] as double,
    miniProgress: values[6] as bool,
    catalogEnabled: values[7] as bool,
    autoNext: values[8] as bool,
  );
}

Future<_MobileVideoSettingsValues> _loadMobileVideoSettingsValues() async {
  final values = await Future.wait<Object?>([
    AppSettings.getSubtitleFontSize(),
    AppSettings.getSubtitleBottomOffset(),
    AppSettings.getSubtitleBackgroundOpacity(),
    AppSettings.getSubtitleOutlineEnabled(),
    AppSettings.getLongPressSpeedEnabled(),
    AppSettings.getLongPressSpeedMultiplier(),
    AppSettings.getVideoAutoNextAfterEnd(),
    AppSettings.getVideoResumeEnabled(),
    AppSettings.getVideoMiniProgressWhenHidden(),
    AppSettings.getVideoCatalogEnabled(),
    AppSettings.getVideoEpisodeNavButtonsEnabled(),
    AppSettings.getVideoLockPauseSeekEnabled(),
    AppSettings.getVideoCatalogLocateCurrentOnOpen(),
    AppSettings.getDoubleTapSeekSeconds(),
  ]);
  return _MobileVideoSettingsValues(
    subtitleFont: values[0] as double,
    subtitleBottom: values[1] as double,
    subtitleBackgroundOpacity: values[2] as double,
    subtitleOutlineEnabled: values[3] as bool,
    longPressEnabled: values[4] as bool,
    longPressMultiplier: values[5] as double,
    autoNext: values[6] as bool,
    resumeEnabled: values[7] as bool,
    miniProgress: values[8] as bool,
    catalogEnabled: values[9] as bool,
    episodeNavButtonsEnabled: values[10] as bool,
    lockPauseSeekEnabled: values[11] as bool,
    catalogLocateCurrentOnOpen: values[12] as bool,
    doubleTapSeekSeconds: values[13] as int,
  );
}
