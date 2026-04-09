part of '../video.dart';

class _DesktopOrientationState {
  bool isFullscreen = false;
  bool isScreenLocked = false;
  NativeDeviceOrientation appliedNativeOri = NativeDeviceOrientation.unknown;
  NativeDeviceOrientation? lastOriCandidate;
  int oriStableCount = 0;
  DateTime lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);
  int videoQuarterTurns = 0;
  bool autoRotateEnabled = true;
}

class _DesktopSubtitleState {
  List<String> srtCandidates = <String>[];
  String? srtSelected;
  bool srtEnabled = false;
  List<EmbySubtitleTrack> embySubtitleCandidates = <EmbySubtitleTrack>[];
  EmbySubtitleTrack? embySubtitleSelected;
  String? lastAutoSubtitleItemId;
}

class _DesktopReporterState {
  _EmbyPlaybackSession? embyPlayback;
  Timer? embyProgressTimer;
  Future<void> embyReportQueue = Future.value();
  DateTime embyLastInteractiveReportAt = DateTime.fromMillisecondsSinceEpoch(0);
}

class _DesktopGestureState {
  bool active = false;
  String type = '';
  String text = '';
  IconData? icon;
  Duration dragStartPos = Duration.zero;
  Duration dragTargetPos = Duration.zero;
}

class _DesktopGestureOverlayViewData {
  final bool active;
  final String text;
  final IconData? icon;

  const _DesktopGestureOverlayViewData({
    required this.active,
    required this.text,
    required this.icon,
  });

  const _DesktopGestureOverlayViewData.inactive()
      : active = false,
        text = '',
        icon = null;
}

class _MobileOrientationState {
  bool isScreenLocked = false;
  bool autoRotateEnabled = true;
  NativeDeviceOrientation appliedNativeOri = NativeDeviceOrientation.unknown;
  NativeDeviceOrientation? lastOriCandidate;
  int oriStableCount = 0;
  DateTime lastOriApplyAt = DateTime.fromMillisecondsSinceEpoch(0);
}

class _MobileGestureState {
  bool active = false;
  String type = '';
  String text = '';
  IconData? icon;
  Duration dragStartPos = Duration.zero;
  Duration dragTargetPos = Duration.zero;
  double? rateBeforeLongPress;
  Offset? lastDoubleTapPos;
}

class _MobileGestureOverlayViewData {
  final bool active;
  final String text;
  final IconData? icon;

  const _MobileGestureOverlayViewData({
    required this.active,
    required this.text,
    required this.icon,
  });

  const _MobileGestureOverlayViewData.inactive()
      : active = false,
        text = '',
        icon = null;
}

class _MobileReporterState {
  _EmbyPlaybackSession? embyPlayback;
  Timer? embyProgressTimer;
  Future<void> embyReportQueue = Future.value();
  DateTime embyLastInteractiveReportAt = DateTime.fromMillisecondsSinceEpoch(0);
}

class _MobileSubtitleState {
  List<EmbySubtitleTrack> embySubtitleCandidates = <EmbySubtitleTrack>[];
  EmbySubtitleTrack? embySubtitleSelected;
  List<String> localSubtitleCandidates = <String>[];
  String? localSubtitleSelected;
  String? lastAutoSubtitleKey;
}

class _MobileHudViewData {
  final bool ready;
  final bool opening;
  final bool buffering;
  final String? error;

  const _MobileHudViewData({
    required this.ready,
    required this.opening,
    required this.buffering,
    required this.error,
  });

  const _MobileHudViewData.initial()
      : ready = false,
        opening = false,
        buffering = false,
        error = null;
}
