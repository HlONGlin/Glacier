export 'app_history.dart';
export 'app_settings.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../logging/app_logger.dart';
import '../network/http_client_factory.dart';
import '../network/network_runner.dart';
import 'redaction.dart' as core_redaction;

class PersistentStore {
  PersistentStore._();
  static final PersistentStore instance = PersistentStore._();

  static Directory? _docDir;

  Future<Directory> get _baseDir async {
    _docDir ??= await getApplicationDocumentsDirectory();
    return _docDir!;
  }

  Future<Directory> getDir(String type) async {
    final base = await _baseDir;
    final dir = Directory(p.join(base.path, 'glacier_store', type));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String makeKey(String input) {
    return sha1.convert(utf8.encode(input)).toString();
  }

  Future<File> getFile(String key, String type, String ext) async {
    final dir = await getDir(type);
    final normalizedExt = ext.trim();
    final safeExt = normalizedExt.isEmpty
        ? ''
        : (normalizedExt.startsWith('.') ? normalizedExt : '.$normalizedExt');
    return File(p.join(dir.path, '$key$safeExt'));
  }
}

class ThumbCache {
  static final Map<String, Future<File?>> _inflight = {};
  static final Map<String, int> _failedUntilMs = <String, int>{};
  static const int _failureCooldownMs = 2 * 60 * 1000;

  static bool _looksRemoteSource(String path) {
    final p = path.trim().toLowerCase();
    return p.startsWith('http://') ||
        p.startsWith('https://') ||
        p.startsWith('webdav://') ||
        p.startsWith('emby://');
  }

  static bool _isFailureCoolingDown(String key) {
    final until = _failedUntilMs[key];
    if (until == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= now) {
      _failedUntilMs.remove(key);
      return false;
    }
    return true;
  }

  static void _rememberFailure(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _failedUntilMs[key] = now + _failureCooldownMs;
  }

  static void _clearFailure(String key) {
    _failedUntilMs.remove(key);
  }

  static Future<File?> getCachedVideoThumb(String videoPath) async {
    try {
      const width = 320;
      const height = 180;
      const posMs = 0;
      final keyStr = '$videoPath|$posMs|$width|$height';
      final key = PersistentStore.instance.makeKey(keyStr);
      final out = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');
      if (!await out.exists()) return null;
      if (await out.length() <= 0) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> getOrCreateVideoThumb(String videoPath) async {
    try {
      final f = await getOrCreateVideoPreviewFrame(videoPath, Duration.zero);
      if (f == null) return null;
      if (!await f.exists()) return null;
      if (await f.length() <= 0) return null;
      return f;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> getOrCreateVideoPreviewFrame(
    String videoPath,
    Duration position, {
    Duration step = const Duration(seconds: 1),
    int width = 320,
    int height = 180,
    bool fastSeek = true,
  }) async {
    if (videoPath.isEmpty) return null;

    final qMs = (position.inMilliseconds / step.inMilliseconds).round() *
        step.inMilliseconds;
    final posQ = Duration(milliseconds: max(0, qMs));
    final keyStr = '$videoPath|${posQ.inMilliseconds}|$width|$height';
    final key = PersistentStore.instance.makeKey(keyStr);

    if (_isFailureCoolingDown(key)) return null;

    if (_looksRemoteSource(videoPath)) {
      _rememberFailure(key);
      return null;
    }

    final out = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');
    if (await out.exists() && await out.length() > 0) {
      _clearFailure(key);
      return out;
    }

    try {
      final f = File(videoPath);
      if (!await f.exists()) {
        _rememberFailure(key);
        return null;
      }
    } catch (_) {
      _rememberFailure(key);
      return null;
    }

    if (_inflight.containsKey(key)) return _inflight[key];

    final task = (() async {
      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          timeMs: posQ.inMilliseconds,
          maxWidth: width,
          quality: 75,
        );

        if (bytes == null || bytes.isEmpty) return null;

        await out.writeAsBytes(bytes, flush: true);
        _clearFailure(key);
        return out;
      } catch (e) {
        AppLogger.error('thumbnail generation failed', error: e, tag: 'thumb');
        _rememberFailure(key);
        return null;
      } finally {
        _inflight.remove(key);
      }
    })();

    _inflight[key] = task;
    return task;
  }
}

class WebDavFileCache {
  static Future<File> downloadAndCache(String webDavUrl,
      {String? customName, Map<String, String>? headers}) async {
    final ext = p.extension(customName ?? webDavUrl).toLowerCase();
    final key = PersistentStore.instance.makeKey(webDavUrl);
    final file = await PersistentStore.instance.getFile(key, 'media', ext);

    if (await file.exists()) {
      AppLogger.info('webdav cache hit: ${redactSensitiveText(file.path)}',
          tag: 'cache');
      return file;
    }

    AppLogger.info('downloading webdav asset: $webDavUrl', tag: 'cache');

    final uri = Uri.parse(webDavUrl);
    final requestHeaders = <String, String>{
      if (headers != null) ...headers,
    };
    final userInfo = uri.userInfo.trim();
    if (userInfo.isNotEmpty &&
        !requestHeaders.containsKey(HttpHeaders.authorizationHeader)) {
      final token = base64Encode(utf8.encode(userInfo));
      requestHeaders[HttpHeaders.authorizationHeader] = 'Basic $token';
    }

    final tmp = File('${file.path}.download');
    if (await tmp.exists()) {
      await tmp.delete();
    }

    final client = HttpClientFactory.createForeground();
    IOSink? sink;
    try {
      final request = await NetworkRunner.run(
        () => client.getUrl(uri),
        label: 'webdav-cache-open',
      );
      requestHeaders.forEach(request.headers.set);
      final response = await NetworkRunner.run(
        () => request.close(),
        label: 'webdav-cache-close',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'WebDAV download failed: ${response.statusCode}',
          uri: uri,
        );
      }

      sink = tmp.openWrite();
      await response.pipe(sink);
      await sink.close();
      sink = null;

      if (await tmp.length() <= 0) {
        throw const HttpException('WebDAV download produced empty file');
      }

      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);

      AppLogger.info(
          'webdav download complete: ${redactSensitiveText(file.path)}',
          tag: 'cache');
      return file;
    } catch (_) {
      if (sink != null) {
        await sink.close();
      }
      if (await tmp.exists()) {
        await tmp.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

class CoverCache {
  CoverCache._();
  static final CoverCache instance = CoverCache._();
  static const Object _nullSentinel = Object();

  static const int maxEntries = 400;

  final Map<String, Future<dynamic>> _inflight = {};
  final LinkedHashMap<String, dynamic> _lru = LinkedHashMap();

  T? getResult<T>(String key) {
    if (!_lru.containsKey(key)) return null;
    final v = _lru.remove(key);
    _lru[key] = v;
    if (identical(v, _nullSentinel)) return null;
    return v as T;
  }

  Future<T?> getOrCreate<T>(String key, Future<T?> Function() loader,
      {bool cacheNull = false}) {
    if (_lru.containsKey(key)) {
      return Future<T?>.value(getResult<T>(key));
    }

    if (_inflight.containsKey(key)) return _inflight[key] as Future<T?>;

    final fut = (() async {
      try {
        final r = await loader();
        if (r != null || cacheNull) {
          _put(key, r);
        }
        return r;
      } finally {
        _inflight.remove(key);
      }
    })();

    _inflight[key] = fut;
    return fut;
  }

  void invalidate(String key) {
    _inflight.remove(key);
    _lru.remove(key);
  }

  void _put(String key, dynamic value) {
    if (_lru.length >= maxEntries) {
      final oldestKey = _lru.keys.first;
      _lru.remove(oldestKey);
    }
    _lru[key] = value ?? _nullSentinel;
  }

  static String keyForSources(List<String> sources) {
    final joined = sources.join('|');
    return sha1.convert(utf8.encode(joined)).toString();
  }
}

@visibleForTesting
void debugResetThumbCacheFailures() {
  ThumbCache._failedUntilMs.clear();
}

String safeDecodeUriComponent(String input) {
  final s = input;
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

String redactSensitiveText(String input) {
  return core_redaction.redactSensitiveText(input);
}
