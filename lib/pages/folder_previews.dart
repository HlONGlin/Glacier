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

class _PreviewFadeIn extends StatelessWidget {
  final Widget child;

  const _PreviewFadeIn({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: KeyedSubtree(
        key: ValueKey(child.runtimeType),
        child: child,
      ),
    );
  }
}

class _PreviewTarget {
  final String path;
  final bool isImage;
  final bool isNetwork;
  final Map<String, String>? headers;

  const _PreviewTarget(
    this.path,
    this.isImage, {
    this.isNetwork = false,
    this.headers,
  });

  const _PreviewTarget.network(
    String url, {
    required bool isImage,
    Map<String, String>? headers,
  }) : this(
          url,
          isImage,
          isNetwork: true,
          headers: headers,
        );
}

const int _kMaxSharedPreviewFutureEntries = 180;
const int _kMaxSharedPreviewResultEntries = 180;
const int _kMaxSharedPreviewConcurrentJobs = 3;
const int _kMaxSharedWebDavCoverFutureEntries = 120;
const int _kMaxSharedWebDavCoverFileEntries = 120;

final Map<String, Future<_PreviewTarget?>> _sharedPreviewFutureCache = {};
final LinkedHashMap<String, _PreviewTarget?> _sharedPreviewResultCache =
    LinkedHashMap<String, _PreviewTarget?>();
final Queue<_SharedPreviewJob> _sharedPreviewQueue = Queue<_SharedPreviewJob>();

final Map<String, Future<File>> _sharedWebDavCoverFuture = {};
final Map<String, Future<File?>> _sharedWebDavVideoThumbFuture = {};
final LinkedHashMap<String, File> _sharedWebDavCoverFile =
    LinkedHashMap<String, File>();
final LinkedHashMap<String, File> _sharedWebDavVideoThumbFile =
    LinkedHashMap<String, File>();

int _sharedPreviewActiveJobs = 0;

String _previewSourcesCacheKey(List<String> sources) => sources.join('\n');

void _trimSharedFutureCache<T>(Map<String, Future<T>> cache, int maxEntries) {
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

void _trimSharedFileCache(Map<String, File> cache, int maxEntries) {
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

void _rememberSharedPreview(String key, _PreviewTarget? target) {
  _sharedPreviewResultCache.remove(key);
  _sharedPreviewResultCache[key] = target;
  while (_sharedPreviewResultCache.length > _kMaxSharedPreviewResultEntries) {
    _sharedPreviewResultCache.remove(_sharedPreviewResultCache.keys.first);
  }
}

bool _hasSharedResolvedPreview(List<String> sources) =>
    _sharedPreviewResultCache.containsKey(_previewSourcesCacheKey(sources));

_PreviewTarget? _getSharedResolvedPreview(List<String> sources) =>
    _sharedPreviewResultCache[_previewSourcesCacheKey(sources)];

void _pumpSharedPreviewQueue() {
  while (_sharedPreviewActiveJobs < _kMaxSharedPreviewConcurrentJobs &&
      _sharedPreviewQueue.isNotEmpty) {
    final job = _sharedPreviewQueue.removeFirst();
    _sharedPreviewActiveJobs++;
    () async {
      _PreviewTarget? target;
      try {
        target = await job.loader();
      } catch (_) {
        target = null;
      } finally {
        _rememberSharedPreview(job.key, target);
        _sharedPreviewFutureCache.remove(job.key);
        _sharedPreviewActiveJobs--;
        if (!job.completer.isCompleted) {
          job.completer.complete(target);
        }
        _pumpSharedPreviewQueue();
      }
    }();
  }
}

Future<_PreviewTarget?> _resolveSharedPreview(
  List<String> sources, {
  bool highPriority = false,
}) {
  final key = _previewSourcesCacheKey(sources);
  if (_sharedPreviewResultCache.containsKey(key)) {
    return Future<_PreviewTarget?>.value(_sharedPreviewResultCache[key]);
  }

  final existing = _sharedPreviewFutureCache[key];
  if (existing != null) return existing;

  if (highPriority && _sharedPreviewQueue.isNotEmpty) {
    _sharedPreviewQueue.removeWhere((job) => !job.highPriority);
  }

  final completer = Completer<_PreviewTarget?>();
  _sharedPreviewFutureCache[key] = completer.future;
  _trimSharedFutureCache(
    _sharedPreviewFutureCache,
    _kMaxSharedPreviewFutureEntries,
  );
  final job = _SharedPreviewJob(
    key: key,
    completer: completer,
    loader: () => _loadPreviewTargetFromSources(sources),
    highPriority: highPriority,
  );
  if (highPriority) {
    _sharedPreviewQueue.addFirst(job);
  } else {
    _sharedPreviewQueue.addLast(job);
  }
  _pumpSharedPreviewQueue();
  return completer.future;
}

Future<_PreviewTarget?> _loadPreviewTargetFromSources(
    List<String> sources) async {
  for (final s in sources) {
    if (isPageEmbySource(s)) {
      final target = await _pickPreviewTargetFromEmbySource(s);
      if (target != null) return target;
      continue;
    }

    if (isPageWebDavSource(s)) {
      final target = await _pickPreviewTargetFromWebDavSource(s);
      if (target != null) return target;
      continue;
    }

    final target = await _pickPreviewTargetFromFolder(s);
    if (target != null) return target;
  }
  return null;
}

Future<_PreviewTarget?> _pickPreviewTargetFromEmbySource(String source) async {
  final ref = parsePageEmbySource(source);
  if (ref == null) return null;

  final accountMap = await loadPageEmbyAccountsMapShared();
  final account = accountMap[ref.accountId];
  if (account == null) return null;

  final client = EmbyClient(account);
  final path = ref.path.trim();
  if (path.isEmpty || path == 'favorites') {
    try {
      final views = await client.listViews();
      for (final item in views) {
        final target = await _embyPreviewTargetForItem(client, item.id);
        if (target != null) return target;
      }
    } catch (_) {}

    try {
      final items = await client.listFavorites();
      for (final item in items) {
        if (item.id.trim().isEmpty) continue;
        if (item.isFolder) {
          final target = await _embyPreviewTargetForItem(client, item.id);
          if (target != null) return target;
          continue;
        }
        final url =
            client.bestCoverUrl(item, maxWidth: 1400, quality: 95).trim();
        if (url.isNotEmpty) {
          return _PreviewTarget.network(
            url,
            isImage: true,
            headers: client.imageHeaders(),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  final colon = path.indexOf(':');
  final itemId = colon >= 0 ? path.substring(colon + 1).trim() : path.trim();
  if (itemId.isEmpty) return null;
  return _embyPreviewTargetForItem(client, itemId);
}

Future<_PreviewTarget?> _embyPreviewTargetForItem(
  EmbyClient client,
  String itemId,
) async {
  try {
    final item = await client.getItemById(itemId);
    if (item == null || item.id.trim().isEmpty) return null;

    if (item.isFolder) {
      final folderUrl = await client.pickAutoFolderCoverUrl(
        folderId: item.id,
        maxWidth: 1400,
        quality: 95,
        fallbackToVideo: true,
      );
      final resolved = (folderUrl ?? '').trim();
      if (resolved.isNotEmpty) {
        return _PreviewTarget.network(
          resolved,
          isImage: true,
          headers: client.imageHeaders(),
        );
      }
    }

    final url = _embyBestPreviewUrl(client, item).trim();
    if (url.isEmpty) return null;
    return _PreviewTarget.network(
      url,
      isImage: true,
      headers: client.imageHeaders(),
    );
  } catch (_) {
    return null;
  }
}

String _embyBestPreviewUrl(EmbyClient client, EmbyItem item) {
  if (_embyTypeLooksImage(item)) {
    final image = client.bestImageUrl(item).trim();
    if (image.isNotEmpty) return image;
  }
  return client.bestCoverUrl(item, maxWidth: 1400, quality: 95).trim();
}

bool _embyTypeLooksImage(EmbyItem item) {
  final type = item.type.trim().toLowerCase();
  final mediaType = (item.mediaType ?? '').trim().toLowerCase();
  return mediaType == 'photo' ||
      mediaType == 'image' ||
      type == 'photo' ||
      type == 'image' ||
      type == 'picture' ||
      type == 'photobubble';
}

Future<_PreviewTarget?> _pickPreviewTargetFromWebDavSource(
    String source) async {
  final ref = parsePageWebDavSource(source);
  if (ref == null || !ref.isDir) return null;

  final accMap = await loadPageWebDavAccountsMapShared();
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

      final name = item.name.toLowerCase();
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
      buildPageWebDavSource(ref.accountId, firstImage.relPath, isDir: false),
      true,
    );
  }
  if (firstVideo != null) {
    return _PreviewTarget(
      buildPageWebDavSource(ref.accountId, firstVideo.relPath, isDir: false),
      false,
    );
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
              buildPageWebDavSource(ref.accountId, item.relPath, isDir: false),
              true,
            );
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
          false,
        );
      }

      cur = next;
      depth++;
      await Future<void>.delayed(Duration.zero);
    }
  } catch (_) {}

  return null;
}

Future<_PreviewTarget?> _pickPreviewTargetFromFolder(String folder) async {
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

class _SharedPreviewJob {
  final String key;
  final Completer<_PreviewTarget?> completer;
  final Future<_PreviewTarget?> Function() loader;
  final bool highPriority;

  const _SharedPreviewJob({
    required this.key,
    required this.completer,
    required this.loader,
    this.highPriority = false,
  });
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
  Future<_PreviewTarget?>? _future;
  Future<Map<String, WebDavAccount>>? _accFuture;

  @override
  void initState() {
    super.initState();
    _future = _resolveSharedPreview(widget.sources, highPriority: true);
    _accFuture = loadPageWebDavAccountsMapShared();
  }

  @override
  void didUpdateWidget(covariant _MultiSourcePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSources(oldWidget.sources, widget.sources)) {
      _future = _resolveSharedPreview(widget.sources, highPriority: true);
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

    if (_hasSharedResolvedPreview(widget.sources)) {
      return _buildTarget(_getSharedResolvedPreview(widget.sources));
    }

    return FutureBuilder<_PreviewTarget?>(
      future: _future,
      builder: (_, s) {
        return _buildTarget(s.data);
      },
    );
  }

  Widget _buildTarget(_PreviewTarget? t) {
    if (t == null) return const _CoverPlaceholder();

    if (t.isNetwork) {
      return _PreviewFadeIn(
        child: CachedNetworkImage(
          imageUrl: t.path,
          httpHeaders: t.headers,
          fit: BoxFit.cover,
          memCacheWidth: 1400,
          maxWidthDiskCache: 1800,
          fadeInDuration: const Duration(milliseconds: 160),
          fadeOutDuration: const Duration(milliseconds: 80),
          placeholder: (_, __) => const _CoverPlaceholder(),
          errorWidget: (_, __, ___) => const _CoverPlaceholder(),
        ),
      );
    }

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

            final client = WebDavManager.instance.getClient(ref.accountId) ??
                WebDavClient(acc);
            final href = client.resolveRel(ref.relPath).toString();

            if (t.isImage) {
              final cached = _sharedWebDavCoverFile[href];
              if (cached != null && cached.existsSync()) {
                return _PreviewFadeIn(
                  child: _ProportionalPreviewBox(
                    child: Image.file(
                      cached,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: (_, child, frame, wasSyncLoaded) {
                        return AnimatedOpacity(
                          opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          child: child,
                        );
                      },
                      errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
                    ),
                  ),
                );
              }
              final coverFuture = _sharedWebDavCoverFuture.putIfAbsent(
                href,
                () => client
                    .ensureCoverCached(href, p.basename(ref.relPath))
                    .then(
                  (f) {
                    _sharedWebDavCoverFile[href] = f;
                    _trimSharedFileCache(
                      _sharedWebDavCoverFile,
                      _kMaxSharedWebDavCoverFileEntries,
                    );
                    return f;
                  },
                ),
              );
              _trimSharedFutureCache(
                _sharedWebDavCoverFuture,
                _kMaxSharedWebDavCoverFutureEntries,
              );
              return FutureBuilder<File>(
                future: coverFuture,
                builder: (_, snap) {
                  final f = snap.data;
                  if (f != null && f.existsSync()) {
                    return _PreviewFadeIn(
                      child: _ProportionalPreviewBox(
                        child: Image.file(
                          f,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          frameBuilder: (_, child, frame, wasSyncLoaded) {
                            return AnimatedOpacity(
                              opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOutCubic,
                              child: child,
                            );
                          },
                          errorBuilder: (_, __, ___) =>
                              const _CoverPlaceholder(),
                        ),
                      ),
                    );
                  }
                  return const _CoverPlaceholder();
                },
              );
            }

            final cachedV = _sharedWebDavVideoThumbFile[href];
            if (cachedV != null &&
                cachedV.existsSync() &&
                cachedV.lengthSync() > 0) {
              return _PreviewFadeIn(
                child: _ProportionalPreviewBox(
                  child: Image.file(
                    cachedV,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    frameBuilder: (_, child, frame, wasSyncLoaded) {
                      return AnimatedOpacity(
                        opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOutCubic,
                        child: child,
                      );
                    },
                    errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                  ),
                ),
              );
            }
            final vFuture = _sharedWebDavVideoThumbFuture.putIfAbsent(
              href,
              () => getPageWebDavVideoThumbFile(
                client,
                href,
                p.basename(ref.relPath),
                maxBytes: 12 * 1024 * 1024,
              ).then((f) {
                if (f != null) _sharedWebDavVideoThumbFile[href] = f;
                _trimSharedFileCache(
                  _sharedWebDavVideoThumbFile,
                  _kMaxSharedWebDavCoverFileEntries,
                );
                return f;
              }),
            );
            _trimSharedFutureCache(
              _sharedWebDavVideoThumbFuture,
              _kMaxSharedWebDavCoverFutureEntries,
            );
            return FutureBuilder<File?>(
              future: vFuture,
              builder: (_, snap) {
                final f = snap.data;
                if (f != null && f.existsSync() && f.lengthSync() > 0) {
                  return _PreviewFadeIn(
                    child: _ProportionalPreviewBox(
                      child: Image.file(
                        f,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        frameBuilder: (_, child, frame, wasSyncLoaded) {
                          return AnimatedOpacity(
                            opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOutCubic,
                            child: child,
                          );
                        },
                        errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                      ),
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
        ? _PreviewFadeIn(
            child: _ProportionalPreviewBox(
              child: Image.file(
                File(t.path),
                gaplessPlayback: true,
                frameBuilder: (_, child, frame, wasSyncLoaded) {
                  return AnimatedOpacity(
                    opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    child: child,
                  );
                },
                errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
              ),
            ),
          )
        : FutureBuilder<File?>(
            future: ThumbCache.getOrCreateVideoPreviewFrame(
              t.path,
              Duration.zero,
            ),
            builder: (_, snap) {
              final f = snap.data;
              if (f != null && f.existsSync() && f.lengthSync() > 0) {
                return _PreviewFadeIn(
                  child: _ProportionalPreviewBox(
                    child: Image.file(
                      f,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: (_, child, frame, wasSyncLoaded) {
                        return AnimatedOpacity(
                          opacity: frame == null && !wasSyncLoaded ? 0 : 1,
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          child: child,
                        );
                      },
                      errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
                    ),
                  ),
                );
              }
              return const _VideoPlaceholder();
            },
          );
  }
}
