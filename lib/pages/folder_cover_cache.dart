part of '../pages.dart';

class _CoverInfo {
  /// source: 'local' | 'webdav' | 'emby'
  final String source;

  // local 用
  final String? localPath;

  // webdav 用
  final String? wdAccountId;
  final String? wdRelPath;
  final String? wdHref;

  // emby 用
  final String? embyAccountId;
  final String? embyCoverUrl;

  final bool isVideo;

  const _CoverInfo.local(this.localPath, {required this.isVideo})
      : source = 'local',
        wdAccountId = null,
        wdRelPath = null,
        wdHref = null,
        embyAccountId = null,
        embyCoverUrl = null;

  const _CoverInfo.webdav({
    required this.wdAccountId,
    required this.wdRelPath,
    required this.wdHref,
    required this.isVideo,
  })  : source = 'webdav',
        localPath = null,
        embyAccountId = null,
        embyCoverUrl = null;

  const _CoverInfo.emby({
    required this.embyAccountId,
    required this.embyCoverUrl,
  })  : source = 'emby',
        localPath = null,
        wdAccountId = null,
        wdRelPath = null,
        wdHref = null,
        isVideo = false;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'localPath': localPath,
        'wdAccountId': wdAccountId,
        'wdRelPath': wdRelPath,
        'wdHref': wdHref,
        'embyAccountId': embyAccountId,
        'embyCoverUrl': embyCoverUrl,
        'isVideo': isVideo,
      };

  static _CoverInfo? fromJson(Map<String, dynamic> j) {
    final src = (j['source'] ?? '').toString();
    final isVideo = j['isVideo'] == true;
    if (src == 'local') {
      final p = (j['localPath'] ?? '').toString();
      if (p.trim().isEmpty) return null;
      return _CoverInfo.local(p, isVideo: isVideo);
    }
    if (src == 'webdav') {
      final acc = (j['wdAccountId'] ?? '').toString();
      final rel = (j['wdRelPath'] ?? '').toString();
      final href = (j['wdHref'] ?? '').toString();
      if (acc.trim().isEmpty || rel.trim().isEmpty || href.trim().isEmpty) {
        return null;
      }
      return _CoverInfo.webdav(
        wdAccountId: acc,
        wdRelPath: rel,
        wdHref: href,
        isVideo: isVideo,
      );
    }
    if (src == 'emby') {
      final acc = (j['embyAccountId'] ?? '').toString();
      final url = (j['embyCoverUrl'] ?? '').toString();
      if (acc.trim().isEmpty || url.trim().isEmpty) return null;
      return _CoverInfo.emby(embyAccountId: acc, embyCoverUrl: url);
    }
    return null;
  }
}

/// Folder cover result cache (memory + SharedPreferences + TTL)
class _FolderCoverCache {
  _FolderCoverCache._(this._sp, {required this.ttl});
  final SharedPreferences _sp;
  final Duration ttl;
  static const String _k = 'folder_cover_cache_v1';
  final Map<String, Map<String, dynamic>> _mem =
      <String, Map<String, dynamic>>{};

  static Future<_FolderCoverCache> init({
    Duration ttl = const Duration(hours: 12),
  }) async {
    final sp = await SharedPreferences.getInstance();
    final c = _FolderCoverCache._(sp, ttl: ttl);
    c._load();
    return c;
  }

  void _load() {
    final raw = _sp.getString(_k);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      for (final e in m.entries) {
        final v = e.value;
        if (v is Map) _mem[e.key] = v.cast<String, dynamic>();
      }
    } catch (_) {
      // ignore corrupted cache
    }
  }

  bool _isFresh(int tsMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - tsMs <= ttl.inMilliseconds;
  }

  _CoverInfo? getIfFresh(String key) {
    final v = _mem[key];
    if (v == null) return null;
    final ts = v['ts'];
    final cover = v['cover'];
    if (ts is! int || cover is! Map) return null;
    if (!_isFresh(ts)) return null;
    return _CoverInfo.fromJson(cover.cast<String, dynamic>());
  }

  Future<void> put(String key, _CoverInfo info) async {
    _mem[key] = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'cover': info.toJson(),
    };
    await _flush();
  }

  Future<void> invalidate(String key) async {
    _mem.remove(key);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _sp.setString(_k, jsonEncode(_mem));
    } catch (_) {
      // ignore
    }
  }
}
