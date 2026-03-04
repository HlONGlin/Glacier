import 'emby.dart';

String _normType(String raw) => raw.trim().toLowerCase();
String _normMediaType(String? raw) => (raw ?? '').trim().toLowerCase();
String _normCollectionType(String? raw) => (raw ?? '').trim().toLowerCase();

bool embyNativeTypeIsFolder(String type) {
  final t = _normType(type);
  if (t.isEmpty) return false;
  switch (t) {
    case 'folder':
    case 'collectionfolder':
    case 'boxset':
    case 'userview':
    case 'view':
    case 'playlist':
    case 'series':
    case 'season':
    case 'photoalbum':
      return true;
    default:
      return false;
  }
}

bool embyNativeTypeIsImage(String type) {
  final t = _normType(type);
  switch (t) {
    case 'photo':
    case 'image':
    case 'picture':
      return true;
    default:
      return false;
  }
}

bool embyNativeTypeIsMovie(String type) => _normType(type) == 'movie';
bool embyNativeTypeIsEpisode(String type) => _normType(type) == 'episode';
bool embyNativeTypeIsSeries(String type) => _normType(type) == 'series';
bool embyNativeTypeIsSeason(String type) => _normType(type) == 'season';

bool embyNativeItemIsFolder(EmbyItem item) {
  if (item.isFolder) return true;
  if (embyNativeTypeIsMovie(item.type) || embyNativeTypeIsImage(item.type)) {
    return false;
  }
  final mediaType = _normMediaType(item.mediaType);
  if (mediaType == 'video' || mediaType == 'photo' || mediaType == 'image') {
    return false;
  }
  return embyNativeTypeIsFolder(item.type);
}

bool embyNativeItemIsImage(EmbyItem item) {
  if (embyNativeItemIsFolder(item)) return false;
  final mediaType = _normMediaType(item.mediaType);
  if (mediaType == 'photo' || mediaType == 'image') return true;
  return embyNativeTypeIsImage(item.type);
}

bool embyNativeItemIsMovie(EmbyItem item) {
  if (embyNativeItemIsFolder(item)) return false;
  return embyNativeTypeIsMovie(item.type);
}

bool embyNativeItemIsEpisode(EmbyItem item) {
  if (embyNativeItemIsFolder(item)) return false;
  return embyNativeTypeIsEpisode(item.type);
}

bool embyNativeItemIsVideo(EmbyItem item) {
  if (embyNativeItemIsFolder(item) || embyNativeItemIsImage(item)) return false;
  final mediaType = _normMediaType(item.mediaType);
  if (mediaType.isNotEmpty) return mediaType == 'video';

  final t = _normType(item.type);
  switch (t) {
    case 'movie':
    case 'episode':
    case 'video':
    case 'musicvideo':
    case 'trailer':
    case 'tvchannel':
    case 'program':
      return true;
    default:
      return false;
  }
}

bool embyNativeFolderIsSeriesCollection(EmbyItem item) {
  if (!embyNativeItemIsFolder(item)) return false;
  final t = _normType(item.type);
  if (t == 'series' || t == 'season') return true;

  final collection = _normCollectionType(item.collectionType);
  return collection.contains('tv') || collection.contains('series');
}

bool embyNativeFolderIsMovieCollection(EmbyItem item) {
  if (!embyNativeItemIsFolder(item)) return false;
  final t = _normType(item.type);
  if (t == 'boxset') return true;

  final collection = _normCollectionType(item.collectionType);
  if (collection.contains('homevideo')) return false;
  return collection.contains('movie');
}

bool embyNativeCollectionIsHomeVideos(String? collectionType) =>
    _normCollectionType(collectionType).contains('homevideo');

bool embyNativeCollectionIsMovies(String? collectionType) =>
    _normCollectionType(collectionType).contains('movie');

bool embyNativeCollectionIsSeries(String? collectionType) {
  final c = _normCollectionType(collectionType);
  return c.contains('tv') || c.contains('series');
}
