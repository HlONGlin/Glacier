import '../emby.dart';
import 'exclusive_models.dart';

class EmbyExclusiveStateHelpers {
  EmbyExclusiveStateHelpers._();

  static List<EmbyExclusiveUiItem> replaceItemsForAccount(
    List<EmbyExclusiveUiItem> source,
    String accountId,
    List<EmbyExclusiveUiItem> incoming,
  ) {
    final out = source
        .where((item) => item.account.id != accountId)
        .toList(growable: true);
    out.addAll(incoming);
    return out;
  }

  static List<EmbyExclusiveSection> replaceSectionsForAccount(
    List<EmbyExclusiveSection> source,
    String accountId,
    List<EmbyExclusiveSection> incoming,
  ) {
    final out = source
        .where((section) => section.account.id != accountId)
        .toList(growable: true);
    out.addAll(incoming);
    return out;
  }

  static EmbyAccount? accountById(List<EmbyAccount> accounts, String id) {
    for (final account in accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  static String accountName(List<EmbyAccount> accounts, String id) {
    final account = accountById(accounts, id);
    if (account == null) return 'Emby';
    return account.name.trim().isEmpty ? 'Emby' : account.name.trim();
  }

  static bool matchesSelectedAccount(
      String? selectedAccountId, String accountId) {
    final selected = (selectedAccountId ?? '').trim();
    if (selected.isEmpty) return true;
    return accountId == selected;
  }

  static List<EmbyExclusiveUiItem> scopeItems(
    List<EmbyExclusiveUiItem> source,
    String? selectedAccountId,
  ) {
    final selected = (selectedAccountId ?? '').trim();
    if (selected.isEmpty) return source;
    return source
        .where((item) => item.account.id == selected)
        .toList(growable: false);
  }

  static List<EmbyExclusiveSection> scopeSections(
    List<EmbyExclusiveSection> source,
    String? selectedAccountId,
  ) {
    final selected = (selectedAccountId ?? '').trim();
    if (selected.isEmpty) return source;
    return source
        .where((section) => section.account.id == selected)
        .toList(growable: false);
  }

  static String selectedAccountLabel(
    List<EmbyAccount> accounts,
    String? selectedAccountId,
  ) {
    final selected = (selectedAccountId ?? '').trim();
    if (selected.isEmpty) return 'Emby';
    return accountName(accounts, selected);
  }

  static Map<String, List<EmbyExclusiveUiItem>> groupFavoritesByAccount(
    List<EmbyExclusiveUiItem> favorites,
  ) {
    final grouped = <String, List<EmbyExclusiveUiItem>>{};
    for (final favorite in favorites) {
      grouped
          .putIfAbsent(favorite.account.id, () => <EmbyExclusiveUiItem>[])
          .add(favorite);
    }
    return grouped;
  }
}
