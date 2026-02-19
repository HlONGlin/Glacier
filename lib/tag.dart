import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'ui_kit.dart';
import 'video.dart';
import 'webdav.dart';
import 'image.dart';
import 'package:file_picker/file_picker.dart'; // 用于选择目录/导入文件
import 'pages.dart'; // 用于跳转 FolderDetailPage 和使用 FavoriteCollection
// Android 版本不支持桌面端拖拽文件（desktop_drop / XFile）。
// ===== core_utils.dart (auto-grouped) =====

// --- from utils.dart ---

/// ===============================
/// WebDAV Background HTTP Pool
///
/// A single shared [HttpClient] used by *background* WebDAV tasks (thumbs, covers,
/// range probes, prefetch...).
///
/// Why:
/// - Background tasks should reuse connections when idle.
/// - During playback we want to *immediately* give way: force-close sockets and
///   fail queued background work.
///
/// This class enables a "browser-style"抢占: playback can abort all background
/// IO in one call.
/// ===============================
class WebDavBackgroundHttpPool {
  WebDavBackgroundHttpPool._();
  static final WebDavBackgroundHttpPool instance = WebDavBackgroundHttpPool._();

  HttpClient? _client;
  int _generation = 0;

  int get generation => _generation;

  HttpClient get client {
    final c = _client;
    if (c != null) return c;
    final nc = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 2; // background: small pool
    _client = nc;
    return nc;
  }

  /// Force-abort all in-flight background requests.
  ///
  /// - closes current client with force
  /// - bumps generation so long loops can detect staleness
  /// - creates a fresh client lazily on next use
  void abortAll() {
    _generation++;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

/// ===============================
/// WebDAV Background Gate
/// - 收藏夹/列表常会并发拉缩略图、PROPFIND 等，容易和播放抢带宽/连接导致卡顿。
/// - 播放媒体时调用 [pause]，退出时调用 [resume]，WebDAV 的后台任务会自动等待。
/// ===============================
class WebDavBackgroundGate {
  static int _pauseDepth = 0;
  static Completer<void>? _resumeCompleter;
  static int _pauseToken = 0;

  static bool get isPaused => _pauseDepth > 0;
  static int get pauseToken => _pauseToken;

  static void pause() {
    _pauseDepth++;
    _pauseToken++;
    _resumeCompleter ??= Completer<void>();
  }

  /// Hard pause used for playback.
  ///
  /// Compared to [pause], this will:
  /// - force-close all background WebDAV sockets (so in-flight downloads abort immediately)
  /// - drop all queued background tasks waiting on [webDavBgSemaphore]
  ///
  /// This mimics browser behavior: playback always has absolute priority.
  static void pauseHard() {
    pause();
    // Abort network immediately.
    WebDavBackgroundHttpPool.instance.abortAll();
    // Clear queued background tasks (fail-fast).
    webDavBgSemaphore.cancelWaiters(
        WebDavPausedException('background tasks aborted by playback'));
  }

  static void resume() {
    if (_pauseDepth <= 0) return;
    _pauseDepth--;
    if (_pauseDepth == 0 &&
        _resumeCompleter != null &&
        !_resumeCompleter!.isCompleted) {
      _resumeCompleter!.complete();
      _resumeCompleter = null;
    }
  }

  static Future<void> waitIfPaused() async {
    if (_pauseDepth == 0) return;
    final c = _resumeCompleter;
    if (c != null) await c.future;
  }
}

/// Thrown when a background WebDAV IO task is aborted due to playback pause.
class WebDavPausedException implements Exception {
  final String? message;
  WebDavPausedException([this.message]);
  @override
  String toString() => message == null
      ? 'WebDavPausedException'
      : 'WebDavPausedException: $message';
}

/// 简单信号量：限制并发，避免收藏夹同时起几十个网络/磁盘任务。
class AsyncSemaphore {
  final int _max;
  int _inUse = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  AsyncSemaphore(this._max);

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }

  Future<void> acquire() async {
    if (_inUse < _max) {
      _inUse++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    _inUse++;
  }

  void release() {
    if (_inUse > 0) _inUse--;
    if (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
  }

  /// Cancel all queued waiters.
  ///
  /// Useful when playback starts and we want to *immediately* drop background
  /// tasks that haven't acquired a permit yet.
  void cancelWaiters([Exception? error]) {
    if (_waiters.isEmpty) return;
    final err = error ?? WebDavPausedException('semaphore waiters cancelled');
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) {
        c.completeError(err);
      }
    }
  }
}

/// WebDAV 后台任务默认并发数（可按需调整）
/// UI关键任务（列表/打开文件等）并发：更高优先级
final AsyncSemaphore webDavUiSemaphore = AsyncSemaphore(4);

/// 后台任务（封面/缩略图/预热等）并发：更低优先级
final AsyncSemaphore webDavBgSemaphore = AsyncSemaphore(2);

/// 工具模块：缩略图缓存 / ffmpeg 检查 / Stream 管理
class TagThumbCache {
  // 避免 hover 时同一 key 反复触发 ffmpeg（合并并发请求）
  static final Map<String, Future<File?>> _inflightPreview = {};

  // 缓存目录/账号信息，避免在 hover/拖动时频繁走平台通道导致 Windows 主线程消息队列压力过大
  static Future<Directory>? _cacheDirFuture;
  static Future<Directory>? _sourceCacheDirFuture;
  static Future<SharedPreferences>? _prefsFuture;
  static Future<List<Map<String, dynamic>>>? _webdavAccountsFuture;

  static Future<Directory> _cacheDir() => _cacheDirFuture ??= (() async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory(p.join(base.path, 'thumb_cache'));
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      })();

  // ===============================
  // Source helpers: local / http(s) / webdav://accountId/...
  // ===============================
  static bool _isHttpSource(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  static bool _isWebDavSource(String s) {
    try {
      final u = Uri.parse(s);
      return u.scheme.toLowerCase() == 'webdav' && u.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> _loadWebDavAccounts() async {
    try {
      final prefs = await (_prefsFuture ??= SharedPreferences.getInstance());
      final raw = prefs.getString('webdav_accounts_v1');
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<Map<String, dynamic>?> _loadWebDavAccount(
      String accountId) async {
    final list = await (_webdavAccountsFuture ??= _loadWebDavAccounts());
    for (final e in list) {
      if ((e['id'] ?? '').toString() == accountId) return e;
    }
    return null;
  }

  static String _basicAuthHeader(String username, String password) {
    final token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  static Future<Directory> _sourceCacheDir() =>
      _sourceCacheDirFuture ??= (() async {
        final tmp = await getTemporaryDirectory();
        final dir = Directory(p.join(tmp.path, 'thumb_source_cache'));
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      })();

  static Future<File> _sourceCacheFile(String stableKey,
      {String ext = ''}) async {
    final root = await _sourceCacheDir();
    final digest = sha1.convert(utf8.encode(stableKey)).toString();
    final sub = Directory(p.join(root.path, digest.substring(0, 2)));
    if (!await sub.exists()) await sub.create(recursive: true);
    return File(p.join(sub.path, '$digest$ext'));
  }

  static Future<File> _sourcePartCacheFile(String stableKey,
      {String ext = ''}) async {
    final full = await _sourceCacheFile(stableKey, ext: ext);
    final e = p.extension(full.path);
    final base = e.isEmpty
        ? full.path
        : full.path.substring(0, full.path.length - e.length);
    return File('$base.part$e');
  }

  static Future<void> _downloadToFile(
    Uri uri,
    File out, {
    required Map<String, String> headers,
    int? rangeEndInclusive,
  }) async {
    // 与播放器拉流互斥：播放期间暂停所有后台网络下载。
    await WebDavBackgroundGate.waitIfPaused();
    final token = WebDavBackgroundGate.pauseToken;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 25);
    try {
      final req = await client.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Accept', '*/*');
      if (rangeEndInclusive != null && rangeEndInclusive > 0) {
        req.headers.set('Range', 'bytes=0-$rangeEndInclusive');
      }

      final res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw HttpException('GET failed: ${res.statusCode}', uri: uri);
      }

      // ensure folder
      await out.parent.create(recursive: true);

      final sink = out.openWrite();
      int received = 0;
      try {
        await for (final chunk in res) {
          // If playback starts while we're downloading, abort immediately.
          if (WebDavBackgroundGate.isPaused &&
              WebDavBackgroundGate.pauseToken != token) {
            client.close(force: true);
            throw WebDavPausedException('aborted background download for $uri');
          }
          received += chunk.length;
          sink.add(chunk);
        }
      } finally {
        await sink.flush();
        await sink.close();
        // If we got aborted mid-way, remove the partial file to avoid poisoning cache.
        if (WebDavBackgroundGate.isPaused &&
            WebDavBackgroundGate.pauseToken != token) {
          try {
            if (await out.exists()) await out.delete();
          } catch (_) {}
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Resolve a source to a local file that ffmpeg can read.
  /// - local path -> itself
  /// - http(s) -> download (partial or full) to temp cache
  /// - webdav:// -> resolve account + baseUrl + auth, then download to temp cache
  static Future<({String localPath, bool isPartial})?> _ensureLocalForFfmpeg(
    String source, {
    required bool preferPartial,
    int partialBytes = 4 * 1024 * 1024, // 4MB（远程场景更省流，减少抢带宽）
  }) async {
    // 1) local file
    final f = File(source);
    if (await f.exists()) {
      return (localPath: f.path, isPartial: false);
    }

    // 2) http(s)
    Uri? uri;
    Map<String, String> headers = const {};
    String stableKey = source;

    if (_isHttpSource(source)) {
      try {
        uri = Uri.parse(source);
      } catch (_) {
        return null;
      }
    } else if (_isWebDavSource(source)) {
      try {
        final u = Uri.parse(source);
        final accountId = u.host;
        final rel = Uri.decodeFull(
            u.path.startsWith('/') ? u.path.substring(1) : u.path);

        final acc = await _loadWebDavAccount(accountId);
        if (acc == null) return null;

        final baseUrl = (acc['baseUrl'] ?? '').toString();
        final username = (acc['username'] ?? '').toString();
        final password = (acc['password'] ?? '').toString();
        if (baseUrl.isEmpty) return null;

        final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
        final resolved = Uri.parse(base).resolve(rel);

        uri = resolved;
        headers = {
          HttpHeaders.authorizationHeader: _basicAuthHeader(username, password),
        };
        stableKey = 'webdav:$accountId:${resolved.toString()}';
      } catch (_) {
        return null;
      }
    } else {
      return null;
    }

    final ext = (uri.pathSegments.isNotEmpty &&
            p.extension(uri.pathSegments.last).isNotEmpty)
        ? p.extension(uri.pathSegments.last)
        : '';

    // partial or full cache
    if (preferPartial) {
      final part = await _sourcePartCacheFile(stableKey, ext: ext);
      final minLen =
          partialBytes ~/ 2; // avoid treating tiny error pages as valid cache
      if (await part.exists()) {
        try {
          final len = await part.length();
          if (len >= minLen) return (localPath: part.path, isPartial: true);
        } catch (_) {}
      }
      try {
        await _downloadToFile(uri, part,
            headers: headers, rangeEndInclusive: partialBytes - 1);
        return (localPath: part.path, isPartial: true);
      } catch (_) {
        // fallback to full below
      }
    }

    final full = await _sourceCacheFile(stableKey, ext: ext);
    if (await full.exists()) {
      try {
        final len = await full.length();
        if (len > 0) return (localPath: full.path, isPartial: false);
      } catch (_) {}
    }
    try {
      await _downloadToFile(uri, full,
          headers: headers, rangeEndInclusive: null);
      return (localPath: full.path, isPartial: false);
    } catch (_) {
      return null;
    }
  }

  /// For image sources (local/http/webdav), fetch to a local cached file so UI can show a thumbnail.
  /// - local path: returns itself
  /// - http(s): downloads full file into temp cache
  /// - webdav://<accountId>/<relPath>: resolves account from SharedPreferences and downloads into temp cache
  static Future<File?> getOrCreateImageThumb(String source) async {
    // Local file
    final f = File(source);
    if (await f.exists()) return f;

    // Remote (http/webdav)
    final resolved = await _ensureLocalForFfmpeg(
      source,
      preferPartial: false, // images通常需要完整文件更稳妥
      partialBytes: 2 * 1024 * 1024,
    );
    if (resolved == null) return null;
    final out = File(resolved.localPath);
    if (await out.exists()) return out;
    return null;
  }

  static Future<File?> getOrCreateVideoThumb(String videoPath) async {
    final ff = await _findFfmpeg();
    if (ff == null) return null;

    // Prefer partial for remote, then fallback to full if ffmpeg fails.
    final resolved = await _ensureLocalForFfmpeg(videoPath,
        preferPartial: true, partialBytes: 4 * 1024 * 1024);
    if (resolved == null) return null;

    Future<File?> runWithLocal(String localPath,
        {required bool isPartial}) async {
      final isLocal = await File(videoPath).exists();
      String key;
      if (isLocal) {
        final st = await File(videoPath).stat();
        key = sha1
            .convert(
              utf8.encode(
                  'thumb|local|$videoPath|${st.size}|${st.modified.millisecondsSinceEpoch}'),
            )
            .toString();
      } else {
        // remote (webdav/http) — keep stable key so it can reuse favorites/catalog cache
        key = sha1.convert(utf8.encode('thumb|remote|$videoPath')).toString();
      }
      final dir = await _cacheDir();
      final out = File(p.join(dir.path, '$key.jpg'));
      if (await out.exists()) return out;

      Future<File?> job() async {
        // Generate thumbnail at 1s. Use scale to reduce size.
        final args = [
          '-y',
          '-ss',
          '00:00:01.000',
          '-i',
          localPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=320:-1',
          '-q:v',
          '2',
          out.path,
        ];

        final r1 = await Process.run(ff, args, runInShell: true);
        if (r1.exitCode != 0) {
          // try frame 0
          final args2 = [
            '-y',
            '-ss',
            '00:00:00.000',
            '-i',
            localPath,
            '-frames:v',
            '1',
            '-vf',
            'scale=320:-1',
            '-q:v',
            '2',
            out.path,
          ];
          final r2 = await Process.run(ff, args2, runInShell: true);
          if (r2.exitCode != 0) return null;
        }

        if (!await out.exists()) return null;
        return out;
      }

      // 合并并发（同一个输出）
      final inflightKey = out.path;
      final existing = _inflightPreview[inflightKey];
      if (existing != null) return existing;

      final fut = job();
      _inflightPreview[inflightKey] = fut;
      try {
        return await fut;
      } finally {
        _inflightPreview.remove(inflightKey);
      }
    }

    var out =
        await runWithLocal(resolved.localPath, isPartial: resolved.isPartial);
    if (out == null && resolved.isPartial) {
      // fallback: full download
      final full = await _ensureLocalForFfmpeg(videoPath, preferPartial: false);
      if (full != null) {
        out = await runWithLocal(full.localPath, isPartial: false);
      }
    }
    return out;
  }

  /// 仅从缓存读取视频缩略图（不触发任何网络下载/ffmpeg 抽帧）。
  /// 用于播放目录/列表等“展示优先”的场景，避免 hover/滚动时抢占带宽。
  static Future<File?> getCachedVideoThumb(String videoPath) async {
    try {
      final isLocal = await File(videoPath).exists();
      String key;
      if (isLocal) {
        final st = await File(videoPath).stat();
        key = sha1
            .convert(
              utf8.encode(
                  'thumb|local|$videoPath|${st.size}|${st.modified.millisecondsSinceEpoch}'),
            )
            .toString();
      } else {
        // remote (webdav/http) — keep stable key so it can reuse favorites/catalog cache
        key = sha1.convert(utf8.encode('thumb|remote|$videoPath')).toString();
      }
      final dir = await _cacheDir();
      final out = File(p.join(dir.path, '$key.jpg'));
      return (await out.exists()) ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// 生成“指定时间点”的视频预览帧（用于进度条 hover/拖动预览）。
  static Future<File?> getOrCreateVideoPreviewFrame(
    String videoPath,
    Duration position, {
    Duration step = const Duration(seconds: 2),
    int width = 320,
    int height = 180,
    bool fastSeek = true,
  }) async {
    final ff = await _findFfmpeg();
    if (ff == null) return null;

    final stepMs = step.inMilliseconds <= 0 ? 1000 : step.inMilliseconds;
    final qMs = (position.inMilliseconds ~/ stepMs) * stepMs;

    // For remote sources, partial often fails (moov atom may be at tail).
    // Strategy:
    // - try partial quickly; if ffmpeg fails, fallback to full cached file.
    final resolved = await _ensureLocalForFfmpeg(videoPath,
        preferPartial: true, partialBytes: 4 * 1024 * 1024);
    if (resolved == null) return null;

    Future<File?> runWithLocal(String localPath,
        {required bool isPartial}) async {
      final isLocal = await File(videoPath).exists();
      String key;
      if (isLocal) {
        final st = await File(videoPath).stat();
        key = sha1
            .convert(
              utf8.encode(
                'frame|local|$videoPath|${st.size}|${st.modified.millisecondsSinceEpoch}|w=$width|h=$height|step=${step.inMilliseconds}',
              ),
            )
            .toString();
      } else {
        // remote (webdav/http) — stable key across sessions/contexts
        key = sha1
            .convert(
              utf8.encode(
                  'frame|remote|$videoPath|w=$width|h=$height|step=${step.inMilliseconds}'),
            )
            .toString();
      }

      final dir = await _cacheDir();
      final out = File(p.join(dir.path, '${key}_$qMs.jpg'));
      if (await out.exists()) return out;

      // ✅ 合并并发请求
      final inflightKey = out.path;
      final existing = _inflightPreview[inflightKey];
      if (existing != null) return existing;

      Future<File?> job() async {
        final ss = (qMs / 1000.0).toStringAsFixed(3);
        final vf =
            'scale=$width:$height:force_original_aspect_ratio=decrease:flags=lanczos,'
            'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black,'
            'setsar=1';

        final args = <String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          if (fastSeek) ...['-ss', ss],
          '-i',
          localPath,
          if (!fastSeek) ...['-ss', ss],
          '-frames:v',
          '1',
          '-an',
          '-sn',
          '-dn',
          '-vf',
          vf,
          '-q:v',
          '2',
          out.path,
        ];

        final result = await Process.run(ff, args, runInShell: true);
        if (result.exitCode != 0) return null;
        if (!await out.exists()) return null;
        return out;
      }

      final fut = job();
      _inflightPreview[inflightKey] = fut;
      try {
        return await fut;
      } finally {
        _inflightPreview.remove(inflightKey);
      }
    }

    var out =
        await runWithLocal(resolved.localPath, isPartial: resolved.isPartial);
    if (out == null && resolved.isPartial) {
      final full = await _ensureLocalForFfmpeg(videoPath, preferPartial: false);
      if (full != null) {
        out = await runWithLocal(full.localPath, isPartial: false);
      }
    }
    return out;
  }

  static Future<String?> _findFfmpeg() async {
    // 1) Try "ffmpeg" directly (PATH).
    try {
      final r = await Process.run('ffmpeg', ['-version'], runInShell: true);
      if (r.exitCode == 0) return 'ffmpeg';
    } catch (_) {}
    // 2) Try common locations.
    final candidates = <String>[
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    return null;
  }
}

class ThumbDoctor {
  /// 环境检查（不依赖具体视频文件）：用于“关于/设置/环境检查”按钮。
  static Future<String> diagnoseEnvironment() async {
    final sb = StringBuffer();
    sb.writeln('== Environment Diagnose ==');
    sb.writeln('Time : ${DateTime.now()}');
    sb.writeln('Platform: ${Platform.operatingSystem}');
    sb.writeln('');

    final ff = await TagThumbCache._findFfmpeg();
    if (ff == null) {
      sb.writeln('[ERR] ffmpeg not found in PATH.');
      sb.writeln('      解决：安装 ffmpeg 并把 ffmpeg\bin 加到 PATH。');
    } else {
      sb.writeln('[OK ] ffmpeg detected: $ff');
    }

    try {
      final d = await TagThumbCache._cacheDir();
      sb.writeln('[OK ] Thumb cache dir: ${d.path}');
    } catch (e) {
      sb.writeln('[ERR] Thumb cache dir: $e');
    }

    try {
      final tmp = await getTemporaryDirectory();
      sb.writeln('[OK ] Temporary dir: ${tmp.path}');
    } catch (e) {
      sb.writeln('[ERR] Temporary dir: $e');
    }

    sb.writeln('');
    sb.writeln('WebDAV Semaphores: ui=4, bg=2');
    return sb.toString();
  }

  static Future<String> diagnose({required String videoPath}) async {
    final sb = StringBuffer();
    sb.writeln('== Thumbnail Diagnose ==');
    sb.writeln('Video: $videoPath');
    sb.writeln('Time : ${DateTime.now()}');
    sb.writeln('');

    final f = File(videoPath);
    if (!await f.exists()) {
      sb.writeln('[ERR] File not found.');
      return sb.toString();
    }
    final st = await f.stat();
    sb.writeln('[OK ] File exists. Size=${st.size} bytes');

    final ff = await TagThumbCache._findFfmpeg();
    if (ff == null) {
      sb.writeln('[ERR] ffmpeg not found in PATH.');
      sb.writeln('      解决：安装 ffmpeg 并把 ffmpeg\\bin 加到 PATH。');
      return sb.toString();
    }
    sb.writeln('[OK ] ffmpeg detected: $ff');

    final dir = await TagThumbCache._cacheDir();
    sb.writeln('[OK ] Cache dir: ${dir.path}');

    final outTest = File(p.join(
        dir.path, 'diagnose_${DateTime.now().millisecondsSinceEpoch}.jpg'));

    Future<void> runTry(String ts) async {
      final args = [
        '-y',
        '-ss',
        ts,
        '-i',
        videoPath,
        '-frames:v',
        '1',
        '-vf',
        'scale=480:-1',
        '-q:v',
        '2',
        outTest.path,
      ];
      sb.writeln('');
      sb.writeln('--- Try at $ts ---');
      sb.writeln('CMD: $ff ${args.map(_quoteIfNeeded).join(' ')}');
      try {
        final r = await Process.run(ff, args, runInShell: true);
        sb.writeln('ExitCode: ${r.exitCode}');
        final so = (r.stdout ?? '').toString();
        final se = (r.stderr ?? '').toString();
        if (so.isNotEmpty) sb.writeln('STDOUT:\n$so');
        if (se.isNotEmpty) sb.writeln('STDERR:\n$se');
        if (await outTest.exists()) {
          sb.writeln(
              '[OK ] Output created: ${outTest.path} (${(await outTest.stat()).size} bytes)');
        } else {
          sb.writeln('[ERR] Output not created.');
        }
      } catch (e, st) {
        sb.writeln('[EXC] $e\n$st');
      }
    }

    await runTry('00:00:01.000');
    if (!await outTest.exists()) {
      await runTry('00:00:00.000');
    }
    return sb.toString();
  }

  static String _quoteIfNeeded(String s) {
    if (s.contains(' ') || s.contains('(') || s.contains(')')) return '"$s"';
    return s;
  }
}

/// Small helper to merge multiple streams.
class StreamGroup<T> {
  static Stream<T> merge<T>(List<Stream<T>> streams) async* {
    final controller = StreamController<T>();
    final subs = <StreamSubscription<T>>[];
    for (final s in streams) {
      subs.add(s.listen(controller.add, onError: controller.addError));
    }
    controller.onCancel = () async {
      for (final sub in subs) {
        await sub.cancel();
      }
    };
    yield* controller.stream;
  }
}

// --- from tag.dart ---

/// =========================
/// Tag Module
/// =========================
///
/// ✅ 功能覆盖（对应你的需求）
/// 1) 在收藏夹里新建 Tag
/// 2) 图片/视频（以及其它文件）右键（或长按）标记 Tag
/// 3) Tag 管理栏：
///    - 查看所有 Tag
///    - 编辑（重命名）/ 删除
///    - 点开某个 Tag 查看该 Tag 下所有内容
/// 4) 基于 Tag 搜索 / 过滤文件
///
/// -------------------------
/// 如何接入（仅需在现有页面做少量 hook，代码都在本文件）
///
/// A. 在 pages.dart 顶部引入：
///   import 'tag.dart';
///
/// B. 在你的文件条目右键菜单里增加一个入口（示例伪代码）：
///   final act = await _ctxMenu<String>(..., [
///     ...,
///     _CtxItem('tag', '标记Tag', Icons.sell_outlined),
///   ]);
///   if (act == 'tag') {
///     final meta = TagTargetMeta.fromEntry(
///       key: e.displayPath, // local: 绝对路径；webdav: webdav://accId/relPath
///       name: e.name,
///       kind: TagKind.fromFilename(e.name),
///       isWebDav: e.isWebDav,
///     );
///     await TagUI.showTagPicker(
///       context,
///       target: meta,
///     );
///   }
///
/// C. 在 FolderDetailPage 顶部加一个 Tag 筛选栏（可放在 AppBar.bottom）
///   bottom: PreferredSize(
///     preferredSize: const Size.fromHeight(42),
///     child: TagChipsBar(
///       onChanged: (selectedTagId) {
///         setState(() => _selectedTagId = selectedTagId); // 你自己维护
///       },
///     ),
///   )
///
///   然后在渲染列表时：
///     if (_selectedTagId != null) {
///        entries = entries.where((e) => TagStore.I.hasTag(e.displayPath, _selectedTagId!)).toList();
///     }
///
/// D. 在收藏夹主页（FavoritesPage）的 AppBar actions 增加一个 Tag 管理入口：
///   IconButton(
///     tooltip: 'Tag 管理',
///     icon: const Icon(Icons.sell_outlined),
///     onPressed: () => Navigator.push(context, MaterialPageRoute(
///       builder: (_) => TagManagerPage(
///         // 让 Tag 列表里“打开文件”时怎么打开，由你提供：
///         onOpenItem: (item) async {
///           // TODO: 你可以根据 item.kind 分别跳到 ImageViewerPage / VideoPlayerPage
///           // 或者复用你已有的 _openWebDavFile / _openLocalFile
///         },
///       ),
///     )),
///   )
///
/// -------------------------
/// 注意
/// - 本模块仅做“标签/索引/管理/筛选”的通用能力；
/// - 真正“打开图片/视频”的动作需要你在 onOpenItem 回调里复用你现有逻辑。
/// =========================

/// Item kind
enum TagKind { image, video, other }

extension TagKindX on TagKind {
  String get label {
    switch (this) {
      case TagKind.image:
        return '图片';
      case TagKind.video:
        return '视频';
      case TagKind.other:
        return '文件';
    }
  }

  IconData get icon {
    switch (this) {
      case TagKind.image:
        return Icons.image_outlined;
      case TagKind.video:
        return Icons.play_circle_outline;
      case TagKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }

  static TagKind fromFilename(String name) {
    final n = name.toLowerCase();
    const img = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
    const vid = <String>{
      '.mp4',
      '.mkv',
      '.mov',
      '.avi',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v',
      '.mpg',
      '.mpeg',
      '.m2v',
      '.ts',
      '.m2ts',
      '.mts',
      '.vob',
      '.3gp',
      '.rm',
      '.rmvb',
      '.iso',
      '.dat',
      '.asf',
      '.f4v',
      '.divx',
      '.dv',
      '.ogv',
      '.hevc',
      '.264',
      '.265',
    };
    final dot = n.lastIndexOf('.');
    final ext = dot >= 0 ? n.substring(dot) : '';
    if (img.contains(ext)) return TagKind.image;
    if (vid.contains(ext)) return TagKind.video;
    return TagKind.other;
  }
}

// --- tag.dart ---

class Tag {
  final String id;
  String name;
  final int colorValue;
  String? localPath; // 新增：绑定的本地物理目录路径

  Tag(
      {required this.id,
      required this.name,
      required this.colorValue,
      this.localPath});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'c': colorValue,
        'lp': localPath // 持久化路径
      };

  static Tag fromJson(Map<String, dynamic> j) => Tag(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        colorValue: (j['c'] is int) ? j['c'] as int : Colors.blue.value,
        localPath: j['lp'] as String?, // 读取路径
      );
}

extension TagStorePhysicalX on TagStore {
  /// 将文件物理同步（复制）到标签绑定的目录
  Future<void> copyFileToTagDir(TagTargetMeta meta, Tag tag) async {
    if (tag.localPath == null) return;

    final targetDir = Directory(tag.localPath!);
    if (!await targetDir.exists()) await targetDir.create(recursive: true);

    final dstFile = File(p.join(tag.localPath!, meta.name));
    if (await dstFile.exists()) return;

    if (!meta.isWebDav) {
      if (meta.localPath != null) {
        final sourceFile = File(meta.localPath!);
        if (await sourceFile.exists()) {
          await sourceFile.copy(dstFile.path);
        }
      }
      return;
    }

    // --- WebDAV 下载逻辑 ---
    if (meta.wdAccountId == null) return;

    final acc = WebDavManager.instance.accountsMap[meta.wdAccountId];
    if (acc == null) return;

    final client = WebDavClient(acc);

    String href = meta.wdHref ?? '';
    if (href.isEmpty && meta.wdRelPath != null) {
      href = client.resolveRel(meta.wdRelPath!).toString();
    }
    if (href.isEmpty) return;

    try {
      await client.downloadToFile(href, dstFile);
    } catch (e) {
      debugPrint('WebDAV download failed: $e');
      if (await dstFile.exists()) await dstFile.delete();
      rethrow;
    }
  }

  /// 绑定路径到 Tag
  Future<void> bindPathToTag(String tagId, String? path) async {
    await ensureLoaded();
    final t = _tagsById[tagId];
    if (t != null) {
      t.localPath = path;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> syncLocalTagDir(Tag tag) async {
    if (tag.localPath == null) return;
    final dir = Directory(tag.localPath!);
    if (!await dir.exists()) return;

    try {
      await ensureLoaded();
      bool changed = false;

      // A: 扫描磁盘文件
      final diskFiles = <String>{};
      final entities =
          await dir.list(recursive: false, followLinks: false).toList();

      for (final e in entities) {
        if (e is! File) continue;
        final path = e.path;
        if (p.basename(path).startsWith('.')) continue;

        diskFiles.add(path);

        TagTargetMeta? meta = _targetsByKey[path];
        if (meta == null) {
          meta = TagTargetMeta(
            key: path,
            name: p.basename(path),
            kind: TagKindX.fromFilename(path),
            isWebDav: false,
            localPath: path,
          );
          _targetsByKey[path] = meta;
        }

        final currentTags = _targetToTagIds[path] ?? <String>{};
        if (!currentTags.contains(tag.id)) {
          currentTags.add(tag.id);
          _targetToTagIds[path] = currentTags;
          changed = true;
        }
      }

      // B: 清理已删除的文件
      final targetsToCheck = <String>[];
      for (final kv in _targetToTagIds.entries) {
        if (kv.value.contains(tag.id)) targetsToCheck.add(kv.key);
      }

      for (final key in targetsToCheck) {
        if (p.isWithin(tag.localPath!, key)) {
          if (!diskFiles.contains(key)) {
            final tags = _targetToTagIds[key];
            if (tags != null) {
              tags.remove(tag.id);
              changed = true;
              if (tags.isEmpty) {
                _targetToTagIds.remove(key);
                _targetsByKey.remove(key);
              }
            }
          }
        }
      }

      if (changed) {
        await _persist();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Sync tag dir failed: $e');
    }
  }
}

/// Tagged target metadata
class TagTargetMeta {
  /// unique key: for local use absolute path; for webdav use `webdav://<accId>/<relPath>`
  final String key;
  final String name;
  final TagKind kind;

  /// if webdav
  final bool isWebDav;
  final String? wdAccountId;
  final String? wdRelPath;
  final String? wdHref;

  /// if local
  final String? localPath;

  /// optional metadata used by folder/page flows
  final bool isDir;
  final bool isEmby;
  final String? embyAccountId;
  final String? embyItemId;
  final String? embyCoverUrl;

  const TagTargetMeta({
    required this.key,
    required this.name,
    required this.kind,
    required this.isWebDav,
    this.wdAccountId,
    this.wdRelPath,
    this.wdHref,
    this.localPath,
    this.isDir = false,
    this.isEmby = false,
    this.embyAccountId,
    this.embyItemId,
    this.embyCoverUrl,
  });

  Map<String, dynamic> toJson() => {
        'k': key,
        'n': name,
        't': kind.index,
        'w': isWebDav,
        'wa': wdAccountId,
        'wr': wdRelPath,
        'wh': wdHref,
        'lp': localPath,
        'd': isDir,
        'e': isEmby,
        'ea': embyAccountId,
        'ei': embyItemId,
        'ec': embyCoverUrl,
      };

  static TagTargetMeta fromJson(Map<String, dynamic> j) {
    return TagTargetMeta(
      key: (j['k'] ?? '') as String,
      name: (j['n'] ?? '') as String,
      kind: TagKind.values[((j['t'] is int) ? j['t'] as int : 2)
          .clamp(0, TagKind.values.length - 1)],
      isWebDav: (j['w'] is bool) ? j['w'] as bool : false,
      wdAccountId: j['wa'] as String?,
      wdRelPath: j['wr'] as String?,
      wdHref: j['wh'] as String?,
      localPath: j['lp'] as String?,
      isDir: (j['d'] is bool) ? j['d'] as bool : false,
      isEmby: (j['e'] is bool) ? j['e'] as bool : false,
      embyAccountId: j['ea'] as String?,
      embyItemId: j['ei'] as String?,
      embyCoverUrl: j['ec'] as String?,
    );
  }
}

/// Storage layer
class TagStore extends ChangeNotifier {
  static TagStore get I => _instance;
  static final TagStore _instance = TagStore._();
  TagStore._();

  static const _kTags = 'tag_module.tags';
  static const _kAssignments = 'tag_module.assignments';
  static const _kTargets = 'tag_module.targets';

  bool _loaded = false;

  final Map<String, Tag> _tagsById = <String, Tag>{};
  final Map<String, Set<String>> _targetToTagIds = <String, Set<String>>{};
  final Map<String, TagTargetMeta> _targetsByKey = <String, TagTargetMeta>{};

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();

    // tags
    final rawTags = sp.getString(_kTags);
    if (rawTags != null && rawTags.trim().isNotEmpty) {
      try {
        final list = (jsonDecode(rawTags) as List).cast<dynamic>();
        for (final e in list) {
          if (e is Map) {
            final t = Tag.fromJson(e.cast<String, dynamic>());
            if (t.id.isNotEmpty) _tagsById[t.id] = t;
          }
        }
      } catch (_) {}
    }

    // assignments
    final rawAss = sp.getString(_kAssignments);
    if (rawAss != null && rawAss.trim().isNotEmpty) {
      try {
        final m = (jsonDecode(rawAss) as Map).cast<String, dynamic>();
        for (final kv in m.entries) {
          final k = kv.key;
          final v = kv.value;
          if (v is List) {
            _targetToTagIds[k] = v.map((e) => e.toString()).toSet();
          }
        }
      } catch (_) {}
    }

    // target meta
    final rawTargets = sp.getString(_kTargets);
    if (rawTargets != null && rawTargets.trim().isNotEmpty) {
      try {
        final m = (jsonDecode(rawTargets) as Map).cast<String, dynamic>();
        for (final kv in m.entries) {
          final v = kv.value;
          if (v is Map) {
            _targetsByKey[kv.key] =
                TagTargetMeta.fromJson(v.cast<String, dynamic>());
          }
        }
      } catch (_) {}
    }

    _loaded = true;
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();

    final tags = _tagsById.values.map((e) => e.toJson()).toList();
    final assigns = <String, dynamic>{
      for (final e in _targetToTagIds.entries) e.key: e.value.toList(),
    };
    final targets = <String, dynamic>{
      for (final e in _targetsByKey.entries) e.key: e.value.toJson(),
    };

    await sp.setString(_kTags, jsonEncode(tags));
    await sp.setString(_kAssignments, jsonEncode(assigns));
    await sp.setString(_kTargets, jsonEncode(targets));
  }

  List<Tag> get allTags {
    final list = _tagsById.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Tag? tagById(String id) => _tagsById[id];

  bool hasTag(String targetKey, String tagId) {
    final s = _targetToTagIds[targetKey];
    if (s == null) return false;
    return s.contains(tagId);
  }

  Set<String> tagsOf(String targetKey) =>
      Set<String>.from(_targetToTagIds[targetKey] ?? const <String>{});

  List<TagTargetMeta> targetsOfTag(String tagId) {
    final out = <TagTargetMeta>[];
    for (final kv in _targetToTagIds.entries) {
      if (kv.value.contains(tagId)) {
        final meta = _targetsByKey[kv.key];
        if (meta != null) out.add(meta);
      }
    }
    // recent first by name (no timestamp stored) - you can adjust if needed
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<Tag> createTag(String name, {Color? color}) async {
    await ensureLoaded();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final c = (color ?? _pickColor(name)).value;
    final t = Tag(id: id, name: name.trim(), colorValue: c);
    _tagsById[id] = t;
    await _persist();
    notifyListeners();
    return t;
  }

  Future<void> renameTag(String tagId, String newName) async {
    await ensureLoaded();
    final t = _tagsById[tagId];
    if (t == null) return;
    t.name = newName.trim();
    await _persist();
    notifyListeners();
  }

  Future<void> deleteTag(String tagId) async {
    await ensureLoaded();
    _tagsById.remove(tagId);
    // remove from assignments
    final toRemoveTargets = <String>[];
    for (final kv in _targetToTagIds.entries) {
      kv.value.remove(tagId);
      if (kv.value.isEmpty) toRemoveTargets.add(kv.key);
    }
    for (final k in toRemoveTargets) {
      _targetToTagIds.remove(k);
      _targetsByKey.remove(k);
    }
    await _persist();
    notifyListeners();
  }

  /// Set tags for a target (will upsert target meta)
  Future<void> setTagsForTarget(
      TagTargetMeta target, Set<String> tagIds) async {
    await ensureLoaded();
    if (tagIds.isEmpty) {
      _targetToTagIds.remove(target.key);
      _targetsByKey.remove(target.key);
    } else {
      _targetToTagIds[target.key] = Set<String>.from(tagIds);
      _targetsByKey[target.key] = target;
    }
    await _persist();
    notifyListeners();
  }

  /// quick helper
  Future<void> toggleTag(TagTargetMeta target, String tagId) async {
    await ensureLoaded();
    final s = tagsOf(target.key);
    if (s.contains(tagId)) {
      s.remove(tagId);
    } else {
      s.add(tagId);
    }
    await setTagsForTarget(target, s);
  }

  static Color _pickColor(String seed) {
    // simple deterministic palette
    const palette = <Color>[
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.red,
      Colors.indigo,
      Colors.brown,
      Colors.pink,
    ];
    var h = 0;
    for (final code in seed.codeUnits) {
      h = (h * 31 + code) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }
}

/// =========================
/// UI Helpers
/// =========================

class TagUI {
  /// Right-click/long-press -> 选择/新建 Tag
  ///
  /// returns selected tagIds
  static Future<Set<String>?> showTagPicker(
    BuildContext context, {
    required TagTargetMeta target,
    String title = '标记Tag',
  }) async {
    await TagStore.I.ensureLoaded();
    final store = TagStore.I;

    final selected = store.tagsOf(target.key);

    return showDialog<Set<String>>(
      context: context,
      builder: (_) {
        return _TagPickerDialog(
          title: title,
          target: target,
          initialSelected: selected,
        );
      },
    );
  }

  static Future<String?> _textInput(
    BuildContext context, {
    required String title,
    String hint = '',
    String initial = '',
    String okText = '确定',
  }) async {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) =>
              Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = ctl.text.trim();
              Navigator.pop(context, v.isEmpty ? null : v);
            },
            child: Text(okText),
          ),
        ],
      ),
    );
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    String okText = '删除',
  }) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(okText)),
        ],
      ),
    );
    return r ?? false;
  }
}

class _TagPickerDialog extends StatefulWidget {
  final String title;
  final TagTargetMeta target;
  final Set<String> initialSelected;

  const _TagPickerDialog({
    required this.title,
    required this.target,
    required this.initialSelected,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  final _qCtl = TextEditingController();
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
  }

  @override
  void dispose() {
    _qCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = TagStore.I;

    final q = _qCtl.text.trim().toLowerCase();
    final tags = store.allTags
        .where((t) => q.isEmpty || t.name.toLowerCase().contains(q))
        .toList();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.target.kind.label}：${widget.target.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _qCtl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索Tag…',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: tags.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = tags[i];
                  final checked = _selected.contains(t.id);
                  return CheckboxListTile(
                    value: checked,
                    onChanged: (_) => setState(() {
                      if (checked) {
                        _selected.remove(t.id);
                      } else {
                        _selected.add(t.id);
                      }
                    }),
                    title: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    secondary: CircleAvatar(
                        backgroundColor: Color(t.colorValue), radius: 10),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final name = await TagUI._textInput(context,
                title: '新建Tag', hint: '输入Tag名称');
            if (!mounted || name == null) return;
            final created = await store.createTag(name);
            if (!mounted) return;
            setState(() => _selected.add(created.id));
          },
          child: const Text('新建Tag'),
        ),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            await store.setTagsForTarget(widget.target, _selected);
            if (!mounted) return;
            Navigator.pop(context, _selected);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// =========================
/// Tag filter bar (chips)
/// =========================
class TagChipsBar extends StatefulWidget {
  /// null -> 全部
  final ValueChanged<String?> onChanged;

  /// 外部受控（可选）。如果提供，将以该值作为当前选中项。
  final String? selectedTagId;

  /// 外部不受控时的初始选中（兼容旧用法）
  final String? initialSelectedTagId;
  final EdgeInsets padding;

  const TagChipsBar({
    super.key,
    required this.onChanged,
    this.selectedTagId,
    this.initialSelectedTagId,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  @override
  State<TagChipsBar> createState() => _TagChipsBarState();
}

class _TagChipsBarState extends State<TagChipsBar> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectedTagId ?? widget.initialSelectedTagId;
    // ignore: unawaited_futures
    TagStore.I.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    TagStore.I.addListener(_onStore);
  }

  @override
  void didUpdateWidget(covariant TagChipsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 受控模式：外部值变化时同步内部状态
    if (widget.selectedTagId != null && widget.selectedTagId != _selected) {
      _selected = widget.selectedTagId;
    }
  }

  @override
  void dispose() {
    TagStore.I.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tags = TagStore.I.allTags;

    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: _selected == null,
            onSelected: (_) {
              setState(() => _selected = null);
              widget.onChanged(null);
            },
          ),
          const SizedBox(width: 8),
          for (final t in tags) ...[
            ChoiceChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: Color(t.colorValue), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(t.name),
                ],
              ),
              selected: _selected == t.id,
              onSelected: (_) {
                setState(() => _selected = t.id);
                widget.onChanged(t.id);
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// =========================
/// Tag manager pages
/// =========================

/// callback used when user taps an item under a tag
typedef TagItemOpenCallback = Future<void> Function(TagTargetMeta item);
typedef TagItemLocateCallback = Future<void> Function(TagTargetMeta item);

/// Tag 管理入口按钮
class TagManagerButton extends StatelessWidget {
  final TagItemOpenCallback onOpenItem;
  final TagItemLocateCallback? onLocateItem;
  final String tooltip;

  const TagManagerButton({
    super.key,
    required this.onOpenItem,
    this.onLocateItem,
    this.tooltip = 'Tag 管理',
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: const Icon(Icons.sell_outlined),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TagManagerPage(
              onOpenItem: onOpenItem,
              onLocateItem: onLocateItem,
            ),
          ),
        );
      },
    );
  }
}

/// Tag 管理页
class TagManagerPage extends StatefulWidget {
  final TagItemOpenCallback onOpenItem;
  final TagItemLocateCallback? onLocateItem;

  const TagManagerPage({
    super.key,
    required this.onOpenItem,
    this.onLocateItem,
  });

  @override
  State<TagManagerPage> createState() => _TagManagerPageState();
}

/// 文件列表排序依据
enum _TagSortMode {
  kind, // 类型
  name, // 名称
  tagCount, // 标签数
}

enum _TagFilesViewMode {
  grid, // 卡片
  list, // 列表
}

class _TagManagerPageState extends State<TagManagerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final Set<String> _selectedTagIds = <String>{}; // 空 => 全部
  String _query = '';
  bool _filesSearchExpanded = false;

  // Files Tab 状态
  _TagSortMode _fileSort = _TagSortMode.kind; // 默认按类型
  bool _fileSortAsc = true;
  _TagFilesViewMode _fileViewMode = _TagFilesViewMode.grid;

  // Tags Tab 状态
  String _tagQuery = '';
  bool _tagsSearchExpanded = false;

  Map<String, WebDavAccount> _accountsMap = const {};

  bool get _filesSearchShowing =>
      _filesSearchExpanded || _query.trim().isNotEmpty;
  bool get _tagsSearchShowing =>
      _tagsSearchExpanded || _tagQuery.trim().isNotEmpty;
  bool get _activeSearchShowing =>
      _tab.index == 0 ? _filesSearchShowing : _tagsSearchShowing;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(_onTabChanged);

    // Load TagStore & listen.
    TagStore.I.ensureLoaded().then((_) => mounted ? setState(() {}) : null);
    TagStore.I.addListener(_onStore);

    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      if (!WebDavManager.instance.isLoaded) {
        await WebDavManager.instance.reload(notify: false);
      }
      if (!mounted) return;
      setState(() => _accountsMap = WebDavManager.instance.accountsMap);
    } catch (_) {}
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  void _toggleCurrentTabSearch() {
    setState(() {
      if (_tab.index == 0) {
        if (_filesSearchShowing) {
          _query = '';
          _filesSearchExpanded = false;
        } else {
          _filesSearchExpanded = true;
        }
      } else {
        if (_tagsSearchShowing) {
          _tagQuery = '';
          _tagsSearchExpanded = false;
        } else {
          _tagsSearchExpanded = true;
        }
      }
    });
  }

  @override
  void dispose() {
    TagStore.I.removeListener(_onStore);
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  // 1. 标签列表（默认按名称 A-Z）
  List<Tag> _tags() {
    var tags = TagStore.I.allTags.toList();

    final q = _tagQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      tags = tags.where((t) => t.name.toLowerCase().contains(q)).toList();
    }

    tags.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return tags;
  }

  // 2. 文件列表（支持多 Tag 过滤）
  List<TagTargetMeta> _targets() {
    final seen = <String>{};
    final out = <TagTargetMeta>[];

    if (_selectedTagIds.isEmpty) {
      for (final t in TagStore.I.allTags) {
        for (final it in TagStore.I.targetsOfTag(t.id)) {
          if (seen.add(it.key)) out.add(it);
        }
      }
    } else {
      for (final tagId in _selectedTagIds) {
        for (final it in TagStore.I.targetsOfTag(tagId)) {
          if (seen.add(it.key)) out.add(it);
        }
      }
    }

    var items = out;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((e) => e.name.toLowerCase().contains(q)).toList();
    }

    items.sort((a, b) {
      int cmp;
      switch (_fileSort) {
        case _TagSortMode.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case _TagSortMode.tagCount:
          final ac = TagStore.I.tagsOfTarget(a.key).length;
          final bc = TagStore.I.tagsOfTarget(b.key).length;
          final r = ac.compareTo(bc);
          cmp =
              r == 0 ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : r;
          break;
        case _TagSortMode.kind:
          final r = a.kind.index.compareTo(b.kind.index);
          cmp =
              r == 0 ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : r;
          break;
      }
      return _fileSortAsc ? cmp : -cmp;
    });

    return items;
  }

  @override
  Widget build(BuildContext context) {
    // 给 _FilesTabView 头部筛选条用的标签列表（按名称排）
    final allTagsForFilter = TagStore.I.allTags.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Tag 管理'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '全部文件'),
            Tab(text: '标签列表'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _activeSearchShowing ? '收起搜索' : '展开搜索',
            icon: Icon(_activeSearchShowing ? Icons.close : Icons.search),
            onPressed: _toggleCurrentTabSearch,
          ),
          IconButton(
            tooltip: '新建标签',
            icon: const Icon(Icons.add),
            onPressed: () => _createTag(context),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _FilesTabView(
            tags: allTagsForFilter,
            selectedTagIds: _selectedTagIds,
            onSelectedTagIdsChanged: (next) => setState(() {
              _selectedTagIds
                ..clear()
                ..addAll(next);
            }),
            query: _query,
            onQueryChanged: (v) => setState(() => _query = v),
            searchExpanded: _filesSearchExpanded,
            onSearchExpandedChanged: (v) =>
                setState(() => _filesSearchExpanded = v),
            sort: _fileSort,
            sortAsc: _fileSortAsc,
            onSortChanged: (v) => setState(() {
              if (_fileSort == v) {
                _fileSortAsc = !_fileSortAsc;
              } else {
                _fileSort = v;
              }
            }),
            onToggleSortOrder: () =>
                setState(() => _fileSortAsc = !_fileSortAsc),
            viewMode: _fileViewMode,
            onViewModeChanged: (v) => setState(() => _fileViewMode = v),
            items: _targets(),
            tagsById: {for (final t in allTagsForFilter) t.id: t},
            accountsMap: _accountsMap,
            tagChipsForTarget: (key) => TagStore.I.tagsOfTarget(key),
            onTapItem: widget.onOpenItem,
            onLocateItem: widget.onLocateItem,
          ),
          _TagsView(
            tags: _tags(),
            onRename: (t) => _renameTag(context, t),
            onDelete: (t) => _deleteTag(context, t),
            query: _tagQuery,
            onQueryChanged: (v) => setState(() => _tagQuery = v),
            searchExpanded: _tagsSearchExpanded,
            onSearchExpandedChanged: (v) =>
                setState(() => _tagsSearchExpanded = v),
          ),
        ],
      ),
    );
  }

  Future<void> _createTag(BuildContext context) async {
    final name = await _textInput(context, title: '新建标签', hint: '输入标签名称');
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await TagStore.I.createTag(trimmed);
  }

  Future<void> _renameTag(BuildContext context, Tag t) async {
    final name = await _textInput(context,
        title: '重命名标签', hint: '输入新名称', initial: t.name);
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await TagStore.I.renameTag(t.id, trimmed);
  }

  Future<void> _deleteTag(BuildContext context, Tag t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确定删除「${t.name}」？\n该操作会移除所有文件上的此标签。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await TagStore.I.deleteTag(t.id);
    if (mounted && _selectedTagIds.contains(t.id)) {
      setState(() {
        _selectedTagIds.remove(t.id);
      });
    }
  }

  Future<String?> _textInput(
    BuildContext context, {
    required String title,
    required String hint,
    String initial = '',
  }) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          decoration: InputDecoration(hintText: hint),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: const Text('确定')),
        ],
      ),
    );
  }
}

class _FilesTabView extends StatefulWidget {
  final List<Tag> tags;
  final Set<String> selectedTagIds;
  final ValueChanged<Set<String>> onSelectedTagIdsChanged;

  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  final _TagSortMode sort;
  final bool sortAsc;
  final ValueChanged<_TagSortMode> onSortChanged;
  final VoidCallback onToggleSortOrder;
  final _TagFilesViewMode viewMode;
  final ValueChanged<_TagFilesViewMode> onViewModeChanged;

  final List<TagTargetMeta> items;
  final Map<String, Tag> tagsById;
  final Map<String, WebDavAccount> accountsMap;
  final Set<String> Function(String targetKey) tagChipsForTarget;
  final TagItemOpenCallback onTapItem;
  final TagItemLocateCallback? onLocateItem;

  const _FilesTabView({
    required this.tags,
    required this.selectedTagIds,
    required this.onSelectedTagIdsChanged,
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.sort,
    required this.sortAsc,
    required this.onSortChanged,
    required this.onToggleSortOrder,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.items,
    required this.tagsById,
    required this.accountsMap,
    required this.tagChipsForTarget,
    required this.onTapItem,
    this.onLocateItem,
  });

  @override
  State<_FilesTabView> createState() => _FilesTabViewState();
}

class _FilesTabViewState extends State<_FilesTabView> {
  @override
  void initState() {
    super.initState();
    _trySyncCurrentTag();
  }

  @override
  void didUpdateWidget(covariant _FilesTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当用户切换 Tag 过滤时，如果新 Tag 绑定了目录，自动扫描同步
    if (!_sameTagSelection(widget.selectedTagIds, oldWidget.selectedTagIds)) {
      _trySyncCurrentTag();
    }
  }

  bool _sameTagSelection(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final id in a) {
      if (!b.contains(id)) return false;
    }
    return true;
  }

  void _trySyncCurrentTag() {
    for (final id in widget.selectedTagIds) {
      final tag = widget.tagsById[id];
      if (tag != null && tag.localPath != null) {
        // 异步执行扫描，不阻塞 UI
        TagStore.I.syncLocalTagDir(tag);
      }
    }
  }

  /// 编辑/去除当前文件的标签（支持取消选择=移除标签）
  Future<void> _editTagsForTarget(
      BuildContext context, TagTargetMeta meta) async {
    await TagStore.I.ensureLoaded();
    final allTags = widget.tags;
    if (allTags.isEmpty) return;

    // current selected tag ids
    final selected = TagStore.I.tagsOfTarget(meta.key).toSet();

    final result = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setD) {
            return AlertDialog(
              title: Text('编辑标签：${meta.name}'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in allTags)
                        FilterChip(
                          label: Text(t.name),
                          selected: selected.contains(t.id),
                          onSelected: (on) => setD(() {
                            if (on) {
                              selected.add(t.id);
                            } else {
                              selected.remove(t.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => setD(() => selected.clear()),
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(selected),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;

    // apply
    await TagStore.I.setTagsForTarget(meta, result);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('标签已更新')),
    );
  }

  List<Tag> _tagsForTarget(TagTargetMeta it) {
    final tagIds = widget.tagChipsForTarget(it.key);
    return tagIds.map((id) => widget.tagsById[id]).whereType<Tag>().toList();
  }

  Future<void> _showStoreToTagMenu({
    required BuildContext context,
    required Offset globalPosition,
    required TagTargetMeta item,
    required List<Tag> tagsForItem,
  }) async {
    final tagsWithDir =
        tagsForItem.where((tag) => tag.localPath != null).toList();
    if (tagsWithDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标签未绑定目录')),
      );
      return;
    }

    final selectedTag = await showMenu<Tag>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: tagsWithDir.map((tag) {
        return PopupMenuItem<Tag>(
          value: tag,
          child: Text('存入：${tag.name}'),
        );
      }).toList(),
    );

    if (selectedTag == null) return;
    await TagStore.I.copyFileToTagDir(item, selectedTag);
    await TagStore.I.syncLocalTagDir(selectedTag);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存到 ${p.basename(selectedTag.localPath!)}')),
    );
  }

  Future<void> _openTagFilterPanel() async {
    final initial = Set<String>.from(widget.selectedTagIds);
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final temp = Set<String>.from(initial);
        var q = '';
        return StatefulBuilder(
          builder: (ctx2, setS) {
            final all = widget.tags;
            final filtered = q.trim().isEmpty
                ? all
                : all
                    .where((t) =>
                        t.name.toLowerCase().contains(q.trim().toLowerCase()))
                    .toList();
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx2).size.height * 0.72,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Tag 筛选',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton(
                            onPressed: () => setS(() => temp.clear()),
                            child: const Text('全部'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        onChanged: (v) => setS(() => q = v),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '搜索标签',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: q.trim().isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除',
                                  onPressed: () => setS(() => q = ''),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('没有匹配的标签'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final t = filtered[i];
                                return CheckboxListTile(
                                  value: temp.contains(t.id),
                                  onChanged: (v) => setS(() {
                                    if (v == true) {
                                      temp.add(t.id);
                                    } else {
                                      temp.remove(t.id);
                                    }
                                  }),
                                  title: Text(t.name),
                                  secondary: CircleAvatar(
                                    radius: 8,
                                    backgroundColor: Color(t.colorValue),
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.trailing,
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              temp.isEmpty
                                  ? '当前：全部文件'
                                  : '当前：已选 ${temp.length} 个 Tag',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx2, temp),
                            child: const Text('应用'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (picked != null) {
      widget.onSelectedTagIdsChanged(picked);
    }
  }

  Widget _buildGridItem(TagTargetMeta it, List<Tag> tagsForItem) {
    return GestureDetector(
      onSecondaryTapDown: (details) => _showStoreToTagMenu(
        context: context,
        globalPosition: details.globalPosition,
        item: it,
        tagsForItem: tagsForItem,
      ),
      child: _FileCard(
        meta: it,
        tags: tagsForItem,
        accountsMap: widget.accountsMap,
        onTap: () => widget.onTapItem(it),
        onEditTags: () => _editTagsForTarget(context, it),
        onLocate: widget.onLocateItem == null
            ? null
            : () => unawaited(widget.onLocateItem!(it)),
      ),
    );
  }

  Widget _buildListItem(TagTargetMeta it, List<Tag> tagsForItem) {
    final showTags = tagsForItem.take(2).toList(growable: false);
    final rest = tagsForItem.length - showTags.length;

    return GestureDetector(
      onSecondaryTapDown: (details) => _showStoreToTagMenu(
        context: context,
        globalPosition: details.globalPosition,
        item: it,
        tagsForItem: tagsForItem,
      ),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        elevation: 0.3,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onTapItem(it),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 110,
                    height: 66,
                    child: _TagCover(meta: it, accountsMap: widget.accountsMap),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _KindBadge(kind: it.kind),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final t in showTags) _TagPill(tag: t),
                          if (rest > 0) _MorePill(count: rest),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '编辑/去除标签',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _editTagsForTarget(context, it),
                  visualDensity: VisualDensity.compact,
                ),
                if (widget.onLocateItem != null)
                  IconButton(
                    tooltip: 'Locate',
                    icon: const Icon(Icons.my_location_outlined, size: 18),
                    onPressed: () => unawaited(widget.onLocateItem!(it)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // 头部筛选栏
        SliverToBoxAdapter(
          child: _TagFilterHeader(
            query: widget.query,
            onQueryChanged: widget.onQueryChanged,
            searchExpanded: widget.searchExpanded,
            onSearchExpandedChanged: widget.onSearchExpandedChanged,
            sort: widget.sort,
            sortAsc: widget.sortAsc,
            onSortChanged: widget.onSortChanged,
            onToggleSortOrder: widget.onToggleSortOrder,
            selectedTagCount: widget.selectedTagIds.length,
            onOpenTagFilter: _openTagFilterPanel,
            viewMode: widget.viewMode,
            onViewModeChanged: widget.onViewModeChanged,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        if (widget.items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('没有文件')),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
            sliver: widget.viewMode == _TagFilesViewMode.grid
                ? SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.crossAxisExtent;
                      int cols;
                      if (w >= 1400) {
                        cols = 6;
                      } else if (w >= 1100) {
                        cols = 5;
                      } else if (w >= 860) {
                        cols = 4;
                      } else if (w >= 620) {
                        cols = 3;
                      } else if (w >= 430) {
                        cols = 2;
                      } else {
                        cols = 1;
                      }

                      return SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.05,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final it = widget.items[i];
                            final tagsForItem = _tagsForTarget(it);
                            return _buildGridItem(it, tagsForItem);
                          },
                          childCount: widget.items.length,
                        ),
                      );
                    },
                  )
                : SliverList.separated(
                    itemCount: widget.items.length,
                    itemBuilder: (context, i) {
                      final it = widget.items[i];
                      final tagsForItem = _tagsForTarget(it);
                      return _buildListItem(it, tagsForItem);
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                  ),
          ),
      ],
    );
  }
}

class _TagFilterHeader extends StatelessWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  final _TagSortMode sort;
  final bool sortAsc;
  final ValueChanged<_TagSortMode> onSortChanged;
  final VoidCallback onToggleSortOrder;
  final int selectedTagCount;
  final VoidCallback onOpenTagFilter;
  final _TagFilesViewMode viewMode;
  final ValueChanged<_TagFilesViewMode> onViewModeChanged;

  const _TagFilterHeader({
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.sort,
    required this.sortAsc,
    required this.onSortChanged,
    required this.onToggleSortOrder,
    required this.selectedTagCount,
    required this.onOpenTagFilter,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  String _sortLabel(_TagSortMode s) {
    switch (s) {
      case _TagSortMode.kind:
        return '类型';
      case _TagSortMode.name:
        return '名称';
      case _TagSortMode.tagCount:
        return '热度';
    }
  }

  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<_TagSortMode>(
          tooltip: '排序依据',
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _TagSortMode.kind,
              child: Row(children: [
                Icon(Icons.category_outlined, size: 16),
                SizedBox(width: 8),
                Text('按类型 (图片/视频/文件)')
              ]),
            ),
            PopupMenuItem(
              value: _TagSortMode.name,
              child: Row(children: [
                Icon(Icons.sort_by_alpha, size: 16),
                SizedBox(width: 8),
                Text('按名称')
              ]),
            ),
            PopupMenuItem(
              value: _TagSortMode.tagCount,
              child: Row(children: [
                Icon(Icons.local_offer_outlined, size: 16),
                SizedBox(width: 8),
                Text('按标签数量 (热度)')
              ]),
            ),
          ],
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 18),
                const SizedBox(width: 6),
                Text(_sortLabel(sort)),
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggleSortOrder,
          child: Container(
            height: 40,
            width: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            alignment: Alignment.center,
            child: Icon(
              sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 18,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tagFilterButton(BuildContext context) {
    final theme = Theme.of(context);
    final active = selectedTagCount > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpenTagFilter,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? theme.colorScheme.primary : theme.dividerColor),
          color: active ? theme.colorScheme.primary.withOpacity(0.08) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.sell : Icons.sell_outlined, size: 18),
            const SizedBox(width: 6),
            Text(active ? 'Tag($selectedTagCount)' : 'Tag选择'),
          ],
        ),
      ),
    );
  }

  String _viewModeLabel(_TagFilesViewMode m) =>
      m == _TagFilesViewMode.grid ? '卡片' : '列表';

  IconData _viewModeIcon(_TagFilesViewMode m) => m == _TagFilesViewMode.grid
      ? Icons.grid_view_outlined
      : Icons.view_list_outlined;

  Widget _viewModeButton(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<_TagFilesViewMode>(
      tooltip: '视图模式',
      initialValue: viewMode,
      onSelected: onViewModeChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _TagFilesViewMode.grid,
          child: Row(
            children: [
              Icon(Icons.grid_view_outlined, size: 16),
              SizedBox(width: 8),
              Text('卡片视图'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _TagFilesViewMode.list,
          child: Row(
            children: [
              Icon(Icons.view_list_outlined, size: 16),
              SizedBox(width: 8),
              Text('列表视图'),
            ],
          ),
        ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_viewModeIcon(viewMode), size: 18),
            const SizedBox(width: 6),
            Text(_viewModeLabel(viewMode)),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showSearch = searchExpanded || query.trim().isNotEmpty;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0.6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _sortButton(context),
                  const SizedBox(width: 8),
                  _tagFilterButton(context),
                  const SizedBox(width: 8),
                  _viewModeButton(context),
                ],
              ),
            ),
            if (showSearch) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 40,
                child: TextField(
                  onChanged: onQueryChanged,
                  controller: TextEditingController(text: query)
                    ..selection = TextSelection.collapsed(offset: query.length),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索文件名',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: query.trim().isEmpty
                        ? IconButton(
                            tooltip: '收起',
                            icon: const Icon(Icons.expand_less, size: 18),
                            onPressed: () => onSearchExpandedChanged(false),
                          )
                        : IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => onQueryChanged(''),
                          ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 简化后的 TagsView，移除所有排序UI
class _TagsView extends StatelessWidget {
  final List<Tag> tags;
  final ValueChanged<Tag> onRename;
  final ValueChanged<Tag> onDelete;

  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  const _TagsView({
    required this.tags,
    required this.onRename,
    required this.onDelete,
    required this.query,
    required this.onQueryChanged,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showSearch = searchExpanded || query.trim().isNotEmpty;

    return Column(children: [
      // 头部：移动端优先，默认收纳搜索框
      Material(
        color: theme.colorScheme.surface,
        elevation: 0.6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.sell_outlined, size: 18),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '标签列表',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('${tags.length} 项'),
                ],
              ),
              if (showSearch) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  width: double.infinity,
                  child: TextField(
                    onChanged: onQueryChanged,
                    controller: TextEditingController(text: query)
                      ..selection =
                          TextSelection.collapsed(offset: query.length),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索标签',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: query.trim().isEmpty
                          ? IconButton(
                              tooltip: '收起',
                              icon: const Icon(Icons.expand_less, size: 18),
                              onPressed: () => onSearchExpandedChanged(false),
                            )
                          : IconButton(
                              tooltip: '清除',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => onQueryChanged(''),
                            ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      Expanded(
        child: tags.isEmpty
            ? const Center(child: Text('没有匹配的标签'))
            : ListView.separated(
                itemCount: tags.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = tags[i];
                  final count = TagStore.I.targetsOfTag(t.id).length;
                  // --- tag.dart -> _TagsView 内部的 itemBuilder ---
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Color(t.colorValue),
                      child: const Icon(Icons.sell_outlined,
                          color: Colors.white, size: 20),
                    ),
                    title: Text(t.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$count 个文件'),
                        if (t.localPath != null)
                          Text('物理存放：${p.basename(t.localPath!)}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.primary)),
                      ],
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '标签操作',
                      onSelected: (v) async {
                        // 1. 重命名
                        if (v == 'rename') onRename(t);

                        // 2. 删除
                        if (v == 'delete') onDelete(t);

                        // 3. 绑定物理目录
                        if (v == 'bind_path') {
                          final path =
                              await FilePicker.platform.getDirectoryPath(
                            dialogTitle: '选择标签「${t.name}」的本地存放目录',
                          );
                          if (path != null) {
                            await TagStore.I.bindPathToTag(t.id, path);
                          }
                        }

                        // 4. 导入文件到该目录 (实现“右键上传/拉入”功能)
                        if (v == 'import_files' && t.localPath != null) {
                          final result = await FilePicker.platform
                              .pickFiles(allowMultiple: true);
                          if (result != null && result.files.isNotEmpty) {
                            int count = 0;
                            final targetDir = Directory(t.localPath!);
                            if (!await targetDir.exists())
                              await targetDir.create(recursive: true);

                            for (final file in result.files) {
                              if (file.path == null) continue;
                              try {
                                final src = File(file.path!);
                                // 复制文件到标签目录
                                final dst = File(p.join(
                                    t.localPath!, p.basename(file.path!)));
                                await src.copy(dst.path);
                                count++;
                              } catch (e) {
                                debugPrint('Import failed: $e');
                              }
                            }
                            if (context.mounted && count > 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        '已导入 $count 个文件到：${p.basename(t.localPath!)}')),
                              );
                            }
                          }
                        }

                        // 5. 打开目录浏览 (复用现有的文件夹详情页)
                        if (v == 'open_path' && t.localPath != null) {
                          // 构造一个临时的收藏夹对象来复用 FolderDetailPage
                          final collection = FavoriteCollection(
                            id: 'tag_dir_${t.id}',
                            name: '标签目录：${t.name}',
                            sources: [t.localPath!], // 直接使用绑定的物理路径作为来源
                            layer1: LayerSettings(
                                viewMode: ViewMode.gallery), // 默认画廊视图
                            layer2: LayerSettings(viewMode: ViewMode.list),
                          );

                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    FolderDetailPage(collection: collection),
                              ));
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'rename', child: Text('重命名')),
                        const PopupMenuItem(
                            value: 'bind_path', child: Text('设置本地存放目录')),
                        if (t.localPath != null) ...[
                          const PopupMenuItem(
                              value: 'import_files', child: Text('导入文件到此目录')),
                          const PopupMenuItem(
                              value: 'open_path', child: Text('浏览物理目录内容')),
                        ],
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

// ... _FileCard, _KindBadge, _TagPill, _MorePill, _TagCover, _CoverPlaceholder 等保持不变 ...
// ... 如果你需要这部分代码，请告诉我，通常这部分不需要变动 ...
// ... 为了完整性，我将在下面附上这部分（保持原样） ...

class _FileCard extends StatelessWidget {
  final TagTargetMeta meta;
  final List<Tag> tags;
  final Map<String, WebDavAccount> accountsMap;
  final VoidCallback onTap;
  final VoidCallback onEditTags;
  final VoidCallback? onLocate;

  const _FileCard({
    required this.meta,
    required this.tags,
    required this.accountsMap,
    required this.onTap,
    required this.onEditTags,
    this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(14);

    final showTags = tags.take(2).toList();
    final rest = tags.length - showTags.length;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: radius,
      elevation: 0.4,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _TagCover(meta: meta, accountsMap: accountsMap),
                    if (meta.kind == TagKind.video)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.42),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _KindBadge(kind: meta.kind),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                meta.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                children: [
                  for (final t in showTags) ...[
                    _TagPill(tag: t),
                    const SizedBox(width: 6),
                  ],
                  if (rest > 0) _MorePill(count: rest),
                  const Spacer(),
                  if (onLocate != null)
                    IconButton(
                      tooltip: 'Locate',
                      icon: const Icon(Icons.my_location_outlined, size: 18),
                      onPressed: onLocate,
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    tooltip: '编辑/去除标签',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: onEditTags,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final TagKind kind;
  const _KindBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    IconData icon;
    String text;
    switch (kind) {
      case TagKind.image:
        icon = Icons.image_outlined;
        text = '图片';
        break;
      case TagKind.video:
        icon = Icons.videocam_outlined;
        text = '视频';
        break;
      default:
        icon = Icons.insert_drive_file_outlined;
        text = '文件';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withOpacity(0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  final Tag tag;
  const _TagPill({required this.tag});

  @override
  Widget build(BuildContext context) {
    final c = Color(tag.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Text(tag.name, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _MorePill extends StatelessWidget {
  final int count;
  const _MorePill({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withOpacity(0.8)),
      ),
      child: Text('+$count', style: const TextStyle(fontSize: 11)),
    );
  }
}

class _TagCover extends StatelessWidget {
  final TagTargetMeta meta;
  final Map<String, WebDavAccount> accountsMap;

  const _TagCover({required this.meta, required this.accountsMap});

  @override
  Widget build(BuildContext context) {
    final embyUrl = _resolveEmbyCoverUrl();
    if (embyUrl.isNotEmpty) {
      return Image.network(
        embyUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _CoverPlaceholder(
          icon: Icons.image_not_supported_outlined,
        ),
      );
    }
    if (meta.kind == TagKind.image) {
      return _imageCover();
    }
    if (meta.kind == TagKind.video) {
      return _videoCover();
    }
    return const _CoverPlaceholder(icon: Icons.insert_drive_file_outlined);
  }

  String _resolveEmbyCoverUrl() {
    final fromMeta = (meta.embyCoverUrl ?? '').trim();
    if (fromMeta.isNotEmpty) return fromMeta;
    final key = meta.key.trim();
    if (key.isEmpty) return '';
    if (!(meta.isEmby || key.toLowerCase().startsWith('emby://'))) return '';
    return '';
  }

  Widget _imageCover() {
    if (meta.isWebDav) {
      final acc =
          meta.wdAccountId != null ? accountsMap[meta.wdAccountId!] : null;
      final href = meta.wdHref;
      if (acc == null || href == null || href.trim().isEmpty) {
        return const _CoverPlaceholder(
            icon: Icons.image_not_supported_outlined);
      }

      return FutureBuilder<File>(
        future:
            WebDavClient(acc).coverFileForHref(href, suggestedName: meta.name),
        builder: (_, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return Image.file(f,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const _CoverPlaceholder(icon: Icons.broken_image_outlined));
          }
          return const _CoverPlaceholder(icon: Icons.image_outlined);
        },
      );
    }

    final lp = meta.localPath;
    if (lp == null || lp.isEmpty)
      return const _CoverPlaceholder(icon: Icons.image_not_supported_outlined);
    final f = File(lp);
    if (!f.existsSync())
      return const _CoverPlaceholder(icon: Icons.image_not_supported_outlined);
    return Image.file(f,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const _CoverPlaceholder(icon: Icons.broken_image_outlined));
  }

  Widget _videoCover() {
    if (meta.isWebDav) {
      final acc =
          meta.wdAccountId != null ? accountsMap[meta.wdAccountId!] : null;
      final href = meta.wdHref;
      if (acc == null || href == null || href.trim().isEmpty) {
        return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
      }
      return FutureBuilder<File>(
        future:
            WebDavClient(acc).cacheFileForHref(href, suggestedName: meta.name),
        builder: (_, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return VideoThumbImage(videoPath: f.path, cacheOnly: true);
          }
          return const _CoverPlaceholder(icon: Icons.videocam_outlined);
        },
      );
    }

    final lp = meta.localPath;
    if (lp == null || lp.isEmpty)
      return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
    final f = File(lp);
    if (!f.existsSync())
      return const _CoverPlaceholder(icon: Icons.videocam_off_outlined);
    return VideoThumbImage(videoPath: f.path, cacheOnly: true);
  }
}

class _CoverPlaceholder extends StatelessWidget {
  final IconData icon;
  const _CoverPlaceholder({required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceVariant.withOpacity(0.45),
      alignment: Alignment.center,
      child: Icon(icon,
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.72),
          size: 28),
    );
  }
}

/// Extension helpers on TagStore (non-invasive).
extension TagStoreCoversX on TagStore {
  /// tags of target by key
  Set<String> tagsOfTarget(String targetKey) {
    final out = <String>{};
    for (final t in allTags) {
      if (hasTag(targetKey, t.id)) out.add(t.id);
    }
    return out;
  }
}
