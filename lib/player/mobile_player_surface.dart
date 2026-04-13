part of '../video.dart';

class _MobileCatalogSheet extends StatelessWidget {
  const _MobileCatalogSheet({
    required this.height,
    required this.controller,
    required this.itemExtent,
    required this.itemCount,
    required this.itemBuilder,
  });

  final double height;
  final ScrollController controller;
  final double itemExtent;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: height,
        child: ListView.builder(
          controller: controller,
          itemExtent: itemExtent,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }
}

extension _MobilePlayerSurface on _MobileVideoPlayerPageState {
  Widget _buildMobileControlsPanel({
    required BuildContext context,
    required bool initialized,
    required double currentMs,
    required double bufferedMs,
    required int maxMs,
    required Duration duration,
    required bool playing,
    required bool showEpisodeNavButtons,
    required VideoPlayerController? controller,
    required void Function(double value) onSeekChanged,
  }) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 4, 10, 6),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x88000000), Color(0x00000000)],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      await _beforeRouteExit(reason: 'mobile back button');
                      if (!mounted) return;
                      final popped = await navigator.maybePop();
                      if (!popped && mounted) {
                        _exitCleanupDone = false;
                      }
                    },
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: initialized ? _showSubtitleMenu : null,
                    icon: const Icon(Icons.closed_caption, color: Colors.white),
                  ),
                  IconButton(
                    onPressed: _canOpenCatalogMenu ? _showCatalogMenu : null,
                    icon: const Icon(Icons.playlist_play, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        _fmt(Duration(milliseconds: currentMs.round())),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2.6,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            secondaryActiveTrackColor: Colors.white38,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                          ),
                          child: Slider(
                            value: currentMs,
                            secondaryTrackValue: max(currentMs, bufferedMs)
                                .clamp(0.0, maxMs.toDouble()),
                            min: 0,
                            max: maxMs.toDouble(),
                            onChanged: initialized
                                ? (v) {
                                    onSeekChanged(v);
                                    _beginGestureOverlay(
                                      _fmt(Duration(milliseconds: v.round())),
                                      Icons.drag_handle_rounded,
                                    );
                                  }
                                : null,
                            onChangeEnd: initialized
                                ? (v) async {
                                    _draggingSeek = false;
                                    await controller?.seekTo(
                                      Duration(milliseconds: v.round()),
                                    );
                                    _scheduleAutoHide();
                                    unawaited(_reportEmbyProgress(
                                      eventName: 'TimeUpdate',
                                      interactive: true,
                                    ));
                                    _endGestureOverlay();
                                  }
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _fmt(duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const SizedBox(width: 42, height: 42),
                      Expanded(
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showEpisodeNavButtons)
                                SizedBox(
                                  width: 42,
                                  height: 42,
                                  child: IconButton(
                                    onPressed: _canPrev ? _prev : null,
                                    iconSize: 22,
                                    color: Colors.white,
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(Icons.skip_previous),
                                  ),
                                ),
                              SizedBox(
                                width: 42,
                                height: 42,
                                child: IconButton(
                                  onPressed:
                                      initialized ? _togglePlayPause : null,
                                  iconSize: 22,
                                  color: Colors.white,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    playing ? Icons.pause : Icons.play_arrow,
                                  ),
                                ),
                              ),
                              if (showEpisodeNavButtons)
                                SizedBox(
                                  width: 42,
                                  height: 42,
                                  child: IconButton(
                                    onPressed: _canNext ? _next : null,
                                    iconSize: 22,
                                    color: Colors.white,
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(Icons.skip_next),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        height: 42,
                        child: TextButton(
                          onPressed: initialized ? _showSpeedMenu : null,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            '${_rate.toStringAsFixed((_rate % 1) == 0 ? 0 : 2)}x',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
