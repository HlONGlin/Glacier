part of '../video.dart';

void _showScopedSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  try {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: duration),
    );
  } catch (_) {
    // 某些情况下（如 context 不在 Scaffold 树下）SnackBar 会失败，这里静默忽略即可。
  }
}

extension _DesktopVideoFeedback on _VideoPlayerPageState {
  void _toast(String msg) {
    if (!mounted) return;
    _showScopedSnackBar(context, msg);
  }

  void _showDesktopErrorSnack(String msg) {
    if (!mounted) return;
    _showScopedSnackBar(context, msg);
  }
}

extension _MobileVideoFeedback on _MobileVideoPlayerPageState {
  void _showSnack(String msg) {
    if (!mounted) return;
    _showScopedSnackBar(context, msg);
  }
}
