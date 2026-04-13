import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

class AppHistoryFolderCtx {
  final String kind;
  final String? localDir;
  final String? wdAccountId;
  final String wdRel;
  final String? embyAccountId;
  final String embyPath;

  const AppHistoryFolderCtx.local(String dir)
      : kind = 'local',
        localDir = dir,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const AppHistoryFolderCtx.webdav({
    required String accountId,
    required String rel,
  })  : kind = 'webdav',
        localDir = null,
        wdAccountId = accountId,
        wdRel = rel,
        embyAccountId = null,
        embyPath = '';

  const AppHistoryFolderCtx.emby({
    required String accountId,
    String path = 'favorites',
  })  : kind = 'emby',
        localDir = null,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = accountId,
        embyPath = path;
}

class AppHistory {
  AppHistory._();

  static const String _kHistoryKey = 'glacier_history_v1';
  static const int _maxEntries = 200;
  static const Duration _kSaveDebounce = Duration(milliseconds: 350);

  static List<Map<String, dynamic>>? _cache;
  static Future<void>? _loadFuture;
  static Timer? _saveTimer;
  static Future<void> _writeQueue = Future<void>.value();
  static bool _dirty = false;

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static List<Map<String, dynamic>> _cloneList(
    List<Map<String, dynamic>> list,
  ) {
    return list.map((e) => Map<String, dynamic>.from(e)).toList(growable: true);
  }

  static Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final pending = _loadFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = () async {
      final sp = await _sp();
      final raw = sp.getString(_kHistoryKey);
      if (raw == null || raw.trim().isEmpty) {
        _cache = <Map<String, dynamic>>[];
        return;
      }
      try {
        final j = jsonDecode(raw);
        if (j is! List) {
          _cache = <Map<String, dynamic>>[];
          return;
        }
        final list =
            j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        final normalized = _normalize(list);
        _cache = normalized;
        if (normalized.length != list.length) {
          _scheduleSave();
        }
      } catch (_) {
        _cache = <Map<String, dynamic>>[];
      }
    }();

    _loadFuture = future;
    try {
      await future;
    } finally {
      if (identical(_loadFuture, future)) {
        _loadFuture = null;
      }
    }
  }

  static Future<void> _persistSnapshot(List<Map<String, dynamic>> list) async {
    final sp = await _sp();
    if (list.isEmpty) {
      await sp.remove(_kHistoryKey);
      return;
    }
    await sp.setString(_kHistoryKey, jsonEncode(list));
  }

  static void _scheduleSave() {
    if (_cache == null) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_kSaveDebounce, () {
      unawaited(_flushDirty());
    });
  }

  static Future<void> _flushDirty() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty || _cache == null) return;

    final snapshot = _cloneList(_cache!);
    _dirty = false;
    final write = _writeQueue.then((_) => _persistSnapshot(snapshot));
    _writeQueue = write.catchError((_) {});
    await write;

    if (_dirty && _saveTimer == null) {
      _scheduleSave();
    }
  }

  @visibleForTesting
  static Future<void> debugResetForTest() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _cache = null;
    _loadFuture = null;
    _dirty = false;
    _writeQueue = Future<void>.value();
  }

  static Future<List<Map<String, dynamic>>> load() async {
    await _ensureLoaded();
    return _cloneList(_cache ?? const <Map<String, dynamic>>[]);
  }

  static List<Map<String, dynamic>> _normalize(
      List<Map<String, dynamic>> list) {
    if (list.length < 2) return list;

    const int windowMs = 10 * 1000;

    bool isEmbyPath(String p) => p.startsWith('emby://');
    bool isWebDavPath(String p) => p.startsWith('webdav://');

    String hostOf(String p) {
      try {
        return Uri.parse(p).host;
      } catch (_) {
        final i = p.indexOf('://');
        if (i < 0) return '';
        final rest = p.substring(i + 3);
        final slash = rest.indexOf('/');
        return slash < 0 ? rest : rest.substring(0, slash);
      }
    }

    final out = <Map<String, dynamic>>[];

    for (int i = 0; i < list.length; i++) {
      final cur = list[i];
      var drop = false;

      if (i > 0) {
        final prev = out.isEmpty ? null : out.last;
        if (prev != null) {
          final prevKind = (prev['kind'] ?? 'media').toString();
          final curKind = (cur['kind'] ?? 'media').toString();

          if (prevKind == 'media' && curKind == 'folder') {
            final prevT = int.tryParse((prev['t'] ?? '').toString()) ?? 0;
            final curT = int.tryParse((cur['t'] ?? '').toString()) ?? 0;
            final dt = (prevT - curT).abs();

            if (prevT > 0 && curT > 0 && dt <= windowMs) {
              final prevPath = (prev['path'] ?? '').toString();
              final ctxKind = (cur['ctxKind'] ?? '').toString();

              if (ctxKind == 'emby' && isEmbyPath(prevPath)) {
                final accId = (cur['embyAccountId'] ?? '').toString();
                if (accId.isNotEmpty && hostOf(prevPath) == accId) {
                  drop = true;
                }
              }

              if (ctxKind == 'webdav' && isWebDavPath(prevPath)) {
                final accId = (cur['wdAccountId'] ?? '').toString();
                if (accId.isNotEmpty && hostOf(prevPath) == accId) {
                  drop = true;
                }
              }

              if (ctxKind == 'local') {
                final dir = (cur['localDir'] ?? '').toString();
                if (dir.isNotEmpty && !prevPath.contains('://')) {
                  try {
                    final normDir = p.normalize(dir);
                    final normPath = p.normalize(prevPath);
                    if (p.isWithin(normDir, normPath)) drop = true;
                  } catch (_) {}
                }
              }
            }
          }
        }
      }

      if (!drop) out.add(cur);
    }

    return out;
  }

  static Future<void> upsert({
    required String path,
    required String title,
    int? positionMs,
    String kind = 'media',
    String? favId,
    String? coverPath,
  }) async {
    if (path.trim().isEmpty) return;
    if (!await AppSettings.getHistoryEnabled()) return;

    var safeTitle = title.trim();
    if (safeTitle.isEmpty) safeTitle = '未命名';
    if (safeTitle.length > 160) safeTitle = '${safeTitle.substring(0, 160)}…';

    final now = DateTime.now().millisecondsSinceEpoch;
    await _ensureLoaded();
    final list = _cache!;
    list.removeWhere((e) => (e['path'] ?? '') == path);

    list.insert(0, <String, dynamic>{
      'kind': kind,
      'path': path,
      'title': safeTitle,
      't': now,
      if (positionMs != null) 'pos': positionMs,
      if (favId != null && favId.trim().isNotEmpty) 'favId': favId,
      if (coverPath != null && coverPath.trim().isNotEmpty) 'cover': coverPath,
    });

    if (list.length > _maxEntries) {
      list.removeRange(_maxEntries, list.length);
    }

    _scheduleSave();
  }

  static Future<void> upsertFolder({
    required String favId,
    required String title,
    String? coverPath,
  }) async {
    final path = 'fav://$favId';
    await upsert(
      path: path,
      title: title,
      kind: 'fav',
      favId: favId,
      coverPath: coverPath,
    );
  }

  static Future<void> upsertFolderCtx({
    required AppHistoryFolderCtx ctx,
    required String title,
    String? coverPath,
  }) async {
    try {
      final kind = ctx.kind.trim();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!await AppSettings.getHistoryEnabled()) return;

      await _ensureLoaded();
      final list = _cache!;

      String path;
      final entry = <String, dynamic>{
        'kind': 'folder',
        'title': title,
        't': now,
      };

      if (kind.contains('local')) {
        final dir = (ctx.localDir ?? '').toString().trim();
        if (dir.isEmpty) return;
        path = 'folder://local/$dir';
        entry['ctxKind'] = 'local';
        entry['localDir'] = dir;
      } else if (kind.contains('webdav')) {
        final accId = (ctx.wdAccountId ?? '').toString().trim();
        var rel = ctx.wdRel.trim();
        if (accId.isEmpty) return;
        if (rel.isNotEmpty && !rel.endsWith('/')) rel = '$rel/';
        path = 'folder://webdav/$accId/$rel';
        entry['ctxKind'] = 'webdav';
        entry['wdAccountId'] = accId;
        entry['wdRel'] = rel;
      } else if (kind.contains('emby')) {
        final accId = (ctx.embyAccountId ?? '').toString().trim();
        final pth = ctx.embyPath.trim();
        if (accId.isEmpty) return;
        path = 'folder://emby/$accId/${pth.isEmpty ? 'favorites' : pth}';
        entry['ctxKind'] = 'emby';
        entry['embyAccountId'] = accId;
        entry['embyPath'] = pth.isEmpty ? 'favorites' : pth;
      } else {
        return;
      }

      entry['path'] = path;
      if (coverPath != null && coverPath.trim().isNotEmpty) {
        entry['cover'] = coverPath;
      }

      list.removeWhere((e) => (e['path'] ?? '') == path);
      list.insert(0, entry);
      if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
      _scheduleSave();
    } catch (_) {}
  }

  static Future<void> removeAt(int index) async {
    await _ensureLoaded();
    final list = _cache!;
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    _scheduleSave();
    await _flushDirty();
  }

  static Future<void> clear() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _cache = <Map<String, dynamic>>[];
    _dirty = false;
    final write = _writeQueue.then((_) async {
      final sp = await _sp();
      await sp.remove(_kHistoryKey);
    });
    _writeQueue = write.catchError((_) {});
    await write;
  }

  static Future<void> updateProgress(
      {required String path, required int positionMs}) async {
    if (path.trim().isEmpty) return;
    if (!await AppSettings.getHistoryEnabled()) return;

    await _ensureLoaded();
    final list = _cache!;
    final idx = list.indexWhere((e) => (e['path'] ?? '') == path);
    if (idx < 0) return;
    list[idx]['pos'] = positionMs;
    _scheduleSave();
  }
}
