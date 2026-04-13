part of '../pages.dart';

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

class _PreviewTarget {
  final String path;
  final bool isImage;
  const _PreviewTarget(this.path, this.isImage);
}

/// ✅ 核心改造：移除WebDAV预览屏蔽，支持WebDAV封面加载
class _MultiSourcePreview extends StatefulWidget {
  final List<String> sources;
  const _MultiSourcePreview(this.sources);

  @override
  State<_MultiSourcePreview> createState() => _MultiSourcePreviewState();
}

class _MultiSourcePreviewState extends State<_MultiSourcePreview>
    with AutomaticKeepAliveClientMixin {
  static const int _kMaxWebDavPreviewFutureEntries = 120;
  static const int _kMaxWebDavPreviewFileEntries = 120;
  Future<_PreviewTarget?>? _future;
  Future<Map<String, WebDavAccount>>? _accFuture;
  final Map<String, Future<File>> _webDavCoverFuture = {};
  final Map<String, Future<File?>> _webDavVideoThumbFuture = {};
  final Map<String, File> _webDavCoverFile = {};
  final Map<String, File> _webDavVideoThumbFile = {};

  void _trimFutureCache<T>(Map<String, Future<T>> cache, int maxEntries) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  void _trimFileCache(Map<String, File> cache, int maxEntries) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  @override
  void initState() {
    super.initState();
    _future = _pickFromSources(widget.sources);
    _accFuture = loadPageWebDavAccountsMap();
  }

  @override
  void didUpdateWidget(covariant _MultiSourcePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSources(oldWidget.sources, widget.sources)) {
      _future = _pickFromSources(widget.sources);
    }
  }

  bool _sameSources(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.sources.isEmpty) return const _CoverPlaceholder();

    return FutureBuilder<_PreviewTarget?>(
      future: _future,
      builder: (_, s) {
        final t = s.data;
        if (t == null) return const _CoverPlaceholder();

        if (isPageWebDavSource(t.path)) {
          final ref = parsePageWebDavSource(t.path);
          if (ref != null && !ref.isDir) {
            return FutureBuilder<Map<String, WebDavAccount>>(
              future: _accFuture,
              builder: (_, accSnap) {
                final accMap = accSnap.data;
                if (accMap == null) return const _CoverPlaceholder();

                final acc = accMap[ref.accountId];
                if (acc == null) return const _CoverPlaceholder();

                final client =
                    WebDavManager.instance.getClient(ref.accountId) ??
                        WebDavClient(acc);
                final href = client.resolveRel(ref.relPath).toString();

                if (t.isImage) {
                  final cached = _webDavCoverFile[href];
                  if (cached != null && cached.existsSync()) {
                    return _ProportionalPreviewBox(
                      child: Image.file(
                        cached,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
                      ),
                    );
                  }
                  final coverFuture = _webDavCoverFuture.putIfAbsent(
                    href,
                    () => client
                        .ensureCoverCached(href, p.basename(ref.relPath))
                        .then((f) {
                      _webDavCoverFile[href] = f;
                      _trimFileCache(
                        _webDavCoverFile,
                        _kMaxWebDavPreviewFileEntries,
                      );
                      return f;
                    }),
                  );
                  _trimFutureCache(
                    _webDavCoverFuture,
                    _kMaxWebDavPreviewFutureEntries,
                  );
                  return FutureBuilder<File>(
                    future: coverFuture,
                    builder: (_, snap) {
                      final f = snap.data;
                      if (f != null && f.existsSync()) {
                        return _ProportionalPreviewBox(
                          child: Image.file(
                            f,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const _CoverPlaceholder(),
                          ),
                        );
                      }
                      return const _CoverPlaceholder();
                    },
                  );
                }

                final cachedV = _webDavVideoThumbFile[href];
                if (cachedV != null &&
                    cachedV.existsSync() &&
                    cachedV.lengthSync() > 0) {
                  return _ProportionalPreviewBox(
                    child: Image.file(
                      cachedV,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                    ),
                  );
                }
                final vFuture = _webDavVideoThumbFuture.putIfAbsent(
                  href,
                  () => getPageWebDavVideoThumbFile(
                    client,
                    href,
                    p.basename(ref.relPath),
                    maxBytes: 12 * 1024 * 1024,
                  ).then((f) {
                    if (f != null) _webDavVideoThumbFile[href] = f;
                    _trimFileCache(
                      _webDavVideoThumbFile,
                      _kMaxWebDavPreviewFileEntries,
                    );
                    return f;
                  }),
                );
                _trimFutureCache(
                  _webDavVideoThumbFuture,
                  _kMaxWebDavPreviewFutureEntries,
                );
                return FutureBuilder<File?>(
                  future: vFuture,
                  builder: (_, snap) {
                    final f = snap.data;
                    if (f != null && f.existsSync() && f.lengthSync() > 0) {
                      return _ProportionalPreviewBox(
                        child: Image.file(
                          f,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const _VideoPlaceholder(),
                        ),
                      );
                    }
                    return const _VideoPlaceholder();
                  },
                );
              },
            );
          }
        }

        return t.isImage
            ? _ProportionalPreviewBox(
                child: Image.file(File(t.path),
                    errorBuilder: (_, __, ___) => const _CoverPlaceholder()),
              )
            : FutureBuilder<File?>(
                future: ThumbCache.getOrCreateVideoPreviewFrame(
                    t.path, Duration.zero),
                builder: (_, snap) {
                  final f = snap.data;
                  if (f != null && f.existsSync() && f.lengthSync() > 0) {
                    return _ProportionalPreviewBox(
                      child: Image.file(
                        f,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                      ),
                    );
                  }
                  return const _VideoPlaceholder();
                },
              );
      },
    );
  }

  Future<_PreviewTarget?> _pickFromSources(List<String> sources) async {
    for (final s in sources) {
      if (isPageWebDavSource(s)) {
        final target = await _pickFromWebDavSource(s);
        if (target != null) return target;
      } else {
        final target = await _pickFromFolder(s);
        if (target != null) return target;
      }
    }
    return null;
  }

  Future<_PreviewTarget?> _pickFromWebDavSource(String source) async {
    final ref = parsePageWebDavSource(source);
    if (ref == null || !ref.isDir) return null;

    final accMap = await loadPageWebDavAccountsMap();
    final acc = accMap[ref.accountId];
    if (acc == null) return null;

    final client = WebDavClient(acc);

    const preferredCoverNames = <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
      'folder.jpg',
      'folder.jpeg',
      'folder.png',
      'folder.webp',
      'thumb.jpg',
      'thumb.jpeg',
      'thumb.png',
      'thumb.webp',
      'poster.jpg',
      'poster.jpeg',
      'poster.png',
      'poster.webp',
    ];

    var start = ref.relPath;
    if (start.isNotEmpty && !start.endsWith('/')) start = '$start/';

    const maxFirst = 350;
    const maxFirstDirs = 80;

    WebDavItem? firstImage;
    WebDavItem? firstVideo;
    final firstDirs = <String>[];

    try {
      final list = await client.list(start);
      var seen = 0;
      for (final item in list) {
        if (seen++ >= maxFirst) break;

        if (item.isDir) {
          var child = item.relPath;
          if (!child.endsWith('/')) child = '$child/';
          if (firstDirs.length < maxFirstDirs) firstDirs.add(child);
          continue;
        }

        final name = (item.name).toLowerCase();
        if (preferredCoverNames.contains(name) && isPageImageName(item.name)) {
          return _PreviewTarget(
            buildPageWebDavSource(ref.accountId, item.relPath, isDir: false),
            true,
          );
        }

        if (firstImage == null && isPageImageName(item.name)) firstImage = item;
        if (firstVideo == null && isPageVideoName(item.name)) firstVideo = item;
      }
    } catch (_) {}

    if (firstImage != null) {
      return _PreviewTarget(
          buildPageWebDavSource(ref.accountId, firstImage.relPath,
              isDir: false),
          true);
    }
    if (firstVideo != null) {
      return _PreviewTarget(
          buildPageWebDavSource(ref.accountId, firstVideo.relPath,
              isDir: false),
          false);
    }

    const maxScan = 900;
    const maxDepth = 2;
    var scanned = 0;
    var depth = 0;
    var cur = List<String>.from(firstDirs);
    WebDavItem? fallbackVideo;

    try {
      while (cur.isNotEmpty && scanned < maxScan && depth < maxDepth) {
        final next = <String>[];
        for (final dirRel in cur) {
          if (scanned >= maxScan) break;
          final list = await client.list(dirRel);
          for (final item in list) {
            scanned++;
            if (scanned > maxScan) break;
            if (item.isDir) {
              var child = item.relPath;
              if (!child.endsWith('/')) child = '$child/';
              next.add(child);
              continue;
            }
            if (isPageImageName(item.name)) {
              return _PreviewTarget(
                  buildPageWebDavSource(ref.accountId, item.relPath,
                      isDir: false),
                  true);
            }
            if (fallbackVideo == null && isPageVideoName(item.name)) {
              fallbackVideo = item;
            }
          }
        }

        if (fallbackVideo != null) {
          return _PreviewTarget(
              buildPageWebDavSource(ref.accountId, fallbackVideo.relPath,
                  isDir: false),
              false);
        }

        cur = next;
        depth++;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {}

    return null;
  }

  Future<_PreviewTarget?> _pickFromFolder(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return null;

    const preferredCoverNames = <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
      'folder.jpg',
      'folder.jpeg',
      'folder.png',
      'folder.webp',
      'thumb.jpg',
      'thumb.jpeg',
      'thumb.png',
      'thumb.webp',
      'poster.jpg',
      'poster.jpeg',
      'poster.png',
      'poster.webp',
    ];

    const maxFirstEntries = 400;
    const maxFirstSubDirs = 60;
    File? firstImage;
    File? firstVideo;
    final firstLevelDirs = <Directory>[];

    try {
      var seen = 0;
      await for (final e in dir.list(followLinks: false)) {
        if (seen++ >= maxFirstEntries) break;

        if (e is File) {
          final name = p.basename(e.path).toLowerCase();
          if (preferredCoverNames.contains(name) && isPageImagePath(e.path)) {
            return _PreviewTarget(e.path, true);
          }
          if (firstImage == null && isPageImagePath(e.path)) {
            firstImage = e;
          } else if (firstVideo == null && isPageVideoPath(e.path)) {
            firstVideo = e;
          }
        } else if (e is Directory) {
          if (firstLevelDirs.length < maxFirstSubDirs) firstLevelDirs.add(e);
        }
      }
    } catch (_) {}

    if (firstImage != null) return _PreviewTarget(firstImage.path, true);
    if (firstVideo != null) return _PreviewTarget(firstVideo.path, false);

    const maxDepth = 2, maxFolders = 40, maxFiles = 800;
    var depth = 0, folders = 0, files = 0;
    var cur = List<Directory>.from(firstLevelDirs);

    while (cur.isNotEmpty &&
        depth < maxDepth &&
        folders < maxFolders &&
        files < maxFiles) {
      final next = <Directory>[];

      for (final d in cur) {
        if (folders >= maxFolders || files >= maxFiles) break;
        folders++;
        try {
          await for (final e in d.list(followLinks: false)) {
            if (files >= maxFiles) break;
            if (e is File) {
              files++;
              if (isPageImagePath(e.path)) return _PreviewTarget(e.path, true);
            } else if (e is Directory) {
              next.add(e);
            }
          }
        } catch (_) {
          continue;
        }
      }

      for (final d in cur) {
        if (files >= maxFiles) break;
        try {
          await for (final e in d.list(followLinks: false)) {
            if (files >= maxFiles) break;
            if (e is File) {
              files++;
              if (isPageVideoPath(e.path)) return _PreviewTarget(e.path, false);
            }
          }
        } catch (_) {
          continue;
        }
      }

      cur = next;
      depth++;
      await Future<void>.delayed(Duration.zero);
    }

    return null;
  }
}
