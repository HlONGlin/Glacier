part of '../pages.dart';

enum _CtxKind { root, local, webdav, emby }

enum _FolderSearchScope {
  currentDirectory,
  currentCollection,
  allCollections,
  singleCollection,
}

class _NavCtx {
  final _CtxKind kind;
  final String? title;
  final String? localDir;
  final String? wdAccountId;
  final String wdRel;
  final String? embyAccountId;
  final String embyPath;

  const _NavCtx.root({this.title})
      : kind = _CtxKind.root,
        localDir = null,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const _NavCtx.local(this.localDir, {this.title})
      : kind = _CtxKind.local,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const _NavCtx.webdav(
      {required this.wdAccountId, required this.wdRel, this.title})
      : kind = _CtxKind.webdav,
        localDir = null,
        embyAccountId = null,
        embyPath = '';

  const _NavCtx.emby(
      {required this.embyAccountId, this.embyPath = 'favorites', this.title})
      : kind = _CtxKind.emby,
        localDir = null,
        wdAccountId = null,
        wdRel = '';
}

class _Entry {
  final bool isDir;
  final String name;
  final int size;
  final DateTime modified;
  final String typeKey;
  final String? origin;

  final String? localPath;

  final String? wdAccountId;
  final String? wdRelPath;
  final String? wdHref;

  final String? embyAccountId;
  final String? embyItemId;
  final String? embyCoverUrl;
  final double? embyAspectRatio;

  final String? searchCollectionId;
  final String? searchCollectionName;

  const _Entry({
    required this.isDir,
    required this.name,
    required this.size,
    required this.modified,
    required this.typeKey,
    required this.origin,
    this.localPath,
    this.wdAccountId,
    this.wdRelPath,
    this.wdHref,
    this.embyAccountId,
    this.embyItemId,
    this.embyCoverUrl,
    this.embyAspectRatio,
    this.searchCollectionId,
    this.searchCollectionName,
  });

  bool get isWebDav => wdAccountId != null;
  bool get isEmby => embyAccountId != null;

  String get displayPath => isWebDav
      ? _buildWebDavSource(wdAccountId ?? '', wdRelPath ?? '', isDir: isDir)
      : (isEmby
          ? () {
              final id = (embyItemId ?? '').trim();
              if (id.isEmpty) {
                return buildEmbySource(embyAccountId ?? '', 'item:');
              }
              final nm = name.trim();
              return buildEmbySource(embyAccountId ?? '', 'item:$id', name: nm);
            }()
          : (localPath ?? ''));

  static const String kLoadingTypeKey = '__loading__';
  bool get isLoading => typeKey == kLoadingTypeKey;

  static _Entry loading(int i) => _Entry(
        isDir: false,
        name: 'loading_$i',
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        typeKey: kLoadingTypeKey,
        origin: null,
      );
}
