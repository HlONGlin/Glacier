import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

// Keeps legacy in-memory fields populated while persistence is already secret-safe.
import 'emby_account_model.dart';
import 'emby_secret_store.dart';

class EmbyStore {
  static const _k = 'emby_accounts_v3';

  static bool _isGuid(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final r1 = RegExp(r'^[0-9a-fA-F]{32}$');
    final r2 = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return r1.hasMatch(t) || r2.hasMatch(t);
  }

  static Future<List<EmbyAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k) ??
        prefs.getString('emby_accounts_v2') ??
        prefs.getString('emby_accounts_v1');

    if (raw == null || raw.trim().isEmpty) return [];

    try {
      final list = jsonDecode(raw);
      if (list is List) {
        final accs = list
            .whereType<Map>()
            .map((m) => EmbyAccount.fromJson(m.cast<String, dynamic>()))
            .toList();

        var mutated = false;
        var migratedSecrets = false;
        for (final a in accs) {
          if (a.username.trim().isEmpty &&
              a.userId.trim().isNotEmpty &&
              !_isGuid(a.userId)) {
            a.username = a.userId.trim();
            a.userId = '';
            a.apiKey = '';
            mutated = true;
          }
          if (a.userId.trim().isNotEmpty && !_isGuid(a.userId)) {
            a.userId = '';
            a.apiKey = '';
            mutated = true;
          }

          final legacyPassword = a.password.trim();
          final legacyApiKey = a.apiKey.trim();
          final stored = await EmbySecretStore.read(a.id);
          final mergedPassword = legacyPassword.isNotEmpty
              ? legacyPassword
              : (stored['password'] ?? '');
          final mergedApiKey =
              legacyApiKey.isNotEmpty ? legacyApiKey : (stored['apiKey'] ?? '');
          a.password = mergedPassword;
          a.apiKey = mergedApiKey;
          if (legacyPassword.isNotEmpty || legacyApiKey.isNotEmpty) {
            migratedSecrets = true;
          }
        }

        if (mutated || migratedSecrets) {
          await save(accs);
        }
        return accs;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> save(List<EmbyAccount> list) async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = <String, Map<String, String>>{
      for (final account in list)
        if (account.id.trim().isNotEmpty)
          account.id.trim(): <String, String>{
            'password': account.password,
            'apiKey': account.apiKey,
          },
    };
    await EmbySecretStore.sync(secrets);
    await prefs.setString(
      _k,
      jsonEncode(list.map((e) => e.toStorageJson()).toList()),
    );
  }

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('emby_device_id');
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();

    final r = Random();
    final id =
        'android-${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 32)}';
    await prefs.setString('emby_device_id', id);
    return id;
  }
}
