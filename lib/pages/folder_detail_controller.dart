import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/favorite_models.dart';
import '../sources/refs.dart';
import '../tag.dart';
import 'folder_detail_models.dart';

extension _CharExt on String {
  bool get isDigit => length == 1 && codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
}

class FolderDetailController extends ChangeNotifier {
  FolderDetailController({required FavoriteCollection collection})
      : _collection = collection;

  final FavoriteCollection _collection;
  bool _favoritePerDirectoryDisplaySettingsEnabled = false;
  final LinkedHashMap<String, LayerSettings> _perDirectoryDisplaySettings =
      LinkedHashMap<String, LayerSettings>();
  static const int maxPerDirectoryDisplaySettingsEntries = 500;

  List<Entry> _raw = <Entry>[];
  List<Entry> _scopeSearchRaw = const <Entry>[];
  String _query = '';
  String? _selectedTagId;
  bool _searchExpanded = false;
  bool _usingScopeSearch = false;
  FolderSearchScope _folderSearchScope = FolderSearchScope.currentCollection;
  String? _singleSearchCollectionId;
  bool _selectionMode = false;
  final Set<String> _selectedEntryKeys = <String>{};

  FavoriteCollection get collection => _collection;
  bool get favoritePerDirectoryDisplaySettingsEnabled =>
      _favoritePerDirectoryDisplaySettingsEnabled;
  set favoritePerDirectoryDisplaySettingsEnabled(bool value) {
    if (_favoritePerDirectoryDisplaySettingsEnabled == value) return;
    _favoritePerDirectoryDisplaySettingsEnabled = value;
    notifyListeners();
  }

  LinkedHashMap<String, LayerSettings> get perDirectoryDisplaySettings =>
      _perDirectoryDisplaySettings;

  void replacePerDirectoryDisplaySettings(Map<String, LayerSettings> data) {
    _perDirectoryDisplaySettings
      ..clear()
      ..addAll(data);
    notifyListeners();
  }

  String normalizeLocalDirForDisplayKey(String dir) {
    final raw = dir.trim();
    if (raw.isEmpty) return '';
    try {
      var out = p.normalize(raw);
      while (out.length > 1 &&
          (out.endsWith('/') || out.endsWith('\\')) &&
          !RegExp(r'^[a-zA-Z]:[\\/]$').hasMatch(out)) {
        out = out.substring(0, out.length - 1);
      }
      if (Platform.isWindows) out = out.toLowerCase();
      return out;
    } catch (_) {
      var out = raw;
      if (Platform.isWindows) out = out.toLowerCase();
      return out;
    }
  }

  String normalizeWebDavDirForDisplayKey(String rel) {
    var out = rel.trim().replaceAll('\\', '/');
    out = out.replaceAll(RegExp(r'/+'), '/');
    if (out.startsWith('/')) out = out.substring(1);
    if (out == '.' || out == '/') out = '';
    if (out.isNotEmpty && !out.endsWith('/')) out = '$out/';
    return out;
  }

  String normalizeEmbyPathForDisplayKey(String path) {
    final out = path.trim();
    if (out.isEmpty) return 'favorites';
    if (out.toLowerCase() == 'favorites') return 'favorites';
    if (out.toLowerCase().startsWith('view:')) {
      final id = out.substring('view:'.length).trim();
      if (id.isEmpty) return 'favorites';
      return 'view:$id';
    }
    return out;
  }

  String displaySettingsKeyForCtx(NavCtx ctx) {
    switch (ctx.kind) {
      case CtxKind.root:
        return '';
      case CtxKind.local:
        final dir = normalizeLocalDirForDisplayKey(ctx.localDir ?? '');
        if (dir.isEmpty) return '';
        return 'local://$dir';
      case CtxKind.webdav:
        final accId = (ctx.wdAccountId ?? '').trim();
        if (accId.isEmpty) return '';
        final rel = normalizeWebDavDirForDisplayKey(ctx.wdRel);
        return buildWebDavSource(accId, rel);
      case CtxKind.emby:
        final accId = (ctx.embyAccountId ?? '').trim();
        if (accId.isEmpty) return '';
        final path = normalizeEmbyPathForDisplayKey(ctx.embyPath);
        return buildEmbySource(accId, path);
    }
  }

  String normalizePersistedDisplaySettingsKey(String rawKey) {
    final key = rawKey.trim();
    if (key.isEmpty) return '';

    const localPrefix = 'local://';
    if (key.startsWith(localPrefix)) {
      final dir =
          normalizeLocalDirForDisplayKey(key.substring(localPrefix.length));
      if (dir.isEmpty) return '';
      return '$localPrefix$dir';
    }

    if (isWebDavSource(key)) {
      final ref = parseWebDavSource(key);
      if (ref == null || ref.accountId.trim().isEmpty) return '';
      final rel = normalizeWebDavDirForDisplayKey(ref.relPath);
      return buildWebDavSource(ref.accountId, rel);
    }

    if (isEmbySource(key)) {
      try {
        final u = Uri.parse(key);
        final accId = u.host.trim();
        if (accId.isEmpty) return '';
        final segs = u.pathSegments.where((x) => x.isNotEmpty).toList();
        final path = normalizeEmbyPathForDisplayKey(
          segs.isEmpty ? 'favorites' : segs.join('/'),
        );
        return buildEmbySource(accId, path);
      } catch (_) {
        return '';
      }
    }

    return key;
  }

  Map<String, dynamic> buildPerDirectoryDisplaySettingsJson() {
    final out = <String, dynamic>{};
    for (final e in _perDirectoryDisplaySettings.entries) {
      final key = normalizePersistedDisplaySettingsKey(e.key);
      if (key.isEmpty) continue;
      out[key] = e.value.toJson();
    }
    return out;
  }

  List<Entry> get raw => _raw;
  set raw(List<Entry> value) {
    _raw = value;
    _pruneSelection();
    notifyListeners();
  }

  List<Entry> get scopeSearchRaw => _scopeSearchRaw;
  set scopeSearchRaw(List<Entry> value) {
    _scopeSearchRaw = value;
    _pruneSelection();
    notifyListeners();
  }

  String get query => _query;
  set query(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  String? get selectedTagId => _selectedTagId;
  set selectedTagId(String? value) {
    final normalized = (value ?? '').trim();
    final next = normalized.isEmpty ? null : normalized;
    if (_selectedTagId == next) return;
    _selectedTagId = next;
    notifyListeners();
  }

  bool get searchExpanded => _searchExpanded;
  set searchExpanded(bool value) {
    if (_searchExpanded == value) return;
    _searchExpanded = value;
    notifyListeners();
  }

  bool get usingScopeSearch => _usingScopeSearch;
  set usingScopeSearch(bool value) {
    if (_usingScopeSearch == value) return;
    _usingScopeSearch = value;
    notifyListeners();
  }

  FolderSearchScope get folderSearchScope => _folderSearchScope;
  set folderSearchScope(FolderSearchScope value) {
    if (_folderSearchScope == value) return;
    _folderSearchScope = value;
    notifyListeners();
  }

  String? get singleSearchCollectionId => _singleSearchCollectionId;
  set singleSearchCollectionId(String? value) {
    final normalized = (value ?? '').trim();
    final next = normalized.isEmpty ? null : normalized;
    if (_singleSearchCollectionId == next) return;
    _singleSearchCollectionId = next;
    notifyListeners();
  }

  bool get selectionMode => _selectionMode;
  set selectionMode(bool value) {
    if (_selectionMode == value) return;
    _selectionMode = value;
    if (!value) {
      _selectedEntryKeys.clear();
    }
    notifyListeners();
  }

  Set<String> get selectedEntryKeys => _selectedEntryKeys;

  void clearSelection() {
    if (!_selectionMode && _selectedEntryKeys.isEmpty) return;
    _selectionMode = false;
    _selectedEntryKeys.clear();
    notifyListeners();
  }

  void toggleSelection(Entry entry, {required String Function(Entry e) keyOf}) {
    final key = keyOf(entry).trim();
    if (key.isEmpty) return;
    if (_selectedEntryKeys.contains(key)) {
      _selectedEntryKeys.remove(key);
    } else {
      _selectedEntryKeys.add(key);
      _selectionMode = true;
    }
    if (_selectedEntryKeys.isEmpty) {
      _selectionMode = false;
    }
    notifyListeners();
  }

  bool isSelected(Entry entry, {required String Function(Entry e) keyOf}) {
    final key = keyOf(entry).trim();
    if (key.isEmpty) return false;
    return _selectedEntryKeys.contains(key);
  }

  List<Entry> shown({
    required LayerSettings activeSettings,
    required String Function(Entry e) tagKeyOf,
  }) {
    final q = _query.trim().toLowerCase();
    var out = _usingScopeSearch
        ? [..._scopeSearchRaw]
        : (q.isEmpty
            ? [..._raw]
            : _raw.where((e) => e.name.toLowerCase().contains(q)).toList());

    final tid = _selectedTagId;
    if (tid != null && tid.isNotEmpty) {
      out = out.where((e) {
        final key = tagKeyOf(e).trim();
        if (key.isEmpty) return false;
        return TagStore.I.hasTag(key, tid);
      }).toList();
    }
    out.sort((a, b) => compareEntries(a, b, activeSettings: activeSettings));
    return out;
  }

  int compareEntries(
    Entry a,
    Entry b, {
    required LayerSettings activeSettings,
  }) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;

    final asc = activeSettings.asc;

    bool embyUnknownDate(Entry e) =>
        e.isEmby && !e.isDir && e.modified.millisecondsSinceEpoch == 0;
    bool embyUnknownSize(Entry e) => e.isEmby && !e.isDir && e.size == 0;
    int byName() => naturalSort(a.name.toLowerCase(), b.name.toLowerCase());

    int r;
    switch (activeSettings.sortKey) {
      case SortKey.name:
        r = byName();
        if (r != 0) return asc ? r : -r;
        r = a.modified.compareTo(b.modified);
        return asc ? r : -r;

      case SortKey.date:
        final au = embyUnknownDate(a);
        final bu = embyUnknownDate(b);
        if (au != bu) return au ? 1 : -1;
        r = a.modified.compareTo(b.modified);
        if (r != 0) return asc ? r : -r;
        r = byName();
        return asc ? r : -r;

      case SortKey.size:
        final au = embyUnknownSize(a);
        final bu = embyUnknownSize(b);
        if (au != bu) return au ? 1 : -1;
        r = a.size.compareTo(b.size);
        if (r != 0) return asc ? r : -r;
        r = byName();
        return asc ? r : -r;

      case SortKey.type:
        r = a.typeKey.compareTo(b.typeKey);
        if (r != 0) return asc ? r : -r;
        r = byName();
        return asc ? r : -r;
    }
  }

  int naturalSort(String a, String b) {
    return compareNaturalText(a, b);
  }

  void _pruneSelection() {
    if (!_selectionMode) return;
    final keys = _raw
        .where((e) => !e.isLoading)
        .map((e) => e.displayPath.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    _selectedEntryKeys.removeWhere((k) => !keys.contains(k));
    if (_selectedEntryKeys.isEmpty) {
      _selectionMode = false;
    }
  }

  void touchPerDirectoryDisplaySettingsKey(String key) {
    final normalized = normalizePersistedDisplaySettingsKey(key);
    if (normalized.isEmpty) return;
    final hit = _perDirectoryDisplaySettings.remove(normalized);
    if (hit != null) {
      _perDirectoryDisplaySettings[normalized] = hit;
    }
  }

  LayerSettings ensurePerDirectoryLayerSettings(
    String key, {
    required LayerSettings seed,
  }) {
    final normalized = normalizePersistedDisplaySettingsKey(key);
    if (normalized.isEmpty) return seed;
    final hit = _perDirectoryDisplaySettings[normalized];
    if (hit != null) {
      touchPerDirectoryDisplaySettingsKey(normalized);
      return hit;
    }
    final created = seed.copy();
    _perDirectoryDisplaySettings[normalized] = created;
    touchPerDirectoryDisplaySettingsKey(normalized);
    while (_perDirectoryDisplaySettings.length >
        maxPerDirectoryDisplaySettingsEntries) {
      _perDirectoryDisplaySettings
          .remove(_perDirectoryDisplaySettings.keys.first);
    }
    return created;
  }
}

int compareNaturalText(String a, String b) {
  var aIdx = 0;
  var bIdx = 0;
  final aLen = a.length;
  final bLen = b.length;

  while (aIdx < aLen && bIdx < bLen) {
    final aChar = a[aIdx];
    final bChar = b[bIdx];

    if (aChar.isDigit && bChar.isDigit) {
      final aStart = aIdx;
      final bStart = bIdx;
      while (aIdx < aLen && a[aIdx].isDigit) {
        aIdx++;
      }
      while (bIdx < bLen && b[bIdx].isDigit) {
        bIdx++;
      }

      final aNum = a.substring(aStart, aIdx);
      final bNum = b.substring(bStart, bIdx);
      final aTrimmed = aNum.replaceFirst(RegExp(r'^0+'), '');
      final bTrimmed = bNum.replaceFirst(RegExp(r'^0+'), '');
      final aNorm = aTrimmed.isEmpty ? '0' : aTrimmed;
      final bNorm = bTrimmed.isEmpty ? '0' : bTrimmed;

      final lenCompare = aNorm.length.compareTo(bNorm.length);
      if (lenCompare != 0) return lenCompare;

      final valueCompare = aNorm.compareTo(bNorm);
      if (valueCompare != 0) return valueCompare;
    } else {
      if (aChar != bChar) return aChar.compareTo(bChar);
      aIdx++;
      bIdx++;
    }
  }

  if (aIdx == aLen && bIdx == bLen) {
    final zeroPadCompare = a.length.compareTo(b.length);
    if (zeroPadCompare != 0) return zeroPadCompare;
  }

  return aLen.compareTo(bLen);
}
