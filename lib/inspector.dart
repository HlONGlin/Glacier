import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_kit.dart';

// ===== playback_inspector_all.dart (auto-grouped) =====

// --- from playback_inspector.dart ---

enum ProxyEventKind {
  reqIn,
  respOut,
  remoteFetchStart,
  remoteFetchDone,
  meta,
  error,
}

@immutable
class ProxyEvent {
  final DateTime t;
  final ProxyEventKind kind;
  final String streamId;
  final String? range;
  final int? status;
  final int? bytes;
  final int? ms;
  final String? note;

  const ProxyEvent({
    required this.t,
    required this.kind,
    required this.streamId,
    this.range,
    this.status,
    this.bytes,
    this.ms,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        't': t.toIso8601String(),
        'kind': kind.name,
        'streamId': streamId,
        if (range != null) 'range': range,
        if (status != null) 'status': status,
        if (bytes != null) 'bytes': bytes,
        if (ms != null) 'ms': ms,
        if (note != null) 'note': note,
      };
}

/// Collects and broadcasts proxy events.
class ProxyInspector {
  ProxyInspector._();
  static final ProxyInspector I = ProxyInspector._();

  /// Performance Guard: Default to FALSE.
  /// Only enable when UI is visible to prevent main thread flooding.
  bool enabled = false;

  // Simple per-kind rate-limit (to avoid event storms).
  final Map<String, int> _lastEmitMs = <String, int>{};

  final ListQueue<ProxyEvent> _ring = ListQueue<ProxyEvent>();
  final StreamController<ProxyEvent> _ctrl =
      StreamController<ProxyEvent>.broadcast();

  int maxEvents = 4000;

  Stream<ProxyEvent> get stream => _ctrl.stream;

  void emit(ProxyEvent e) {
    if (!enabled) return;

    // Additional safety: rate limit super frequent events
    if (e.kind == ProxyEventKind.remoteFetchStart) {
      final key = '${e.streamId}:${e.kind.name}';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final last = _lastEmitMs[key];
      if (last != null && (nowMs - last) < 200) return;
      _lastEmitMs[key] = nowMs;
    }

    _ring.addLast(e);
    while (_ring.length > maxEvents) {
      _ring.removeFirst();
    }
    if (!_ctrl.isClosed && _ctrl.hasListener) _ctrl.add(e);
  }

  List<ProxyEvent> snapshot({Duration within = const Duration(seconds: 10)}) {
    final now = DateTime.now();
    final out = <ProxyEvent>[];
    for (final e in _ring) {
      if (now.difference(e.t) <= within) out.add(e);
    }
    return out;
  }

  int throughput({
    required ProxyEventKind kind,
    Duration window = const Duration(seconds: 5),
  }) {
    final now = DateTime.now();
    int sum = 0;
    for (final e in _ring) {
      if (e.kind != kind) continue;
      if (e.bytes == null) continue;
      if (now.difference(e.t) > window) continue;
      sum += e.bytes!;
    }
    final secs = window.inMilliseconds / 1000.0;
    if (secs <= 0) return 0;
    return (sum / secs).round();
  }
}

@immutable
class PlayerSample {
  final DateTime t;
  final Duration position;
  final bool playing;
  final bool buffering;
  final Duration buffer;
  final double rate;

  const PlayerSample({
    required this.t,
    required this.position,
    required this.playing,
    required this.buffering,
    required this.buffer,
    required this.rate,
  });

  Map<String, dynamic> toJson() => {
        't': t.toIso8601String(),
        'positionMs': position.inMilliseconds,
        'playing': playing,
        'buffering': buffering,
        'bufferMs': buffer.inMilliseconds,
        'rate': rate,
      };
}

class PlayerInspector {
  PlayerInspector._();
  static final PlayerInspector I = PlayerInspector._();

  final ListQueue<PlayerSample> _ring = ListQueue<PlayerSample>();
  final StreamController<PlayerSample> _ctrl =
      StreamController<PlayerSample>.broadcast();

  int maxSamples = 2000;

  Stream<PlayerSample> get stream => _ctrl.stream;

  void push(PlayerSample s) {
    _ring.addLast(s);
    while (_ring.length > maxSamples) {
      _ring.removeFirst();
    }
    if (!_ctrl.isClosed) _ctrl.add(s);
  }

  PlayerSample? latest() => _ring.isEmpty ? null : _ring.last;

  List<PlayerSample> snapshot({Duration within = const Duration(seconds: 10)}) {
    final now = DateTime.now();
    final out = <PlayerSample>[];
    for (final e in _ring) {
      if (now.difference(e.t) <= within) out.add(e);
    }
    return out;
  }
}

enum StallKind {
  network,
  decodeOrRender,
  unknown,
}

@immutable
class StallReport {
  final DateTime start;
  final DateTime end;
  final Duration duration;
  final StallKind kind;
  final PlayerSample sample;
  final List<ProxyEvent> proxyContext;

  const StallReport({
    required this.start,
    required this.end,
    required this.duration,
    required this.kind,
    required this.sample,
    required this.proxyContext,
  });

  Map<String, dynamic> toJson() => {
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'kind': kind.name,
        'sample': sample.toJson(),
        'proxyContext': proxyContext.map((e) => e.toJson()).toList(),
      };
}

class StallDetector {
  StallDetector._();
  static final StallDetector I = StallDetector._();

  final StreamController<StallReport> _ctrl =
      StreamController<StallReport>.broadcast();
  Stream<StallReport> get stream => _ctrl.stream;

  StreamSubscription<PlayerSample>? _sub;
  Duration stallThreshold = const Duration(milliseconds: 700);
  Duration coolDown = const Duration(seconds: 2);

  Duration _lastPos = Duration.zero;
  DateTime _lastAdvanceAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _stallStart;

  void start() {
    _sub ??= PlayerInspector.I.stream.listen(_onSample);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _onSample(PlayerSample s) {
    final now = s.t;
    if (!s.playing) {
      _stallStart = null;
      _lastPos = s.position;
      _lastAdvanceAt = now;
      return;
    }

    if (s.position > _lastPos + const Duration(milliseconds: 120)) {
      _lastPos = s.position;
      _lastAdvanceAt = now;
      _stallStart = null;
      return;
    }

    final noAdvanceFor = now.difference(_lastAdvanceAt);
    if (noAdvanceFor < stallThreshold) return;

    _stallStart ??= _lastAdvanceAt;

    if (now.difference(_lastReportAt) < coolDown) return;

    final kind = s.buffering
        ? StallKind.network
        : (s.buffer > const Duration(milliseconds: 1500)
            ? StallKind.decodeOrRender
            : StallKind.unknown);

    final report = StallReport(
      start: _stallStart!,
      end: now,
      duration: now.difference(_stallStart!),
      kind: kind,
      sample: s,
      proxyContext:
          ProxyInspector.I.snapshot(within: const Duration(seconds: 8)),
    );

    _lastReportAt = now;
    if (!_ctrl.isClosed) _ctrl.add(report);
  }
}

// --- from playback_inspector_overlay.dart ---

/// A small overlay to inspect where stutters happen.
///
/// V4 Optimization:
/// - STRICT UI Throttling: UI updates max 2 times per second.
/// - Decoupled event processing from rendering.
/// - Prevents "Failed to post message to main thread" during high-speed downloads.
class PlaybackInspectorOverlay extends StatefulWidget {
  final VoidCallback onClose;
  const PlaybackInspectorOverlay({super.key, required this.onClose});

  @override
  State<PlaybackInspectorOverlay> createState() =>
      _PlaybackInspectorOverlayState();
}

class _PlaybackInspectorOverlayState extends State<PlaybackInspectorOverlay> {
  Offset _pos = const Offset(20, 20);
  StreamSubscription<PlayerSample>? _ps;
  StreamSubscription<ProxyEvent>? _pe; // Listen to proxy events
  StreamSubscription<StallReport>? _st;

  Timer? _uiTick;

  // Cache latest data to render
  PlayerSample? _latestSample;
  final ListQueue<ProxyEvent> _recentEvents = ListQueue<ProxyEvent>();
  final List<StallReport> _stalls = <StallReport>[];

  // Stats counters
  int _bpsIn = 0;
  int _bpsOut = 0;

  @override
  void initState() {
    super.initState();
    // 1. Enable data collection
    ProxyInspector.I.enabled = true;

    // 2. Subscribe to data streams (Passive collection - NO setState here)
    _ps = PlayerInspector.I.stream.listen((s) => _latestSample = s);

    // We listen to proxy events just to keep a local short history for the UI
    _pe = ProxyInspector.I.stream.listen((e) {
      _recentEvents.addFirst(e);
      while (_recentEvents.length > 100) {
        // Keep slightly more history
        _recentEvents.removeLast();
      }
    });

    _st = StallDetector.I.stream.listen((r) {
      _stalls.insert(0, r);
      if (_stalls.length > 10) _stalls.removeLast();
    });

    // 3. Active Rendering Timer (The Performance Fix)
    // Only rebuild the UI every 500ms, regardless of how many events come in.
    _uiTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;

      // Calculate throughput roughly for UI
      final now = DateTime.now();
      final oneSecAgo = now.subtract(const Duration(seconds: 1));

      // Simple sum of recent bytes for display
      int inBytes = 0;
      int outBytes = 0;
      for (final e in _recentEvents) {
        if (e.t.isAfter(oneSecAgo)) {
          if (e.kind == ProxyEventKind.remoteFetchDone)
            inBytes += (e.bytes ?? 0);
          if (e.kind == ProxyEventKind.respOut) outBytes += (e.bytes ?? 0);
        }
      }

      // This is the ONLY place setState is called.
      setState(() {
        _bpsIn = inBytes;
        _bpsOut = outBytes;
      });
    });
  }

  @override
  void dispose() {
    ProxyInspector.I.enabled = false; // Disable overhead when closed
    _ps?.cancel();
    _pe?.cancel();
    _st?.cancel();
    _uiTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => _pos += d.delta),
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
          elevation: 6,
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  const Icon(Icons.analytics_outlined,
                      color: Colors.blueAccent, size: 16),
                  const SizedBox(width: 8),
                  const Text('Playback Inspector',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                  const Spacer(),
                  InkWell(
                      onTap: widget.onClose,
                      child: const Icon(Icons.close,
                          color: Colors.white54, size: 16)),
                ]),
                const Divider(color: Colors.white24, height: 16),

                // Player Stats
                if (_latestSample != null) ...[
                  _row('Position', _fmtDur(_latestSample!.position)),
                  _row('Buffer',
                      '${_fmtDur(_latestSample!.buffer)}  (${_latestSample!.buffering ? "Buffering" : "Ready"})',
                      valColor: _latestSample!.buffering
                          ? Colors.orangeAccent
                          : Colors.greenAccent),
                ],

                const SizedBox(height: 8),
                const Text('Proxy Throughput (1s)',
                    style: TextStyle(color: Colors.white54, fontSize: 10)),
                _row('Download',
                    '${(_bpsIn / 1024 / 1024).toStringAsFixed(1)} MB/s'),
                _row('Serve',
                    '${(_bpsOut / 1024 / 1024).toStringAsFixed(1)} MB/s'),

                if (_stalls.isNotEmpty) ...[
                  const Divider(color: Colors.white24, height: 16),
                  const Text('Recent Stalls (Tap to copy)',
                      style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    height: 100,
                    decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4)),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(4),
                      itemCount: _stalls.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (_, i) {
                        final r = _stalls[i];
                        return InkWell(
                          onTap: () => _showStallDetail(context, r),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Text(_timeOnly(r.end),
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 10)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(r.kind.name,
                                        style: TextStyle(
                                            color: _kindColor(r.kind),
                                            fontSize: 11))),
                                Text('${r.duration.inMilliseconds}ms',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 11)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],

                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.copy, size: 12),
                    label: const Text('Copy All Logs',
                        style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _copyAllLogs(context),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String val, {Color? valColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Text(val,
              style: TextStyle(
                  color: valColor ?? Colors.white,
                  fontSize: 11,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Color _kindColor(StallKind k) {
    switch (k) {
      case StallKind.network:
        return Colors.orange;
      case StallKind.decodeOrRender:
        return Colors.redAccent;
      case StallKind.unknown:
        return Colors.grey;
    }
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _timeOnly(DateTime d) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }

  Future<void> _showStallDetail(BuildContext context, StallReport r) async {
    final events = r.proxyContext;
    final lines = <String>[];
    for (final e in events.take(40)) {
      final ms = e.ms != null ? ' ${e.ms}ms' : '';
      final b = e.bytes != null ? ' ${e.bytes}B' : '';
      final st = e.status != null ? ' ${e.status}' : '';
      final rg = e.range != null ? ' ${e.range}' : '';
      final note = e.note != null ? ' ${e.note}' : '';
      lines.add('${e.t.toIso8601String()} ${e.kind.name}$st$b$ms$rg$note');
    }
    final text = lines.join('\n');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black87,
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        contentTextStyle: const TextStyle(color: Colors.white70, fontSize: 12),
        title: Text('Stall Detail - ${r.kind.name} (${_fmtDur(r.duration)})'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Text(text.isEmpty ? 'No proxy events.' : text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) {
                Navigator.pop(ctx);
                showAppToast(context, 'Copied!',
                    duration: const Duration(milliseconds: 600));
              }
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAllLogs(BuildContext context) async {
    final json = jsonEncode({
      'playerLatest': _latestSample?.toJson(),
      'proxyRecent': _recentEvents.map((e) => e.toJson()).toList(),
      'stalls': _stalls.map((e) => e.toJson()).toList(),
    });
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      showAppToast(context, 'Full logs copied!',
          duration: const Duration(seconds: 1));
    }
  }
}
