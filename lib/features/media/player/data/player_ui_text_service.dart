import 'dart:math';

import 'play_source_resolver.dart';

class PlayerUiTextService {
  PlayerUiTextService._();

  static String catalogLoadingMessage({required bool initialExpansion}) {
    return initialExpansion ? '正在加载同目录视频...' : '正在刷新目录...';
  }

  static String openingLabel({required bool hasExistingController}) {
    return hasExistingController ? '正在切换视频' : '正在准备视频';
  }

  static String switchingLabel(String source) {
    return '正在切换到 ${PlayerSourceResolver.displayName(source)}';
  }

  static String resumeHintText(Duration position) {
    final totalSeconds = max(0, position.inSeconds);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    String two(int value) => value.toString().padLeft(2, '0');
    final formatted = hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
    return '从 $formatted 继续播放';
  }
}
