import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
export 'core/network/background_gate.dart'
    show
        AsyncSemaphore,
        WebDavBackgroundGate,
        WebDavBackgroundHttpPool,
        WebDavPausedException,
        webDavBgSemaphore,
        webDavUiSemaphore;
import 'core/network/background_gate.dart';
import 'ui/kit.dart';
import 'webdav.dart';
import 'image.dart';
import 'core/network/remote_media_cache.dart';
import 'sources/accounts.dart';
import 'sources/refs.dart';
import 'tag/tag_interaction_helpers.dart';
import 'tag/tag_manager_filters.dart';
import 'tag/tag_models.dart';
import 'tag/tag_store_algorithms.dart';
import 'tag/tag_store_persistence.dart';
import 'package:file_picker/file_picker.dart'; // 用于选择目录/导入文件
part 'tag/tag_files_tab_view.dart';
part 'tag/tag_ui_sections.dart';
// Android 版本不支持桌面端拖拽文件（desktop_drop / XFile）。
// ===== core_utils.dart (auto-grouped) =====

// --- from utils.dart ---

/// 工具模块：缩略图缓存 / ffmpeg 检查 / Stream 管理
class TagThumbCache {
  // 避免 hover 时同一 key 反复触发 ffmpeg（合并并发请求）
  static final Map<String, Future<File?>> _inflightPreview = {};

  // 缓存目录/账号信息，避免在 hover/拖动时频繁走平台通道导致 Windows 主线程消息队列压力过大
  static Future<Directory>? _cacheDirFuture;
  static Future<Directory>? _sourceCacheDirFuture;
  static final Map<String, Future<Map<String, dynamic>?>>
      _webdavAccountFutures = {};

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

  static bool _isWebDavSource(String s) => isWebDavSource(s);

  static Future<Map<String, dynamic>?> _loadWebDavAccount(
      String accountId) async {
    return await _webdavAccountFutures.putIfAbsent(
      accountId,
      () => loadWebDavAccountJsonShared(accountId),
    );
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
    if (rangeEndInclusive != null && rangeEndInclusive > 0) {
      final token = WebDavBackgroundGate.pauseToken;
      await RemoteMediaRangeCache.downloadPrefixToFile(
        uri.toString(),
        headers,
        out,
        maxBytes: rangeEndInclusive + 1,
        beforeRequest: WebDavBackgroundGate.waitIfPaused,
        shouldAbort: () =>
            WebDavBackgroundGate.isPaused &&
            WebDavBackgroundGate.pauseToken != token,
        abortError: () =>
            WebDavPausedException('aborted background download for $uri'),
      );
      if (WebDavBackgroundGate.isPaused &&
          WebDavBackgroundGate.pauseToken != token) {
        try {
          if (await out.exists()) await out.delete();
        } catch (_) {}
      }
      return;
    }

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

      await out.parent.create(recursive: true);

      final sink = out.openWrite();
      try {
        await for (final chunk in res) {
          if (WebDavBackgroundGate.isPaused &&
              WebDavBackgroundGate.pauseToken != token) {
            client.close(force: true);
            throw WebDavPausedException('aborted background download for $uri');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.flush();
        await sink.close();
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
        final ref = parseWebDavSource(source);
        if (ref == null) return null;
        final accountId = ref.accountId;
        final rel = ref.relPath;

        final acc = await _loadWebDavAccount(accountId);
        if (acc == null) return null;

        final baseUrl = (acc['baseUrl'] ?? '').toString();
        final username = (acc['username'] ?? '').toString();
        final password = (acc['password'] ?? '').toString();
        if (baseUrl.isEmpty) return null;

        final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
        final resolved = Uri.parse(base).resolve(encodePathPreserveSlash(rel));

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
      markChanged();
    }
  }

  Future<void> syncLocalTagDir(Tag tag) async {
    if (tag.localPath == null) return;
    final dir = Directory(tag.localPath!);
    if (!await dir.exists()) return;

    try {
      await ensureLoaded();
      bool changed = false;

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
        markChanged();
      }
    } catch (e) {
      debugPrint('Sync tag dir failed: $e');
    }
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
  static const _kStoreFileName = 'tag_module_store_v2.json';

  bool _loaded = false;

  final Map<String, Tag> _tagsById = <String, Tag>{};
  final Map<String, Set<String>> _targetToTagIds = <String, Set<String>>{};
  final Map<String, TagTargetMeta> _targetsByKey = <String, TagTargetMeta>{};

  // Public wrapper so helpers/extensions don't call protected member directly.
  void markChanged() {
    notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final store = await TagStorePersistence.storeFile(_kStoreFileName);
    final tmp = await TagStorePersistence.storeTmpFile(_kStoreFileName);
    await TagStorePersistence.recoverStoreIfNeeded(store, tmp);
    var loadedFromFile = false;
    final filePayload = await TagStorePersistence.readPayloadFromFile(store);
    if (filePayload != null) {
      TagStorePersistence.hydrateFromPayload(
        filePayload,
        tagsById: _tagsById,
        targetToTagIds: _targetToTagIds,
        targetsByKey: _targetsByKey,
      );
      loadedFromFile = true;
    }

    if (!loadedFromFile) {
      final payload = await TagStorePersistence.readLegacyPayload(
        tagsKey: _kTags,
        assignmentsKey: _kAssignments,
        targetsKey: _kTargets,
      );
      TagStorePersistence.hydrateFromPayload(
        payload,
        tagsById: _tagsById,
        targetToTagIds: _targetToTagIds,
        targetsByKey: _targetsByKey,
      );
      await _persist();
    }

    _loaded = true;
  }

  Future<void> _persist() async {
    final tags = _tagsById.values.map((e) => e.toJson()).toList();
    final assigns = <String, dynamic>{
      for (final e in _targetToTagIds.entries) e.key: e.value.toList(),
    };
    final targets = <String, dynamic>{
      for (final e in _targetsByKey.entries) e.key: e.value.toJson(),
    };
    final payload = <String, dynamic>{
      'tags': tags,
      'assignments': assigns,
      'targets': targets,
    };
    await TagStorePersistence.persistPayload(
      payload,
      fileName: _kStoreFileName,
    );
  }

  @visibleForTesting
  Future<void> debugRecoverStoreForTest() async {
    final store = await TagStorePersistence.storeFile(_kStoreFileName);
    final tmp = await TagStorePersistence.storeTmpFile(_kStoreFileName);
    await TagStorePersistence.recoverStoreIfNeeded(store, tmp);
  }

  @visibleForTesting
  Future<File> debugStoreFileForTest() =>
      TagStorePersistence.storeFile(_kStoreFileName);

  @visibleForTesting
  Future<File> debugStoreTmpFileForTest() =>
      TagStorePersistence.storeTmpFile(_kStoreFileName);

  @visibleForTesting
  void debugResetForTest() {
    _loaded = false;
    _tagsById.clear();
    _targetToTagIds.clear();
    _targetsByKey.clear();
  }

  List<Tag> get allTags {
    return TagStoreAlgorithms.sortedTags(_tagsById.values);
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
    return TagStoreAlgorithms.sortedTargetsForTag(
      tagId,
      targetToTagIds: _targetToTagIds,
      targetsByKey: _targetsByKey,
    );
  }

  Future<Tag> createTag(String name, {Color? color}) async {
    await ensureLoaded();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final c = (color ?? TagStorePersistence.pickColor(name)).toARGB32();
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
    TagStoreAlgorithms.removeTag(
      tagId,
      tagsById: _tagsById,
      targetToTagIds: _targetToTagIds,
      targetsByKey: _targetsByKey,
    );
    await _persist();
    notifyListeners();
  }

  /// Set tags for a target (will upsert target meta)
  Future<void> setTagsForTarget(
      TagTargetMeta target, Set<String> tagIds) async {
    await ensureLoaded();
    TagStoreAlgorithms.setTagsForTarget(
      target,
      tagIds,
      targetToTagIds: _targetToTagIds,
      targetsByKey: _targetsByKey,
    );
    await _persist();
    notifyListeners();
  }

  /// quick helper
  Future<void> toggleTag(TagTargetMeta target, String tagId) async {
    await ensureLoaded();
    final next = TagStoreAlgorithms.toggledTags(tagsOf(target.key), tagId);
    await setTagsForTarget(target, next);
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
    if (!context.mounted) return null;
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
            if (!context.mounted) return;
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
typedef TagDirectoryOpenCallback = Future<void> Function(
    BuildContext context, Tag tag);

/// Tag 管理入口按钮
class TagManagerButton extends StatelessWidget {
  final TagItemOpenCallback onOpenItem;
  final TagItemLocateCallback? onLocateItem;
  final TagDirectoryOpenCallback? onOpenTagDirectory;
  final String tooltip;

  const TagManagerButton({
    super.key,
    required this.onOpenItem,
    this.onLocateItem,
    this.onOpenTagDirectory,
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
              onOpenTagDirectory: onOpenTagDirectory,
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
  final TagDirectoryOpenCallback? onOpenTagDirectory;

  const TagManagerPage({
    super.key,
    required this.onOpenItem,
    this.onLocateItem,
    this.onOpenTagDirectory,
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

extension _TagSortModeX on _TagSortMode {
  TagManagerSortMode get asFilterSortMode {
    switch (this) {
      case _TagSortMode.kind:
        return TagManagerSortMode.kind;
      case _TagSortMode.name:
        return TagManagerSortMode.name;
      case _TagSortMode.tagCount:
        return TagManagerSortMode.tagCount;
    }
  }
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
    return TagManagerFilters.filterTags(
      TagStore.I.allTags,
      query: _tagQuery,
    );
  }

  // 2. 文件列表（支持多 Tag 过滤）
  List<TagTargetMeta> _targets() {
    return TagManagerFilters.filterTargets(
      allTags: TagStore.I.allTags,
      selectedTagIds: _selectedTagIds,
      targetsOfTag: TagStore.I.targetsOfTag,
      tagsOfTarget: TagStore.I.tagsOf,
      query: _query,
      sortMode: _fileSort.asFilterSortMode,
      sortAsc: _fileSortAsc,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 给 _FilesTabView 头部筛选条用的标签列表（按名称排）
    final allTagsForFilter =
        TagManagerFilters.filterTags(TagStore.I.allTags, query: '');

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
            onOpenTagDirectory: widget.onOpenTagDirectory,
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
