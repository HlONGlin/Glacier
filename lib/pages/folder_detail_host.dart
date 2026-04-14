part of '../pages.dart';

class _FolderDetailPageHost extends StatefulWidget {
  final FavoriteCollection collection;
  final NavCtx? initialNav;
  final Future<NavCtx?>? deferredInitialNav;
  final bool exitOnInitialContextBack;

  const _FolderDetailPageHost({
    required this.collection,
    required this.initialNav,
    required this.deferredInitialNav,
    required this.exitOnInitialContextBack,
  });

  @override
  State<_FolderDetailPageHost> createState() => _FolderDetailPageState();
}
