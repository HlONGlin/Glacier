import '../sources/refs.dart';

enum CtxKind { root, local, webdav, emby }

enum FolderSearchScope {
  currentDirectory,
  currentCollection,
  allCollections,
  singleCollection,
}

class NavCtx {
  final CtxKind kind;
  final String? title;
  final String? localDir;
  final String? wdAccountId;
  final String wdRel;
  final String? embyAccountId;
  final String embyPath;

  const NavCtx.root()
      : kind = CtxKind.root,
        title = null,
        localDir = null,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const NavCtx.local(this.localDir, {this.title})
      : kind = CtxKind.local,
        wdAccountId = null,
        wdRel = '',
        embyAccountId = null,
        embyPath = '';

  const NavCtx.webdav(
      {required this.wdAccountId, required this.wdRel, this.title})
      : kind = CtxKind.webdav,
        localDir = null,
        embyAccountId = null,
        embyPath = '';

  const NavCtx.emby(
      {required this.embyAccountId, this.embyPath = 'favorites', this.title})
      : kind = CtxKind.emby,
        localDir = null,
        wdAccountId = null,
        wdRel = '';
}

class Entry {
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

  const Entry({
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
      ? buildWebDavSource(wdAccountId ?? '', wdRelPath ?? '')
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

  static Entry loading(int i) => Entry(
        isDir: false,
        name: 'loading_$i',
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        typeKey: kLoadingTypeKey,
        origin: null,
      );
}
