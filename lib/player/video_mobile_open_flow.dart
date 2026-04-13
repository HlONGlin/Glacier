part of '../video.dart';

Future<int?> _loadMobileResumePositionMs(String path) {
  return PlayerHistoryService.loadResumePositionMs(path);
}

Future<void> _runMobileExitCleanup({
  required String reason,
  required void Function() dismissResumeHint,
  required void Function() stopAutoRotate,
  required Future<void> Function() unlockOrientation,
  required Future<void> Function() pauseController,
  required Future<void> Function() flushHistoryProgress,
  required Future<void> Function() stopEmbyCheckIns,
  required void Function() resetAutoRotate,
}) async {
  dismissResumeHint();
  stopAutoRotate();
  resetAutoRotate();
  await unlockOrientation();
  await pauseController();
  await flushHistoryProgress();
  unawaited(stopEmbyCheckIns());
}

extension _MobileVideoOpenFlow on _MobileVideoPlayerPageState {
  String _mobileOpeningLabel({required bool hasExistingController}) {
    return PlayerUiTextService.openingLabel(
      hasExistingController: hasExistingController,
    );
  }

  Future<VideoPlayerController> _createMobileVideoController({
    required _MobileResolvedSource resolved,
    required double playbackRate,
    required double volume,
  }) async {
    late final VideoPlayerController controller;
    if (resolved.isLocal) {
      controller = VideoPlayerController.file(File(resolved.localPath!));
    } else {
      controller = VideoPlayerController.networkUrl(
        resolved.networkUri!,
        httpHeaders: resolved.headers,
      );
    }
    await controller.initialize();
    await controller.setLooping(false);
    await controller.setPlaybackSpeed(playbackRate);
    await controller.setVolume((volume / 100).clamp(0, 1).toDouble());
    return controller;
  }

  Future<int?> _seekMobileResumeIfNeeded({
    required VideoPlayerController controller,
    required int? resumeMs,
  }) async {
    if (resumeMs == null) return null;
    try {
      final durMs = controller.value.duration.inMilliseconds;
      final safeMaxMs = max(0, durMs - 1200);
      final targetMs = resumeMs.clamp(0, safeMaxMs);
      if (targetMs > 0) {
        await controller.seekTo(Duration(milliseconds: targetMs));
        return targetMs;
      }
    } catch (_) {}
    return null;
  }

  void _finishMobileOpenSuccess({
    required String source,
    required int? resumedAtMs,
  }) {
    unawaited(_syncOrientationFromSensor(force: true));
    _scheduleAutoHide();
    unawaited(_startEmbyPlaybackCheckInsIfNeeded(reason: 'mobile open'));
    unawaited(_prepareSubtitleForCurrent());
    _armHistoryRecordForCurrent();
    if (resumedAtMs != null && resumedAtMs > 0) {
      unawaited(_showResumeHint(resumedAtMs, source));
    }
  }

  String _mobileSwitchingLabel(String currentPath) {
    return PlayerUiTextService.switchingLabel(currentPath);
  }
}
