import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

// Keeps legacy in-memory fields populated while persistence is already secret-safe.
import 'webdav_account_model.dart';
import 'webdav_secret_store.dart';

class WebDavStore {
  static const _k = 'webdav_accounts_v1';

  static Future<List<WebDavAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        final accounts = list
            .whereType<Map>()
            .map((m) => WebDavAccount.fromJson(m.cast<String, dynamic>()))
            .toList();
        var migratedSecrets = false;
        for (final account in accounts) {
          final legacyPassword = account.password.trim();
          final stored = await WebDavSecretStore.read(account.id);
          account.password = legacyPassword.isNotEmpty
              ? legacyPassword
              : (stored['password'] ?? '');
          if (legacyPassword.isNotEmpty) migratedSecrets = true;
        }
        if (migratedSecrets) {
          await save(accounts);
        }
        return accounts;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> save(List<WebDavAccount> list) async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = <String, Map<String, String>>{
      for (final account in list)
        if (account.id.trim().isNotEmpty)
          account.id.trim(): <String, String>{'password': account.password},
    };
    await WebDavSecretStore.sync(secrets);
    await prefs.setString(
      _k,
      jsonEncode(list.map((e) => e.toStorageJson()).toList()),
    );
  }
}
