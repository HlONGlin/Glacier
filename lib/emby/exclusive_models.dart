import '../emby.dart';
import 'read_scheme.dart';

class EmbyExclusiveUiItem {
  final EmbyAccount account;
  final EmbyItem item;
  final bool isDir;
  final bool isImage;
  final String coverUrl;

  const EmbyExclusiveUiItem({
    required this.account,
    required this.item,
    required this.isDir,
    required this.isImage,
    required this.coverUrl,
  });

  String get title => item.name.trim().isEmpty ? '未命名' : item.name.trim();
}

class EmbyExclusiveSection {
  final EmbyAccount account;
  final EmbyItem view;
  final List<EmbyExclusiveUiItem> items;

  const EmbyExclusiveSection({
    required this.account,
    required this.view,
    required this.items,
  });
}

class EmbyExclusiveFolderPageSeed {
  final List<EmbyExclusiveUiItem> directItems;
  final List<EmbyExclusiveUiItem> recursiveVideos;
  final List<EmbyExclusiveUiItem> recursiveImages;
  final EmbyLibraryKindSignal kindHint;

  const EmbyExclusiveFolderPageSeed({
    this.directItems = const <EmbyExclusiveUiItem>[],
    this.recursiveVideos = const <EmbyExclusiveUiItem>[],
    this.recursiveImages = const <EmbyExclusiveUiItem>[],
    this.kindHint = EmbyLibraryKindSignal.unknown,
  });

  bool get hasAnyData =>
      directItems.isNotEmpty ||
      recursiveVideos.isNotEmpty ||
      recursiveImages.isNotEmpty;
}
