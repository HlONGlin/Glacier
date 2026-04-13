part of 'emby_exclusive_ui.dart';

class _EmbyExclusiveFolderPage extends StatefulWidget {
  final EmbyAccount account;
  final String title;
  final String folderId;
  final bool favoritesMode;
  final _FolderPageSeed? initialSeed;
  final _EmbyPaletteMode paletteMode;

  const _EmbyExclusiveFolderPage({
    required this.account,
    required this.title,
    required this.folderId,
    this.favoritesMode = false,
    this.initialSeed,
    required this.paletteMode,
  });

  @override
  State<_EmbyExclusiveFolderPage> createState() =>
      _EmbyExclusiveFolderPageState();
}

typedef _FolderTopTab = EmbyFolderTopTab;
typedef _FolderSortKind = EmbyFolderSortKind;
typedef _LibraryKind = EmbyLibraryKind;
