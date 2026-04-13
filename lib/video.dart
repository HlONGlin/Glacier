import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;
import 'tag.dart';
import 'core/utils/app_shared.dart';
import 'core/network/remote_media_cache.dart';
import 'image.dart';
import 'debug/inspector.dart';
import 'emby.dart';
import 'sources/refs.dart';
import 'dart:math';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:collection/collection.dart';

import 'features/media/player/data/play_source_resolver.dart';
import 'features/media/player/data/player_catalog_search_service.dart';
import 'features/media/player/data/player_emby_subtitle_service.dart';
import 'features/media/player/data/player_history_service.dart';
import 'features/media/player/data/player_local_subtitle_service.dart';
import 'features/media/player/data/player_ui_text_service.dart';
import 'features/media/player/data/text_download_service.dart';
import 'features/media/player/presentation/player_controller.dart'
    as player_presentation;
import 'core/network/http_client_factory.dart';
import 'core/network/network_runner.dart';
part 'player/video_state_groups.dart';
part 'player/mobile_controls_overlay.dart';
part 'player/player_controls_overlay.dart';
part 'player/mobile_reporter_subtitle_orientation.dart';
part 'player/desktop_reporter_subtitle_orientation.dart';
part 'player/player_gesture_handlers.dart';
part 'player/player_catalog_and_expansion.dart';
part 'player/mobile_player_surface.dart';
part 'player/desktop_player_surface.dart';
part 'player/video_settings_sync.dart';
part 'player/video_history_sync.dart';
part 'player/video_source_resolution.dart';
part 'player/video_feedback_helpers.dart';
part 'player/video_subtitle_helpers.dart';
part 'player/video_mobile_open_flow.dart';
part 'player/video_desktop_catalog_flow.dart';
part 'player/video_mobile_control_actions.dart';
part 'player/video_desktop_controls.dart';
part 'player/video_desktop_host.dart';
part 'player/video_mobile_host.dart';
part 'player/video_desktop_state.dart';
part 'player/video_mobile_state.dart';

const SystemUiOverlayStyle _kLightStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

// ===== media_video.dart (auto-grouped) =====

// --- from video.dart ---

/// ===============================
/// Video Module (Desktop-first) — PotPlayer-like (v3) [Merged]
///
/// ✅ 主体以“大版本”为主
/// ✅ 合入“WebDAV 播放源”解析（webdav://accountId/xxx -> http(s)://user:pass@...）
///
/// ✅ 主要功能
/// - 控制栏自动隐藏 + 鼠标指针自动隐藏（更快：~1.6~1.8s）
/// - 拖动进度条：只显示预览，不实时 seek；松手才 seek（更像 PotPlayer）
/// - 目录：弹出式浮层（更“pop”），不影响播放；支持快捷键 L / Ctrl+L
/// - 右键菜单：全屏/倍速/打开目录/快捷键说明
/// - 右上方“热区”：鼠标停留自动弹出目录
///
/// ✅ 快捷键（桌面）
/// Space / K：播放暂停
/// ← / →：后退/前进 5s
/// ↑ / ↓：音量 +/-5
/// F：进入/退出全屏
/// L / Ctrl+L：打开目录
/// Esc：退出全屏 或 关闭目录/菜单
/// ===============================

class _EmbyRef {
  final String accountId;
  final String itemId;
  const _EmbyRef({required this.accountId, required this.itemId});
}

/// Emby 播放上报会话信息。
///
/// ✅ 设计原因：
/// - Emby 的 /Sessions/Playing(Progress/Stopped) 需要 PlaySessionId + MediaSourceId。
/// - 这些值应尽量来自 PlaybackInfo（由服务端生成），这样服务端才能正确识别会话、
///   正确记录进度/观看状态，并在停止时更及时地释放转码资源。
class _EmbyPlaybackSession {
  final EmbyAccount account;
  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final int? audioStreamIndex;
  int? subtitleStreamIndex;

  _EmbyPlaybackSession({
    required this.account,
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.audioStreamIndex,
    required this.subtitleStreamIndex,
  });
}

class _PlayerInteractionPolicy {
  static bool canOpenCatalog({
    required bool hasPlaylist,
    required bool isScreenLocked,
    required bool catalogEnabled,
    required bool menuAlreadyOpen,
  }) {
    return hasPlaylist && !isScreenLocked && catalogEnabled && !menuAlreadyOpen;
  }

  static bool canUseSeekGestures({
    required bool isScreenLocked,
    required bool lockPauseSeekEnabled,
  }) {
    return !isScreenLocked || lockPauseSeekEnabled;
  }

  static bool canUseVerticalGestures({
    required bool isScreenLocked,
  }) {
    return !isScreenLocked;
  }

  static bool canUseLongPressSpeed({
    required bool isScreenLocked,
    required bool longPressSpeedEnabled,
  }) {
    return !isScreenLocked && longPressSpeedEnabled;
  }
}

class VideoPlayerPage extends StatelessWidget {
  final List<String> videoPaths;
  final int initialIndex;

  const VideoPlayerPage({
    super.key,
    required this.videoPaths,
    required this.initialIndex,
  });

  bool get _useMobilePlayer =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Widget build(BuildContext context) {
    if (_useMobilePlayer) {
      return _MobileVideoPlayerHost(
        videoPaths: videoPaths,
        initialIndex: initialIndex,
      );
    }
    return _DesktopVideoPlayerHost(
      videoPaths: videoPaths,
      initialIndex: initialIndex,
    );
  }
}

/// ===============================
/// 让 Slider 轨道“铺满”整个可用宽度
/// ===============================
/// 默认 Slider 会在两端留出 thumb 半径的 padding，导致进度条看起来像“有一小节没包进去”。
/// 这里重写 getPreferredRect，让轨道从 0 开始到最右侧结束。
class _FullWidthSliderTrackShape extends RoundedRectSliderTrackShape {
  const _FullWidthSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 2.0;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
