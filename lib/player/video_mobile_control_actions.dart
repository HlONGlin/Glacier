part of '../video.dart';

double _normalizePlaybackRate(double next) {
  return next.clamp(0.25, 3.0).toDouble();
}

Duration _computeRelativeSeekTarget({
  required Duration current,
  required Duration duration,
  required int seconds,
}) {
  var target = current + Duration(seconds: seconds);
  if (target < Duration.zero) target = Duration.zero;
  if (duration > Duration.zero && target > duration) target = duration;
  return target;
}

Future<double?> _showMobileSpeedPicker(
  BuildContext context, {
  required double currentRate,
}) {
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    builder: (ctx) {
      const options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final r in options)
              ListTile(
                title: Text(
                  '${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 2)}x',
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: (currentRate - r).abs() < 0.001
                    ? const Icon(Icons.check, color: Colors.white)
                    : null,
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      );
    },
  );
}

extension _MobileVideoControlActions on _MobileVideoPlayerPageState {
  Future<void> _pauseMobilePlayback(VideoPlayerController controller) async {
    await controller.pause();
    _pageController.showControls();
    _pageController.cancelAutoHide();
    _showGestureOverlay('暂停', Icons.pause_rounded);
    unawaited(_reportEmbyProgress(eventName: 'Pause'));
  }

  Future<void> _resumeMobilePlayback(VideoPlayerController controller) async {
    await controller.play();
    _scheduleAutoHide();
    _showGestureOverlay('播放', Icons.play_arrow_rounded);
    unawaited(_reportEmbyProgress(eventName: 'Unpause'));
  }

  Future<void> _applyMobilePlaybackRate(
    VideoPlayerController controller,
    double rate,
  ) async {
    try {
      await controller.setPlaybackSpeed(rate);
    } catch (_) {}
  }

  void _reportMobilePlaybackRateChanged() {
    unawaited(
      _reportEmbyProgress(eventName: 'PlaybackRateChange', interactive: true),
    );
  }

  void _afterMobileRelativeSeek() {
    _scheduleAutoHide();
    unawaited(_reportEmbyProgress(eventName: 'TimeUpdate', interactive: true));
  }
}
