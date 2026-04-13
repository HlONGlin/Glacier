import 'emby.dart';
import 'features/accounts/webdav/data/webdav_auth_header_builder.dart';
import 'webdav.dart';

Future<Map<String, WebDavAccount>> loadWebDavAccountsMapShared() async {
  if (!WebDavManager.instance.isLoaded) {
    await WebDavManager.instance.reload(notify: false);
  }
  return WebDavManager.instance.accountsMap;
}

Future<Map<String, Map<String, String>>>
    loadWebDavAccountAuthMapShared() async {
  final map = await loadWebDavAccountsMapShared();
  return {
    for (final entry in map.entries)
      entry.key: <String, String>{
        'baseUrl': entry.value.baseUrl,
        'username': entry.value.username,
        'password': entry.value.password,
        'authorization': WebDavAuthHeaderBuilder.buildAuthorization(
          username: entry.value.username,
          password: entry.value.password,
        ),
      },
  };
}

Future<Map<String, dynamic>?> loadWebDavAccountJsonShared(
    String accountId) async {
  final map = await loadWebDavAccountsMapShared();
  final account = map[accountId];
  if (account == null) return null;
  return account.toJson();
}

Future<Map<String, EmbyAccount>> loadEmbyAccountsMapShared() async {
  final list = await EmbyStore.load();
  return {
    for (final account in list)
      if (account.id.trim().isNotEmpty) account.id.trim(): account,
  };
}
