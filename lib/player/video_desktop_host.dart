part of '../video.dart';

class _DesktopVideoPlayerHost extends StatefulWidget {
  final List<String> videoPaths;
  final int initialIndex;

  const _DesktopVideoPlayerHost({
    required this.videoPaths,
    required this.initialIndex,
  });

  @override
  State<_DesktopVideoPlayerHost> createState() => _VideoPlayerPageState();
}
