class WebDavSourceRef {
  final String accountId;
  final String relPath;
  final bool isDir;

  const WebDavSourceRef({
    required this.accountId,
    required this.relPath,
    this.isDir = false,
  });
}

class EmbySourceRef {
  final String accountId;
  final String itemId;

  const EmbySourceRef({required this.accountId, required this.itemId});
}

class EmbyStreamSourceInfo {
  final String itemId;

  const EmbyStreamSourceInfo({required this.itemId});
}

class EmbyPathSourceRef {
  final String accountId;
  final String path;

  const EmbyPathSourceRef({required this.accountId, required this.path});
}

bool isWebDavSource(String source) {
  try {
    final u = Uri.parse(source);
    return u.scheme.toLowerCase() == 'webdav' && u.host.isNotEmpty;
  } catch (_) {
    return false;
  }
}

bool isEmbySource(String source) {
  try {
    final u = Uri.parse(source);
    return u.scheme.toLowerCase() == 'emby' && u.host.isNotEmpty;
  } catch (_) {
    return false;
  }
}

String buildWebDavSource(String accountId, String relPath) {
  final normalized = encodePathPreserveSlash(relPath);
  return 'webdav://$accountId/$normalized';
}

String buildEmbySource(String accountId, String path, {String? name}) {
  final host = accountId.trim();
  var normalizedPath = path.trim();
  if (normalizedPath.startsWith('/')) {
    normalizedPath = normalizedPath.substring(1);
  }
  final base = 'emby://$host/$normalizedPath';
  final n = (name ?? '').trim();
  if (n.isEmpty) return base;
  return '$base?name=${Uri.encodeComponent(n)}';
}

String decodeMaybeTwice(String s) {
  var out = s;
  for (var i = 0; i < 2; i++) {
    try {
      final decoded = Uri.decodeFull(out);
      if (decoded == out) break;
      out = decoded;
    } catch (_) {
      break;
    }
  }
  return out;
}

String encodePathPreserveSlash(String relPath) {
  var value = relPath.trim();
  if (value.startsWith('/')) value = value.substring(1);
  if (value.isEmpty) return '';
  final endsWithSlash = value.endsWith('/');
  final encoded = value
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
  if (encoded.isEmpty) return '';
  return endsWithSlash ? '$encoded/' : encoded;
}

WebDavSourceRef? parseWebDavSource(String source) {
  try {
    final safe = source.replaceAllMapped(
      RegExp(r'%(?![0-9A-Fa-f]{2})'),
      (_) => '%25',
    );
    final u = Uri.parse(safe);
    if (u.scheme.toLowerCase() != 'webdav' || u.host.isEmpty) return null;
    var rel = u.path.startsWith('/') ? u.path.substring(1) : u.path;
    rel = decodeMaybeTwice(rel).trim();
    return WebDavSourceRef(
      accountId: u.host.trim(),
      relPath: rel,
      isDir: source.trim().endsWith('/') || rel.isEmpty,
    );
  } catch (_) {
    return null;
  }
}

EmbySourceRef? parseEmbySourceRef(String source) {
  try {
    final u = Uri.parse(source);
    if (u.scheme.toLowerCase() != 'emby' || u.host.isEmpty) return null;
    final m = RegExp(r'item:([^/]+)').firstMatch(u.path);
    final itemId = (m?.group(1) ?? '').trim();
    if (itemId.isEmpty) return null;
    return EmbySourceRef(accountId: u.host.trim(), itemId: itemId);
  } catch (_) {
    return null;
  }
}

EmbyPathSourceRef? parseEmbySourcePath(String source) {
  try {
    final u = Uri.parse(source);
    if (u.scheme.toLowerCase() != 'emby' || u.host.isEmpty) return null;
    final segs = u.pathSegments.where((x) => x.isNotEmpty).toList();
    final path = segs.isEmpty ? 'favorites' : segs.join('/');
    return EmbyPathSourceRef(accountId: u.host.trim(), path: path);
  } catch (_) {
    return null;
  }
}

EmbyStreamSourceInfo? parseEmbyStreamInfo(String source) {
  try {
    final u = Uri.parse(source);
    final segs = u.pathSegments;
    final i = segs.indexWhere((s) => s.toLowerCase() == 'videos');
    if (i < 0 || i + 2 >= segs.length) return null;
    final itemId = segs[i + 1].trim();
    final tail = segs[i + 2].toLowerCase();
    if (itemId.isEmpty || !tail.startsWith('stream')) return null;
    return EmbyStreamSourceInfo(itemId: itemId);
  } catch (_) {
    return null;
  }
}
