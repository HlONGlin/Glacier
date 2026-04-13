part of '../video.dart';

class _MobileVideoPlayerHost extends StatefulWidget {
  final List<String> videoPaths;
  final int initialIndex;

  const _MobileVideoPlayerHost({
    required this.videoPaths,
    required this.initialIndex,
  });

  @override
  State<_MobileVideoPlayerHost> createState() => _MobileVideoPlayerPageState();
}
