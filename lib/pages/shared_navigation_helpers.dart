part of '../pages.dart';

Route _embyPageRouteNoAnimWithUi() {
  return EmbyPage.routeNoAnim(
    openExclusiveUi: (ctx, {Set<String>? scopedAccountIds}) {
      final scoped = scopedAccountIds
          ?.map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      return Navigator.push(
        ctx,
        MaterialPageRoute(
          builder: (_) => EmbyExclusiveFavoritesPage(
            accountIds: (scoped == null || scoped.isEmpty) ? null : scoped,
            openFolder: (openCtx, {required title, required source}) {
              return openTagSourceAsFolder(openCtx,
                  title: title, source: source);
            },
            openSettings: (openCtx) {
              return Navigator.push(
                openCtx,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> _openEmbyPageWithUi(BuildContext context) async {
  await Navigator.push(context, _embyPageRouteNoAnimWithUi());
}
