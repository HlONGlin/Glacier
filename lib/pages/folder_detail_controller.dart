part of '../pages.dart';

class FolderDetailController extends ChangeNotifier {
  FolderDetailController({required FavoriteCollection collection})
      : _collection = collection;

  final FavoriteCollection _collection;
  bool _favoritePerDirectoryDisplaySettingsEnabled = false;
  final LinkedHashMap<String, LayerSettings> _perDirectoryDisplaySettings =
      LinkedHashMap<String, LayerSettings>();
  static const int maxPerDirectoryDisplaySettingsEntries = 500;

  List<_Entry> _raw = <_Entry>[];
  List<_Entry> _scopeSearchRaw = const <_Entry>[];
  String _query = '';
  String? _selectedTagId;
  bool _searchExpanded = false;
  bool _usingScopeSearch = false;
  _FolderSearchScope _folderSearchScope = _FolderSearchScope.currentCollection;
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

  String displaySettingsKeyForCtx(_NavCtx ctx) {
    switch (ctx.kind) {
      case _CtxKind.root:
        return '';
      case _CtxKind.local:
        final dir = normalizeLocalDirForDisplayKey(ctx.localDir ?? '');
        if (dir.isEmpty) return '';
        return 'local://$dir';
      case _CtxKind.webdav:
        final accId = (ctx.wdAccountId ?? '').trim();
        if (accId.isEmpty) return '';
        final rel = normalizeWebDavDirForDisplayKey(ctx.wdRel);
        return buildWebDavSourceWithDir(accId, rel, isDir: true);
      case _CtxKind.emby:
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
      return buildWebDavSourceWithDir(ref.accountId, rel, isDir: true);
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

  List<_Entry> get raw => _raw;
  set raw(List<_Entry> value) {
    _raw = value;
    _pruneSelection();
    notifyListeners();
  }

  List<_Entry> get scopeSearchRaw => _scopeSearchRaw;
  set scopeSearchRaw(List<_Entry> value) {
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

  _FolderSearchScope get folderSearchScope => _folderSearchScope;
  set folderSearchScope(_FolderSearchScope value) {
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

  void toggleSelection(_Entry entry,
      {required String Function(_Entry e) keyOf}) {
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

  bool isSelected(_Entry entry, {required String Function(_Entry e) keyOf}) {
    final key = keyOf(entry).trim();
    if (key.isEmpty) return false;
    return _selectedEntryKeys.contains(key);
  }

  List<_Entry> shown({
    required LayerSettings activeSettings,
    required String Function(_Entry e) tagKeyOf,
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
    _Entry a,
    _Entry b, {
    required LayerSettings activeSettings,
  }) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;

    final asc = activeSettings.asc;

    bool embyUnknownDate(_Entry e) =>
        e.isEmby && !e.isDir && e.modified.millisecondsSinceEpoch == 0;
    bool embyUnknownSize(_Entry e) => e.isEmby && !e.isDir && e.size == 0;
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
    var aIdx = 0;
    var bIdx = 0;
    final aLen = a.length;
    final bLen = b.length;

    while (aIdx < aLen && bIdx < bLen) {
      final aChar = a[aIdx];
      final bChar = b[bIdx];

      if (aChar.isDigit && bChar.isDigit) {
        var aNum = '';
        var bNum = '';
        while (aIdx < aLen && a[aIdx].isDigit) {
          aNum += a[aIdx++];
        }
        while (bIdx < bLen && b[bIdx].isDigit) {
          bNum += b[bIdx++];
        }

        final numA = int.parse(aNum);
        final numB = int.parse(bNum);
        if (numA != numB) return numA.compareTo(numB);
      } else {
        if (aChar != bChar) return aChar.compareTo(bChar);
        aIdx++;
        bIdx++;
      }
    }
    return aLen.compareTo(bLen);
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
