part of '../video.dart';

/// ===============================
/// Controls overlay（只负责“显示/隐藏”与 seekbar 预览）
/// ===============================

// ✅ 仅支持安卓手机：已移除桌面端控制层实现，避免无用代码引入编译问题。
class _MobileControlsOverlay extends StatefulWidget {
  final VideoState state;
  final Player player;
  final String currentVideoPath;

  final bool uiVisible;
  final VoidCallback onUserInteract;

  final double volume;
  final double rate;
  final bool isFullscreen;
  final bool isScreenLocked;

  /// 是否已启用字幕（用于按钮图标状态）
  final bool subtitlesEnabled;

  /// 播放结束行为：是否自动下一集。
  final bool autoNextAfterEnd;

  /// 控制栏隐藏时，是否显示底部细进度条。
  final bool showMiniProgressWhenHidden;

  /// 播放列表/目录
  final bool catalogEnabled;
  final int playlistCount;
  final int playlistIndex;
  final Future<void> Function() onShowCatalog;

  final Future<void> Function() onTogglePlayPause;
  final Future<void> Function() onToggleEndBehavior;
  final Future<void> Function() onShowSubtitles;
  final Future<void> Function(BuildContext buttonContext) onShowRate;

  const _MobileControlsOverlay({
    required this.state,
    required this.player,
    required this.currentVideoPath,
    required this.uiVisible,
    required this.onUserInteract,
    required this.volume,
    required this.rate,
    required this.isFullscreen,
    required this.isScreenLocked,
    required this.subtitlesEnabled,
    required this.autoNextAfterEnd,
    required this.showMiniProgressWhenHidden,
    required this.catalogEnabled,
    required this.playlistCount,
    required this.playlistIndex,
    required this.onShowCatalog,
    required this.onTogglePlayPause,
    required this.onToggleEndBehavior,
    required this.onShowSubtitles,
    required this.onShowRate,
  });

  @override
  State<_MobileControlsOverlay> createState() => _MobileControlsOverlayState();
}

class _MobileControlsOverlayState extends State<_MobileControlsOverlay> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _dragging = false;

  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _subs.add(widget.player.stream.position.listen((v) {
      if (!_dragging) {
        if (mounted) setState(() => _position = v);
      }
    }));
    _subs.add(widget.player.stream.duration.listen((v) {
      if (mounted) setState(() => _duration = v);
    }));
    _subs.add(widget.player.stream.buffer.listen((v) {
      if (mounted) setState(() => _buffer = v);
    }));
    _subs.add(widget.player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int x) => x.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isScreenLocked) return const SizedBox.shrink();

    final showControls = widget.uiVisible;
    final durationMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, max(0, durationMs));
    final bufMs = _buffer.inMilliseconds.clamp(0, max(0, durationMs));
    final bufferedValue = (durationMs > 0) ? (bufMs / durationMs) : 0.0;
    final playedValue = (durationMs > 0) ? (posMs / durationMs) : 0.0;

    final bottomBar = showControls
        ? Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(_fmt(_position),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                      Expanded(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              height: 2,
                              child: LinearProgressIndicator(
                                value: bufferedValue.clamp(0.0, 1.0),
                                backgroundColor: Colors.white12,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Colors.white24),
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: Colors.redAccent,
                                inactiveTrackColor: Colors.transparent,
                                thumbColor: Colors.redAccent,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                                trackShape: const _FullWidthSliderTrackShape(),
                                trackHeight: 2,
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14),
                              ),
                              child: Slider(
                                value: posMs
                                    .toDouble()
                                    .clamp(0, durationMs.toDouble()),
                                min: 0,
                                max: durationMs > 0
                                    ? durationMs.toDouble()
                                    : 1.0,
                                onChangeStart: (_) {
                                  widget.onUserInteract();
                                  setState(() => _dragging = true);
                                },
                                onChanged: (v) {
                                  widget.onUserInteract();
                                  setState(() => _position =
                                      Duration(milliseconds: v.toInt()));
                                },
                                onChangeEnd: (v) {
                                  widget.onUserInteract();
                                  setState(() => _dragging = false);
                                  widget.player
                                      .seek(Duration(milliseconds: v.toInt()));
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(_fmt(_duration),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          _playing ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onTogglePlayPause();
                        },
                      ),
                      const SizedBox(width: 6),
                      Builder(
                        builder: (ctx) {
                          return InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              widget.onUserInteract();
                              widget.onShowRate(ctx);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.speed,
                                      color: Colors.white70, size: 18),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${widget.rate}x',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
                      if (widget.catalogEnabled)
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            widget.onUserInteract();
                            widget.onShowCatalog();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.list_alt,
                                    color: Colors.white70, size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  '${(widget.playlistIndex + 1).clamp(1, widget.playlistCount)}/${widget.playlistCount}',
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const Spacer(),
                      IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          widget.autoNextAfterEnd
                              ? Icons.skip_next
                              : Icons.pause_circle_outline,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onToggleEndBehavior();
                        },
                      ),
                      IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          widget.subtitlesEnabled
                              ? Icons.subtitles
                              : Icons.subtitles_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          widget.onUserInteract();
                          widget.onShowSubtitles();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        : const SizedBox.shrink();

    final miniProgressBar =
        (!showControls && widget.showMiniProgressWhenHidden && durationMs > 0)
            ? Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 2,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(color: Colors.white10),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: bufferedValue.clamp(0.0, 1.0),
                            child: Container(color: Colors.white24),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: playedValue.clamp(0.0, 1.0),
                            child: Container(color: Colors.redAccent),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink();

    return Stack(
      children: [
        miniProgressBar,
        Positioned(left: 0, right: 0, bottom: 0, child: bottomBar),
      ],
    );
  }
}
