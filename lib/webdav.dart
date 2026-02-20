import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'image.dart';
import 'video.dart';
import 'tag.dart';

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

// ===== network_webdav.dart (auto-grouped) =====

// --- from webdav.dart ---

/// =========================
/// WebDAV data models
/// =========================
class WebDavAccount {
  final String id;
  String name;
  String baseUrl; // e.g. https://example.com/dav/  (建议以 / 结尾)
  String username;
  String password;

  WebDavAccount({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
      };

  static WebDavAccount fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString().trim();
    return WebDavAccount(
      id: id.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : id,
      name: ((j['name'] ?? '').toString().trim().isEmpty)
          ? 'WebDAV'
          : (j['name'] ?? '').toString(),
      baseUrl: (j['baseUrl'] ?? '').toString(),
      username: (j['username'] ?? '').toString(),
      password: (j['password'] ?? '').toString(),
    );
  }

  /// Normalize base uri (ensure trailing slash).
  Uri get baseUri {
    var b = baseUrl.trim();
    if (!b.endsWith('/')) b = '$b/';
    return Uri.parse(b);
  }

  Map<String, String> get authHeaders {
    final token = base64Encode(utf8.encode('$username:$password'));
    return {HttpHeaders.authorizationHeader: 'Basic $token'};
  }
}

class WebDavItem {
  final String href; // href from server (may be absolute path like /dav/a.mp4)
  final String relPath; // path relative to baseUrl (used for navigation)
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;

  WebDavItem({
    required this.href,
    required this.relPath,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });
}

/// =========================
/// WebDAV store (PUBLIC)
/// =========================
class WebDavStore {
  static const _k = 'webdav_accounts_v1';

  static Future<List<WebDavAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .whereType<Map>()
            .map((m) => WebDavAccount.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<void> save(List<WebDavAccount> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_k, jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}

/// =========================
/// WebDAV manager
/// - 统一管理账号/Client 生命周期
/// - 账号增删改后通知所有页面清理缓存并重载
/// =========================
class WebDavManager extends ChangeNotifier {
  WebDavManager._();
  static final WebDavManager instance = WebDavManager._();

  bool _loaded = false;
  final Map<String, WebDavAccount> _accMap = <String, WebDavAccount>{};
  final Map<String, WebDavClient> _clientMap = <String, WebDavClient>{};

  bool get isLoaded => _loaded;
  Map<String, WebDavAccount> get accountsMap => _accMap;

  WebDavAccount? getAccount(String id) => _accMap[id];

  WebDavClient? getClient(String id) {
    final a = _accMap[id];
    if (a == null) return null;
    return _clientMap.putIfAbsent(id, () => WebDavClient(a));
  }

  Future<void> reload({bool notify = true}) async {
    final list = await WebDavStore.load();
    _accMap
      ..clear()
      ..addEntries(list.map((a) => MapEntry(a.id, a)));
    _clientMap
      ..clear()
      ..addEntries(list.map((a) => MapEntry(a.id, WebDavClient(a))));
    _loaded = true;
    if (notify) notifyListeners();
  }

  /// 账号发生变化（增删改）时调用：清空失效 Client 并通知所有监听者
  Future<void> notifyAccountChanged() async {
    await reload(notify: true);
  }
}

/// =========================
/// WebDAV client (HttpClient, no extra deps)
/// - Fix: href 可能是相对路径/绝对路径（无 host），必须 resolve 到 baseUri
/// - Cache: 使用 href hash 生成稳定缓存名，便于缩略图/重复打开复用
/// =========================

String _friendlyWebDavError(Object e, String url) {
  final lower = e.toString().toLowerCase();
  // Android 9+ blocks cleartext HTTP by default; Dart often surfaces this as errno=1 (Operation not permitted).
  if (Platform.isAndroid && url.trim().toLowerCase().startsWith('http://')) {
    if (lower.contains('operation not permitted') ||
        lower.contains('errno = 1')) {
      return '连接被系统拦截：Android 默认禁止明文 HTTP。\n'
          '请把地址改成 https，或在 android/app/src/main/AndroidManifest.xml 的 <application> 增加：\n'
          'android:usesCleartextTraffic="true"\n'
          '（更安全做法是只对白名单域名启用 cleartext，使用 network_security_config）。\n'
          '原始错误：$e';
    }
  }
  if (lower.contains('connection refused')) {
    return '连接被拒绝：请确认 WebDAV 服务已启动、端口正确、同一局域网可达。\n原始错误：$e';
  }
  if (lower.contains('timed out')) {
    return '连接超时：请检查网络/地址/端口，或服务端响应过慢。\n原始错误：$e';
  }
  return e.toString();
}

class WebDavClient {
  final WebDavAccount account;
  late final Uri _base;

  WebDavClient(this.account) {
    _base = account.baseUri;
  }

  String _basicAuth() {
    final token =
        base64Encode(utf8.encode('${account.username}:${account.password}'));
    return 'Basic $token';
  }

  /// Resolve relPath (folder path relative to baseUrl)
  Uri resolveRel(String relPath) {
    var rp = relPath;
    if (rp.startsWith('/')) rp = rp.substring(1);
    return _base.resolve(rp);
  }

  /// Resolve a href from server to full uri (href may be full url, /absolute-path, or relative)
  Uri resolveHref(String href) {
    final h = href.trim();
    if (h.isEmpty) return _base;
    final u = Uri.tryParse(h);
    if (u == null) return _base;
    if (u.hasScheme && u.host.isNotEmpty) return u;
    // u might be like "/dav/a.jpg" or "a.jpg"
    return _base.resolveUri(u);
  }

  Future<T> _runUi<T>(Future<T> Function() action) {
    return webDavUiSemaphore.withPermit(() async {
      await WebDavBackgroundGate.waitIfPaused();
      return await action();
    });
  }

  Future<T> _runBg<T>(Future<T> Function() action) {
    return webDavBgSemaphore.withPermit(() async {
      await WebDavBackgroundGate.waitIfPaused();
      return await action();
    });
  }

  Future<List<WebDavItem>> list(String relFolder) async {
    return _runUi(() async {
      // WebDAV 目录建议以 / 结尾
      var folder = relFolder;
      if (folder.isNotEmpty && !folder.endsWith('/')) folder = '$folder/';

      final uri = resolveRel(folder);
      const body = '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop>'
          '<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>'
          '</d:prop></d:propfind>';

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.openUrl('PROPFIND', uri);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
        req.headers.set('Depth', '1');
        req.headers.set('Accept', '*/*');
        req.headers.set('Content-Type', 'application/xml; charset=utf-8');
        req.add(utf8.encode(body));

        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();

        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('PROPFIND failed: ${res.statusCode}', uri: uri);
        }

        return _parsePropfind(text, folder);
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<File> cacheFileForHref(String href, {String? suggestedName}) async {
    final tmp = await getTemporaryDirectory();
    final root = Directory(p.join(tmp.path, 'webdav_cache', account.id));
    if (!await root.exists()) await root.create(recursive: true);

    // IMPORTANT:
    // Using base64(url) of the full href can produce extremely long filenames,
    // which breaks on Windows (MAX_PATH / filename length / invalid syntax).
    // We instead use a stable SHA1 hash as the cache key.
    final s =
        href.trim().isEmpty ? DateTime.now().toIso8601String() : href.trim();
    final digest = sha1.convert(utf8.encode(s)).toString(); // 40 hex chars

    // Spread files across subfolders to keep directory listings fast.
    final sub = Directory(p.join(root.path, digest.substring(0, 2)));
    if (!await sub.exists()) await sub.create(recursive: true);

    final ext = (suggestedName != null && p.extension(suggestedName).isNotEmpty)
        ? p.extension(suggestedName)
        : '';
    return File(p.join(sub.path, '$digest$ext'));
  }

  /// Cover cache (persistent): used for 收藏夹封面预览。
  /// Stored under ApplicationSupportDirectory so it survives restarts.
  Future<File> coverFileForHref(String href, {String? suggestedName}) async {
    final base = await getApplicationSupportDirectory();
    final root = Directory(p.join(base.path, 'webdav_cover_cache', account.id));
    if (!await root.exists()) await root.create(recursive: true);

    final s =
        href.trim().isEmpty ? DateTime.now().toIso8601String() : href.trim();
    final digest = sha1.convert(utf8.encode(s)).toString();
    final sub = Directory(p.join(root.path, digest.substring(0, 2)));
    if (!await sub.exists()) await sub.create(recursive: true);

    final ext = (suggestedName != null && p.extension(suggestedName).isNotEmpty)
        ? p.extension(suggestedName)
        : '';
    return File(p.join(sub.path, '$digest$ext'));
  }

  /// Ensure cover cached (FULL file) for previews.
  /// This cache is long-lived and should NOT be cleared by play-cache cleanup.
  Future<File> ensureCoverCached(
    String href,
    String name, {
    int? expectedSize,
    bool force = false,
  }) async {
    return _runBg(() async {
      final out = await coverFileForHref(href, suggestedName: name);
      if (await out.exists()) {
        if (!force) {
          final len = await out.length();
          if (len > 0 && (expectedSize == null || len == expectedSize))
            return out;
        }
        try {
          await out.delete();
        } catch (_) {}
      }

      final uri = resolveHref(href);
      final client = WebDavBackgroundHttpPool.instance.client;
      final gen = WebDavBackgroundHttpPool.instance.generation;
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
        req.headers.set('Accept', '*/*');
        final res = await req.close();
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('GET failed: ${res.statusCode}', uri: uri);
        }

        final tmpFile = File('${out.path}.download');
        if (await tmpFile.exists()) await tmpFile.delete();
        await tmpFile.create(recursive: true);

        final sink = tmpFile.openWrite();
        await res.pipe(sink);
        await sink.flush();
        await sink.close();

        if (expectedSize != null) {
          final got = await tmpFile.length();
          if (got != expectedSize) {
            try {
              await tmpFile.delete();
            } catch (_) {}
            throw Exception(
                'Download incomplete: got $got bytes, expected $expectedSize bytes');
          }
        }

        if (await out.exists()) await out.delete();
        await tmpFile.rename(out.path);
        return out;
      } finally {
        // Do NOT close shared client here.
        // If playback started, pool.abortAll() will have closed it.
        if (WebDavBackgroundHttpPool.instance.generation != gen) {
          // client was rotated; nothing to do.
        }
      }
    });
  }

  /// Create a stable cache file path for the *prefix/partial* download used by thumbnail probing.
  /// This is separated from the full cache file to avoid treating a Range prefix as a complete file.
  Future<File> cachePartFileForHref(String href,
      {String? suggestedName}) async {
    final full = await cacheFileForHref(href, suggestedName: suggestedName);
    final ext = p.extension(full.path);
    final base = ext.isEmpty
        ? full.path
        : full.path.substring(0, full.path.length - ext.length);
    return File('$base.part$ext');
  }

  /// Ensure a cached file exists (FULL file).
  /// - If cache exists and is complete, return it.
  /// - If cache exists but incomplete (e.g. a Range prefix file), delete and re-download.
  Future<File> ensureCached(
    String href,
    String name, {
    int? expectedSize,
    bool force = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    return _runUi(() async {
      final out = await cacheFileForHref(href, suggestedName: name);

      if (await out.exists()) {
        if (force) {
          try {
            await out.delete();
          } catch (_) {}
        } else {
          final len = await out.length();
          if (len > 0) {
            if (expectedSize == null || len == expectedSize) {
              return out;
            }
            // cached but incomplete -> remove and re-download
            try {
              await out.delete();
            } catch (_) {}
          }
        }
      }

      final uri = resolveHref(href);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
        req.headers.set('Accept', '*/*');
        final res = await req.close();

        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('GET failed: ${res.statusCode}', uri: uri);
        }

        final total = res.contentLength > 0 ? res.contentLength : null;

        final tmpFile = File('${out.path}.download');
        if (await tmpFile.exists()) await tmpFile.delete();
        await tmpFile.create(recursive: true);

        final sink = tmpFile.openWrite();
        int received = 0;
        await for (final chunk in res) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();

        // Validate size if known (avoid caching truncated downloads)
        if (expectedSize != null) {
          final got = await tmpFile.length();
          if (got != expectedSize) {
            try {
              await tmpFile.delete();
            } catch (_) {}
            throw Exception(
                'Download incomplete: got $got bytes, expected $expectedSize bytes');
          }
        }

        if (await out.exists()) await out.delete();
        await tmpFile.rename(out.path);
        return out;
      } finally {
        client.close(force: true);
      }
    });
  }

  /// Ensure a cached file exists for thumbnail generation (PREFIX file).
  /// Downloads only a prefix (Scheme A step 1) to reduce bandwidth.
  Future<File> ensureCachedForThumb(
    String href,
    String name, {
    int maxBytes = 12 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async {
    final out = await cachePartFileForHref(href, suggestedName: name);
    if (await out.exists() && await out.length() > 0) return out;

    await downloadToFileRange(
      href,
      out,
      maxBytes: maxBytes,
      onProgress: onProgress,
    );
    return out;
  }

  /// Probe whether MP4 'moov' atom exists in the *tail* of the remote file.
  /// Scheme A step 2: only if moov is in tail do we decide to download the full file.
  Future<bool> probeMoovInTail(
    String href, {
    required int fileSize,
    int probeBytes = 2 * 1024 * 1024,
  }) async {
    if (fileSize <= 0 || probeBytes <= 0) return false;
    final start = (fileSize - probeBytes).clamp(0, fileSize - 1);
    final end = fileSize - 1;
    final bytes = await _downloadRangeBytes(href,
        start: start, end: end, maxBytes: probeBytes);
    return _containsAscii(bytes, 'moov');
  }

  /// Download a byte range into memory (capped by [maxBytes]).
  Future<List<int>> _downloadRangeBytes(
    String href, {
    required int start,
    required int end,
    required int maxBytes,
  }) async {
    // Respect playback priority.
    await WebDavBackgroundGate.waitIfPaused();
    final token = WebDavBackgroundGate.pauseToken;
    final uri = resolveHref(href);
    final client = WebDavBackgroundHttpPool.instance.client;
    final gen = WebDavBackgroundHttpPool.instance.generation;
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
      req.headers.set('Accept', '*/*');
      req.headers.set('Range', 'bytes=$start-$end');
      final res = await req.close();

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('GET(Range) failed: ${res.statusCode}', uri: uri);
      }

      final out = <int>[];
      await for (final chunk in res) {
        if (WebDavBackgroundGate.isPaused &&
            WebDavBackgroundGate.pauseToken != token) {
          throw WebDavPausedException('aborted range probe for $uri');
        }
        if (WebDavBackgroundHttpPool.instance.generation != gen) {
          throw WebDavPausedException(
              'aborted (pool rotated) range probe for $uri');
        }
        if (out.length >= maxBytes) break;
        final remaining = maxBytes - out.length;
        if (chunk.length <= remaining) {
          out.addAll(chunk);
        } else {
          out.addAll(chunk.sublist(0, remaining));
        }
        if (out.length >= maxBytes) break;
      }
      return out;
    } finally {
      // Do NOT close shared client.
    }
  }

  bool _containsAscii(List<int> bytes, String needle) {
    if (needle.isEmpty || bytes.isEmpty) return false;
    final n = needle.codeUnits;
    outer:
    for (int i = 0; i <= bytes.length - n.length; i++) {
      for (int j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Download to a user-selected local file.
  Future<void> downloadToFile(String href, File outFile,
      {void Function(int received, int? total)? onProgress}) async {
    return _runUi(() async {
      final uri = resolveHref(href);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
        req.headers.set('Accept', '*/*');
        final res = await req.close();

        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('GET failed: ${res.statusCode}', uri: uri);
        }

        final total = res.contentLength > 0 ? res.contentLength : null;
        final tmp = File('${outFile.path}.download');
        if (await tmp.exists()) await tmp.delete();
        await tmp.create(recursive: true);

        final sink = tmp.openWrite();
        int received = 0;
        await for (final chunk in res) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();

        if (await outFile.exists()) await outFile.delete();
        await tmp.rename(outFile.path);
      } finally {
        client.close(force: true);
      }
    });
  }

  /// Download only a prefix of the remote file into [outFile] (for generating thumbnails).
  /// Uses HTTP Range when supported; otherwise it may still return 200 and stream full data,
  /// but we stop reading after [maxBytes] to cap bandwidth.
  Future<void> downloadToFileRange(
    String href,
    File outFile, {
    required int maxBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (maxBytes <= 0) return;

    return _runBg(() async {
      await WebDavBackgroundGate.waitIfPaused();
      final token = WebDavBackgroundGate.pauseToken;
      final uri = resolveHref(href);
      final client = WebDavBackgroundHttpPool.instance.client;
      final gen = WebDavBackgroundHttpPool.instance.generation;
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuth());
        req.headers.set('Accept', '*/*');
        req.headers.set('Range', 'bytes=0-${maxBytes - 1}');

        final res = await req.close();
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('GET(Range) failed: ${res.statusCode}', uri: uri);
        }

        final tmp = File('${outFile.path}.download');
        if (await tmp.exists()) await tmp.delete();
        await tmp.create(recursive: true);

        final sink = tmp.openWrite();
        int received = 0;

        await for (final chunk in res) {
          if (WebDavBackgroundGate.isPaused &&
              WebDavBackgroundGate.pauseToken != token) {
            throw WebDavPausedException('aborted background download for $uri');
          }
          if (WebDavBackgroundHttpPool.instance.generation != gen) {
            throw WebDavPausedException(
                'aborted (pool rotated) background download for $uri');
          }
          final remaining = maxBytes - received;
          if (remaining <= 0) break;

          if (chunk.length <= remaining) {
            sink.add(chunk);
            received += chunk.length;
          } else {
            sink.add(chunk.sublist(0, remaining));
            received += remaining;
          }

          onProgress?.call(received, null);

          if (received >= maxBytes) break;
        }

        await sink.flush();
        await sink.close();

        if (await outFile.exists()) await outFile.delete();
        await tmp.rename(outFile.path);
      } finally {
        // Do NOT close shared client.
      }
    });
  }

// ===============================
// XML entity decode for WebDAV
// ===============================
  String _xmlUnescape(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  List<WebDavItem> _parsePropfind(String xml, String currentFolderRel) {
    // 兼容大小写 / 命名空间：用宽松正则提取 response 块
    final responses = <String>[];
    final reResp = RegExp(
        r'<\s*[^>]*response\b[^>]*>([\s\S]*?)<\s*\/\s*[^>]*response\s*>',
        caseSensitive: false);
    for (final m in reResp.allMatches(xml)) {
      responses.add(m.group(0) ?? '');
    }

    String? textOf(String block, String tag) {
      final re = RegExp(
        r'<\s*[^>]*' +
            tag +
            r'\b[^>]*>([\s\S]*?)<\s*\/\s*[^>]*' +
            tag +
            r'\s*>',
        caseSensitive: false,
      );
      final m = re.firstMatch(block);
      if (m == null) return null;
      return _xmlUnescape((m.group(1) ?? '').trim());
    }

    bool containsTag(String block, String tag) {
      final re = RegExp(r'<\s*[^>]*' + tag + r'\b', caseSensitive: false);
      return re.hasMatch(block);
    }

    int intOf(String? s) =>
        int.tryParse((s ?? '').replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

    DateTime dateOf(String? s) {
      if (s == null) return DateTime.fromMillisecondsSinceEpoch(0);
      try {
        return HttpDate.parse(s);
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    // base path for rel mapping
    final basePath = _base.path.endsWith('/') ? _base.path : '${_base.path}/';

    String relFromHref(String href) {
      try {
        final u = Uri.parse(href);
        final path = Uri.decodeFull(u.path);
        var rel = path;
        if (rel.startsWith(basePath)) rel = rel.substring(basePath.length);
        if (rel.startsWith('/')) rel = rel.substring(1);
        return rel;
      } catch (_) {
        // fallback: keep raw
        return href;
      }
    }

    final out = <WebDavItem>[];
    for (final block in responses) {
      final href = textOf(block, 'href');
      if (href == null || href.isEmpty) continue;

      final rel = relFromHref(href);

      // 跳过当前目录自身（通常第一条就是自己）
      final cur = currentFolderRel.startsWith('/')
          ? currentFolderRel.substring(1)
          : currentFolderRel;
      final curNorm = cur.isEmpty ? '' : (cur.endsWith('/') ? cur : '$cur/');
      final relNorm = rel.isEmpty ? '' : (rel.endsWith('/') ? rel : '$rel/');
      if (curNorm == relNorm) continue;

      final isDir = containsTag(block, 'collection') || rel.endsWith('/');
      final display = textOf(block, 'displayname');
      final name = (display != null && display.isNotEmpty)
          ? display
          : p.basename(rel.isEmpty ? href : rel.replaceAll(RegExp(r'\/$'), ''));

      final size = isDir ? 0 : intOf(textOf(block, 'getcontentlength'));
      final modified = dateOf(textOf(block, 'getlastmodified'));

      out.add(
        WebDavItem(
          href: href,
          relPath: rel,
          name: name.isEmpty ? (isDir ? '文件夹' : '文件') : name,
          isDir: isDir,
          size: size,
          modified: modified,
        ),
      );
    }

    return out;
  }
}

/// =========================
/// WebDAV module entry
/// - Added WebDavPage wrapper to match your old call: WebDavPage.routeNoAnim()
/// =========================
class WebDavPage extends StatelessWidget {
  const WebDavPage({super.key});

  static Route routeNoAnim() => PageRouteBuilder(
        pageBuilder: (_, __, ___) => const WebDavAccountsPage(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );

  @override
  Widget build(BuildContext context) => const WebDavAccountsPage();
}

class WebDavAccountsPage extends StatefulWidget {
  const WebDavAccountsPage({super.key});

  @override
  State<WebDavAccountsPage> createState() => _WebDavAccountsPageState();
}

class _WebDavAccountsPageState extends State<WebDavAccountsPage> {
  bool _loading = true;
  bool _reloading = false;
  Object? _loadError;
  List<WebDavAccount> _accounts = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    setState(() => _loading = true);
    try {
      final list = await WebDavStore.load();
      if (!mounted) return;
      setState(() {
        _accounts = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _save() => WebDavStore.save(_accounts);

  Future<void> _add() async {
    final a = await _editAccountDialog(context, null);
    if (a == null) return;
    setState(() => _accounts.add(a));
    await _save();
    await WebDavManager.instance.notifyAccountChanged();
  }

  Future<void> _edit(WebDavAccount a) async {
    final updated = await _editAccountDialog(context, a);
    if (updated == null) return;
    final idx = _accounts.indexWhere((e) => e.id == a.id);
    if (idx < 0) return;
    setState(() => _accounts[idx] = updated);
    await _save();
    await WebDavManager.instance.notifyAccountChanged();
  }

  Future<void> _delete(WebDavAccount a) async {
    final ok = await _confirm(context,
        title: '删除 WebDAV', message: '确定删除「${a.name}」吗？');
    if (!ok) return;
    setState(() => _accounts.removeWhere((e) => e.id == a.id));
    await _save();
    await WebDavManager.instance.notifyAccountChanged();
  }

  Future<void> _open(WebDavAccount a) async {
    await Navigator.push(
      context,
      _noAnimRoute(WebDavBrowserPage(account: a)),
    );
  }

  Future<void> _ctx(WebDavAccount a, Offset pos) async {
    final act = await _ctxMenu<String>(context, pos, const [
      _CtxItem('open', '打开', Icons.open_in_new),
      _CtxItem('edit', '编辑', Icons.edit_outlined),
      _CtxItem('delete', '删除', Icons.delete_outline),
    ]);
    switch (act) {
      case 'open':
        await _open(a);
        break;
      case 'edit':
        await _edit(a);
        break;
      case 'delete':
        await _delete(a);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const AppLoadingState()
        : _loadError != null
            ? AppErrorState(
                title: '加载 WebDAV 账号失败',
                details: friendlyErrorMessage(_loadError!),
                onRetry: _reload,
              )
            : _accounts.isEmpty
                ? const AppEmptyState(
                    title: '还没有 WebDAV',
                    subtitle: '点击右下角添加账号',
                    icon: Icons.cloud_off_outlined,
                  )
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: AppViewport(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _accounts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final a = _accounts[i];
                          return InkWell(
                            onTap: () => _open(a),
                            onSecondaryTapDown: (d) =>
                                _ctx(a, d.globalPosition),
                            onLongPress: () {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              final pos = box != null
                                  ? box.localToGlobal(
                                      box.size.center(Offset.zero))
                                  : const Offset(80, 80);
                              _ctx(a, pos);
                            },
                            borderRadius: BorderRadius.circular(14),
                            child: Card(
                              elevation: 1,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              child: ListTile(
                                leading: const Icon(Icons.cloud_outlined),
                                title: Text(a.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(a.baseUrl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing: const Icon(Icons.chevron_right),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: Scaffold(
      appBar: GlassAppBar(
        title: const Text('WebDAV'),
        actions: [
          IconButton(
            onPressed: _reloading ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('添加 WebDAV'),
      ),
      ),
    );
  }
}

/// =========================
/// WebDAV browser page
/// =========================
enum WebDavViewMode { list, gallery, grid }

enum WebDavSortKey { name, date, size, type }

String _vmLabel(WebDavViewMode v) => const ['列表', '画廊', '网格'][v.index];
String _skLabel(WebDavSortKey k) => const ['名称', '日期', '大小', '类型'][k.index];
IconData _vmIcon(WebDavViewMode v) => const [
      Icons.view_list,
      Icons.photo_library_outlined,
      Icons.grid_view
    ][v.index];
IconData _skIcon(WebDavSortKey k) => const [
      Icons.sort_by_alpha,
      Icons.calendar_today_outlined,
      Icons.data_usage_outlined,
      Icons.category_outlined
    ][k.index];

class WebDavBrowserPage extends StatefulWidget {
  final WebDavAccount account;
  final String startRel; // allow start from a sub folder (favorites)
  const WebDavBrowserPage(
      {super.key, required this.account, this.startRel = ''});

  @override
  State<WebDavBrowserPage> createState() => _WebDavBrowserPageState();
}

class _WebDavBrowserPageState extends State<WebDavBrowserPage> {
  late final WebDavClient _client;

  bool _loading = true;
  bool _refreshing = false;
  Object? _loadError;
  String _rel = ''; // current folder relative path
  final List<String> _stack = [''];

  List<WebDavItem> _raw = [];

  bool _searching = false;
  String _q = '';

  WebDavViewMode _viewMode = WebDavViewMode.gallery;
  WebDavSortKey _sortKey = WebDavSortKey.name;
  bool _asc = true;

  // auto download small videos for thumbnail (optional)
  bool _autoVideoThumb = true;
  int _autoThumbMaxMB = 80;

  @override
  void initState() {
    super.initState();
    _client = WebDavClient(widget.account);
    _rel = widget.startRel;
    _stack
      ..clear()
      ..add(widget.startRel);
    _refresh();
  }

  String get _title {
    if (_rel.isEmpty) return widget.account.name;
    final t = _rel.endsWith('/') ? _rel.substring(0, _rel.length - 1) : _rel;
    return p.basename(t);
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    setState(() => _loading = true);
    try {
      final list = await _client.list(_rel);
      if (!mounted) return;
      setState(() {
        _raw = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
      showAppToast(
        context,
        _friendlyWebDavError(e, widget.account.baseUrl),
        error: true,
      );
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _openFolder(WebDavItem it) async {
    final rel = it.relPath;
    setState(() {
      _rel = rel.endsWith('/') ? rel : '$rel/';
      _stack.add(_rel);
      _searching = false;
      _q = '';
    });
    await _refresh();
  }

  Future<bool> _onBack() async {
    if (_stack.length > 1) {
      setState(() {
        _stack.removeLast();
        _rel = _stack.last;
        _searching = false;
        _q = '';
      });
      await _refresh();
      return false;
    }
    Navigator.pop(context);
    return false;
  }

  int _cmp(WebDavItem a, WebDavItem b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int r = 0;
    switch (_sortKey) {
      case WebDavSortKey.name:
        r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        break;
      case WebDavSortKey.date:
        r = a.modified.compareTo(b.modified);
        break;
      case WebDavSortKey.size:
        r = a.size.compareTo(b.size);
        break;
      case WebDavSortKey.type:
        final ta = a.isDir ? 'folder' : p.extension(a.name).toLowerCase();
        final tb = b.isDir ? 'folder' : p.extension(b.name).toLowerCase();
        r = ta.compareTo(tb);
        if (r == 0) r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        break;
    }
    return _asc ? r : -r;
  }

  List<WebDavItem> _shown() {
    final q = _q.trim().toLowerCase();
    final out = q.isEmpty
        ? [..._raw]
        : _raw.where((e) => e.name.toLowerCase().contains(q)).toList();
    out.sort(_cmp);
    return out;
  }

  bool _isImgName(String name) {
    final ext = p.extension(name).toLowerCase();
    const img = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
    return img.contains(ext);
  }

  bool _isVidName(String name) {
    final ext = p.extension(name).toLowerCase();
    const vid = <String>{
      '.mp4',
      '.mkv',
      '.mov',
      '.avi',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v'
    };
    return vid.contains(ext);
  }

  /// Build a pseudo URL for VideoPlayerPage to resolve & inject WebDAV auth headers.
  /// Example: webdav://<accountId>/<relative/path/to/file>
  String _webdavPlayUrl(WebDavItem it) {
    final segs = it.relPath.split('/').where((e) => e.isNotEmpty).toList();
    final u = Uri(
      scheme: 'webdav',
      host: _client.account.id,
      pathSegments: segs,
      // ✅ LAN 优化：把文件大小一路带到播放器/代理，避免某些 WebDAV 服务器
      // 不返回 Content-Length/Content-Range 导致起播慢、Range 异常。
      queryParameters: {
        'size': it.size.toString(),
      },
    );
    return u.toString();
  }

  Future<void> _openFile(WebDavItem it) async {
    final name = it.name;
    try {
      // 图片：仍然走稳定缓存（避免图片频繁重复拉取）
      if (_isImgName(name)) {
        final f = await _client.ensureCached(it.href, name);
        if (!mounted) return;
        await Navigator.push(
            context,
            _noAnimRoute(
                ImageViewerPage(imagePaths: [f.path], initialIndex: 0)));
        return;
      }

      // ✅ 视频：改为“边下边播 + 磁盘缓存”（YouTube/哔哩哔哩式）
      // - 通过 webdav:// 协议把 accountId + 相对路径传给 VideoPlayerPage
      // - VideoPlayerPage 内部会读取 SharedPreferences 里的 webdav_accounts_v1，
      //   自动把它解析成真实 http(s) URL，并注入 Authorization/User-Agent/keep-alive
      // - 具体的缓存/预读/回退缓冲策略在 video.dart 的 libmpv 参数里完成
      if (_isVidName(name)) {
        final shown = _shown();

        // 用当前列表中的所有视频构建播放列表，支持上一集/下一集
        final vids =
            shown.where((e) => !e.isDir && _isVidName(e.name)).toList();
        final idx = vids.indexWhere((e) => e.href == it.href);
        final paths = vids.map(_webdavPlayUrl).toList();

        if (!mounted) return;
        await Navigator.push(
          context,
          _noAnimRoute(
            VideoPlayerPage(
              videoPaths: paths.isEmpty ? [_webdavPlayUrl(it)] : paths,
              initialIndex: (idx >= 0 ? idx : 0),
            ),
          ),
        );
        return;
      }

// 其它文件：选择保存到本地
      final picked =
          await FilePicker.platform.getDirectoryPath(dialogTitle: '选择保存位置');
      if (picked == null) return;

      final out = File(p.join(picked, name));
      await _client.downloadToFile(it.href, out);
      if (!mounted) return;
      showAppToast(context, '已保存到：${out.path}');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '打开/下载失败：${friendlyErrorMessage(e)}', error: true);
    }
  }

  Future<void> _download(WebDavItem it) async {
    try {
      final picked =
          await FilePicker.platform.getDirectoryPath(dialogTitle: '选择保存位置');
      if (picked == null) return;
      final out = File(p.join(picked, it.name));
      await _client.downloadToFile(it.href, out);
      if (!mounted) return;
      showAppToast(context, '已保存到：${out.path}');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '下载失败：${friendlyErrorMessage(e)}', error: true);
    }
  }

  Future<void> _copyLink(WebDavItem it) async {
    try {
      final uri = _client.resolveHref(it.href).toString();
      await Clipboard.setData(ClipboardData(text: uri));
      if (!mounted) return;
      showAppToast(context, '已复制链接');
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '复制失败', error: true);
    }
  }

  Future<void> _ctxItem(WebDavItem it, Offset pos) async {
    final items = <_CtxItem<String>>[];
    if (!it.isDir) {
      if (_isVidName(it.name))
        items.add(const _CtxItem('play', '播放', Icons.play_arrow));
      if (_isImgName(it.name))
        items.add(const _CtxItem('view', '查看', Icons.image_outlined));
      items.add(const _CtxItem('download', '下载', Icons.download));
    }
    if (it.isDir) items.add(const _CtxItem('open', '打开', Icons.folder_open));
    items.add(const _CtxItem('copy', '复制链接', Icons.link));

    final act = await _ctxMenu<String>(context, pos, items);
    switch (act) {
      case 'open':
        _openFolder(it);
        break;
      case 'play':
      case 'view':
        _openFile(it);
        break;
      case 'download':
        _download(it);
        break;
      case 'copy':
        _copyLink(it);
        break;
    }
  }

  Future<void> _pickView() async {
    final v = await _picker<WebDavViewMode>(
      context,
      title: '视图模式',
      current: _viewMode,
      options: WebDavViewMode.values,
      labelOf: _vmLabel,
      iconOf: _vmIcon,
    );
    if (v == null) return;
    setState(() => _viewMode = v);
  }

  Future<void> _pickSort() async {
    final k = await _picker<WebDavSortKey>(
      context,
      title: '排序方式',
      current: _sortKey,
      options: WebDavSortKey.values,
      labelOf: _skLabel,
      iconOf: _skIcon,
    );
    if (k == null) return;
    setState(() => _sortKey = k);
  }

  @override
  Widget build(BuildContext context) {
    final list = _shown();
    final body = _loading
        ? const AppLoadingState()
        : _loadError != null
            ? AppErrorState(
                title: '加载目录失败',
                details:
                    _friendlyWebDavError(_loadError!, widget.account.baseUrl),
                onRetry: _refresh,
              )
            : list.isEmpty
                ? AppEmptyState(
                    title: '没有内容',
                    subtitle: '可以尝试切换目录或下拉刷新',
                    icon: Icons.folder_off_outlined,
                    actionLabel: '刷新',
                    onAction: _refresh,
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: AppViewport(child: _buildByMode(list)),
                  );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: WillPopScope(
        onWillPop: _onBack,
        child: Scaffold(
        appBar: GlassAppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: () => _onBack(),
          ),
          title: !_searching
              ? Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis)
              : TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: '搜索…', border: InputBorder.none),
                  onChanged: (v) => setState(() => _q = v),
                ),
          actions: [
            IconButton(
              tooltip: _searching ? '关闭搜索' : '搜索',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _q = '';
              }),
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
            IconButton(
                tooltip: '视图：${_vmLabel(_viewMode)}',
                onPressed: _pickView,
                icon: Icon(_vmIcon(_viewMode))),
            IconButton(
                tooltip: '排序：${_skLabel(_sortKey)}',
                onPressed: _pickSort,
                icon: Icon(_skIcon(_sortKey))),
            IconButton(
              tooltip: _asc ? '升序' : '降序',
              onPressed: () => setState(() => _asc = !_asc),
              icon: Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward),
            ),
            IconButton(
                tooltip: '刷新',
                onPressed: _refreshing ? null : _refresh,
                icon: const Icon(Icons.refresh)),
          ],
        ),
        body: body,
      ),
      ),
    );
  }

  Widget _buildByMode(List<WebDavItem> l) {
    switch (_viewMode) {
      case WebDavViewMode.list:
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: l.length,
          itemBuilder: (_, i) => _listItem(l[i]),
        );
      case WebDavViewMode.gallery:
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 420,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.45,
          ),
          itemCount: l.length,
          itemBuilder: (_, i) => _cardItem(l[i], dense: false),
        );
      case WebDavViewMode.grid:
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.95,
          ),
          itemCount: l.length,
          itemBuilder: (_, i) => _cardItem(l[i], dense: true),
        );
    }
  }

  Widget _thumb(WebDavItem it) {
    if (it.isDir) return const _FolderPreviewBox();
    if (_isImgName(it.name)) {
      final uri = _client.resolveHref(it.href);
      return _ProportionalPreviewBox(
        child: Image.network(
          uri.toString(),
          headers: widget.account.authHeaders,
          errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
        ),
      );
    }
    if (_isVidName(it.name)) {
      return FutureBuilder<File>(
        future: _client.cacheFileForHref(it.href, suggestedName: it.name),
        builder: (_, snap) {
          final f = snap.data;
          if (f != null && f.existsSync() && f.lengthSync() > 0) {
            return _ProportionalPreviewBox(
                child: VideoThumbImage(videoPath: f.path));
          }
          final canAuto = _autoVideoThumb &&
              it.size > 0 &&
              (it.size / (1024 * 1024) <= _autoThumbMaxMB);
          if (canAuto) {
            _client.ensureCached(it.href, it.name).then((_) {
              if (mounted) setState(() {});
            }).catchError((_) {});
          }
          return const _VideoPlaceholder();
        },
      );
    }
    return const _CoverPlaceholder();
  }

  Widget _listItem(WebDavItem it) {
    if (it.isDir) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              Text(it.relPath, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _openFolder(it),
          onLongPress: () {
            final box = context.findRenderObject() as RenderBox?;
            final pos = box != null
                ? box.localToGlobal(box.size.center(Offset.zero))
                : const Offset(80, 80);
            _ctxItem(it, pos);
          },
        ),
      );
    }

    return Card(
      child: ListTile(
        leading: SizedBox(width: 56, height: 56, child: _thumb(it)),
        title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${_fmtSize(it.size)} · ${it.modified.millisecondsSinceEpoch == 0 ? '-' : it.modified.toLocal()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        onTap: () => _openFile(it),
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox?;
          final pos = box != null
              ? box.localToGlobal(box.size.center(Offset.zero))
              : const Offset(80, 80);
          _ctxItem(it, pos);
        },
      ),
    );
  }

  Widget _cardItem(WebDavItem it, {required bool dense}) {
    final radius = BorderRadius.circular(14);
    IconData badge;
    if (it.isDir) {
      badge = Icons.folder_outlined;
    } else if (_isImgName(it.name)) {
      badge = Icons.image_outlined;
    } else if (_isVidName(it.name)) {
      badge = Icons.play_circle_outline;
    } else {
      badge = Icons.insert_drive_file_outlined;
    }

    return InkWell(
      onTap: () {
        if (it.isDir) {
          _openFolder(it);
          return;
        }
        _openFile(it);
      },
      onSecondaryTapDown: (d) => _ctxItem(it, d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box != null
            ? box.localToGlobal(box.size.center(Offset.zero))
            : const Offset(80, 80);
        _ctxItem(it, pos);
      },
      borderRadius: radius,
      child: Card(
        elevation: 1,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: radius),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _thumb(it)),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(999)),
                      child: Icon(badge, size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: dense,
              title:
                  Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(it.isDir ? '文件夹' : _fmtSize(it.size),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// =========================
/// Favorites: pick a WebDAV target (root/dir/file) and return a source string:
///   webdav://<accountId>/<relPath>   (file)
///   webdav://<accountId>/<relPath>/ (dir/root)
/// =========================
class WebDavPickSourcePage extends StatelessWidget {
  const WebDavPickSourcePage({super.key});

  static Future<String?> pick(BuildContext context) async {
    return Navigator.push<String>(
        context, _noAnimRoute(const WebDavPickSourcePage()));
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: FutureBuilder<List<WebDavAccount>>(
        future: WebDavStore.load(),
        builder: (_, snap) {
        final accs = snap.data ?? [];
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: AppLoadingState());
        }
        if (accs.isEmpty) {
          return Scaffold(
            appBar: GlassAppBar(title: const Text('选择 WebDAV')),
            body: const AppEmptyState(
              title: '还没有 WebDAV 账号',
              subtitle: '请先在 WebDAV 页面添加',
              icon: Icons.cloud_off_outlined,
            ),
          );
        }
        return Scaffold(
          appBar: GlassAppBar(title: const Text('选择 WebDAV')),
          body: AppViewport(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: accs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final a = accs[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: Text(a.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(a.baseUrl,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final src = await Navigator.push<String>(
                        context,
                        _noAnimRoute(_WebDavPickBrowserPage(account: a)),
                      );
                      if (src == null) return;
                      if (!context.mounted) return;
                      Navigator.pop(context, src);
                    },
                  ),
                );
              },
            ),
          ),
        );
        },
      ),
    );
  }
}

class _WebDavPickBrowserPage extends StatefulWidget {
  final WebDavAccount account;
  final String startRel;
  const _WebDavPickBrowserPage({required this.account, this.startRel = ''});

  @override
  State<_WebDavPickBrowserPage> createState() => _WebDavPickBrowserPageState();
}

class _WebDavPickBrowserPageState extends State<_WebDavPickBrowserPage> {
  late final WebDavClient _client;

  bool _loading = true;
  bool _refreshing = false;
  Object? _loadError;
  String _rel = '';
  final List<String> _stack = [''];
  List<WebDavItem> _raw = [];

  bool _searching = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _client = WebDavClient(widget.account);
    _rel = widget.startRel;
    _stack
      ..clear()
      ..add(widget.startRel);
    _refresh();
  }

  String get _title {
    if (_rel.isEmpty) return widget.account.name;
    final t = _rel.endsWith('/') ? _rel.substring(0, _rel.length - 1) : _rel;
    return p.basename(t);
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    setState(() => _loading = true);
    try {
      final list = await _client.list(_rel);
      if (!mounted) return;
      setState(() {
        _raw = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(
        context,
        _friendlyWebDavError(e, widget.account.baseUrl),
        error: true,
      );
    } finally {
      _refreshing = false;
    }
  }

  List<WebDavItem> _shown() {
    final q = _q.trim().toLowerCase();
    final out = q.isEmpty
        ? [..._raw]
        : _raw.where((e) => e.name.toLowerCase().contains(q)).toList();
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<void> _openFolder(WebDavItem it) async {
    final rel = it.relPath;
    setState(() {
      _rel = rel.endsWith('/') ? rel : '$rel/';
      _stack.add(_rel);
      _searching = false;
      _q = '';
    });
    await _refresh();
  }

  Future<bool> _onBack() async {
    if (_stack.length > 1) {
      setState(() {
        _stack.removeLast();
        _rel = _stack.last;
        _searching = false;
        _q = '';
      });
      await _refresh();
      return false;
    }
    Navigator.pop(context);
    return false;
  }

  String _sourceForCurrentDir() {
    final rel = _rel; // '' or 'a/b/'
    final base = 'webdav://${widget.account.id}/${Uri.encodeFull(rel)}';
    return base.endsWith('/') ? base : '$base/';
  }

  String _sourceForItem(WebDavItem it) {
    // use relPath to be stable
    final rel = it.relPath; // may end with '/'
    final base = 'webdav://${widget.account.id}/${Uri.encodeFull(rel)}';
    if (it.isDir) return base.endsWith('/') ? base : '$base/';
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  @override
  Widget build(BuildContext context) {
    final list = _shown();
    final body = _loading
        ? const AppLoadingState()
        : _loadError != null
            ? AppErrorState(
                title: '加载目录失败',
                details:
                    _friendlyWebDavError(_loadError!, widget.account.baseUrl),
                onRetry: _refresh,
              )
            : list.isEmpty
                ? AppEmptyState(
                    title: '没有内容',
                    subtitle: '可以尝试切换目录或下拉刷新',
                    icon: Icons.folder_off_outlined,
                    actionLabel: '刷新',
                    onAction: _refresh,
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: AppViewport(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final it = list[i];
                          return Card(
                            child: ListTile(
                              leading: Icon(it.isDir
                                  ? Icons.folder_outlined
                                  : Icons.insert_drive_file_outlined),
                              title: Text(it.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(it.relPath,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                tooltip: it.isDir ? '添加此目录' : '添加此文件',
                                icon: const Icon(Icons.add),
                                onPressed: () =>
                                    Navigator.pop(context, _sourceForItem(it)),
                              ),
                              onTap: () {
                                if (it.isDir) {
                                  _openFolder(it);
                                } else {
                                  Navigator.pop(context, _sourceForItem(it));
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: WillPopScope(
        onWillPop: _onBack,
        child: Scaffold(
        appBar: GlassAppBar(
          leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _onBack,
              tooltip: '返回'),
          title: !_searching
              ? Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis)
              : TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: '搜索…', border: InputBorder.none),
                  onChanged: (v) => setState(() => _q = v),
                ),
          actions: [
            IconButton(
              tooltip: _searching ? '关闭搜索' : '搜索',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _q = '';
              }),
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
            IconButton(
              tooltip: '添加当前目录',
              onPressed: () => Navigator.pop(context, _sourceForCurrentDir()),
              icon: const Icon(Icons.playlist_add),
            ),
            IconButton(
                tooltip: '刷新',
                onPressed: _refreshing ? null : _refresh,
                icon: const Icon(Icons.refresh)),
          ],
        ),
        body: body,
      ),
      ),
    );
  }
}

Route<T> _noAnimRoute<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );

/// =========================
/// Small UI helpers (no animation)
/// =========================
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined));
}

class _FolderPreviewBox extends StatelessWidget {
  const _FolderPreviewBox();
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.folder_outlined, size: 46));
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.play_circle_outline, size: 42),
    );
  }
}

class _ProportionalPreviewBox extends StatelessWidget {
  final Widget child;
  const _ProportionalPreviewBox({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: child,
      ),
    );
  }
}

/// =========================
/// No-animation dialogs / menus
/// =========================
Future<T?> _panel<T>(BuildContext context, Widget child,
    {Color barrier = Colors.black26}) {
  return showAdaptivePanel<T>(
    context: context,
    child: child,
    barrierColor: barrier,
    barrierLabel: 'panel',
  );
}

Future<bool> _confirm(BuildContext context,
    {required String title, required String message}) async {
  final res = await _panel<bool>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(message),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确定')),
            ]),
          ]),
        ),
      ),
    ),
  );
  return res ?? false;
}

class _CtxItem<T> {
  final T value;
  final String label;
  final IconData icon;
  const _CtxItem(this.value, this.label, this.icon);
}

Future<T?> _ctxMenu<T>(
    BuildContext context, Offset pos, List<_CtxItem<T>> items) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'ctx',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, __) {
      final size = MediaQuery.of(ctx).size;
      const w = 220.0;
      final left =
          pos.dx.clamp(10.0, (size.width - w - 10).clamp(10.0, size.width));
      final top =
          pos.dy.clamp(10.0, (size.height - 10).clamp(10.0, size.height));
      return Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final it in items)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, it.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(children: [
                        Icon(it.icon, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(it.label))
                      ]),
                    ),
                  )
              ],
            ),
          ),
        ),
      ]);
    },
  );
}

Future<T?> _picker<T>(
  BuildContext context, {
  required String title,
  required T current,
  required List<T> options,
  required String Function(T) labelOf,
  required IconData Function(T) iconOf,
}) {
  return _panel<T>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium)),
            for (final o in options)
              InkWell(
                onTap: () => Navigator.pop(context, o),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Icon(iconOf(o), size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(labelOf(o))),
                    if (o == current) const Icon(Icons.check, size: 18),
                  ]),
                ),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    ),
  );
}

/// Add/Edit WebDAV dialog (no animation)
Future<WebDavAccount?> _editAccountDialog(
    BuildContext context, WebDavAccount? origin) {
  final name = TextEditingController(text: origin?.name ?? 'WebDAV');
  final baseUrl = TextEditingController(text: origin?.baseUrl ?? '');
  final user = TextEditingController(text: origin?.username ?? '');
  final pass = TextEditingController(text: origin?.password ?? '');
  var submitting = false;

  return showAdaptivePanel<WebDavAccount>(
    context: context,
    barrierColor: Colors.black26,
    barrierLabel: 'editWebdav',
    child: StatefulBuilder(builder: (ctx, setState) {
      return Material(
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(origin == null ? '添加 WebDAV' : '编辑 WebDAV',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称（自定义）')),
              const SizedBox(height: 10),
              TextField(
                controller: baseUrl,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址（baseUrl）',
                  hintText: '例如：https://example.com/dav/（建议以 / 结尾）',
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: user,
                        decoration: const InputDecoration(labelText: '用户名'))),
                const SizedBox(width: 10),
                Expanded(
                    child: TextField(
                        controller: pass,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码'))),
              ]),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: submitting ? null : () => Navigator.pop(ctx),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () {
                          final n = name.text.trim();
                          final b = baseUrl.text.trim();
                          final u = user.text.trim();
                          final p = pass.text.trim();
                          if (b.isEmpty) {
                            showAppToast(ctx, 'WebDAV 地址不能为空', error: true);
                            return;
                          }
                          setState(() => submitting = true);
                          Navigator.pop(
                            ctx,
                            WebDavAccount(
                              id: origin?.id ??
                                  DateTime.now()
                                      .millisecondsSinceEpoch
                                      .toString(),
                              name: n.isEmpty ? 'WebDAV' : n,
                              baseUrl: b,
                              username: u,
                              password: p,
                            ),
                          );
                        },
                  child: const Text('保存'),
                ),
              ]),
            ]),
          ),
        ),
      );
    }),
  );
}
