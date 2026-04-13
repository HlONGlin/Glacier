import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _memoryFallback = <String, String>{};
  static bool _useMemoryFallback = false;

  static Future<T> _withBackend<T>(
    Future<T> Function() action,
    T Function() fallback,
  ) async {
    if (_useMemoryFallback) return fallback();
    final bindingReady = BindingBase.debugBindingType() != null;
    if (!bindingReady) {
      _useMemoryFallback = true;
      return fallback();
    }
    try {
      return await action();
    } on MissingPluginException {
      _useMemoryFallback = true;
      return fallback();
    } on PlatformException catch (e) {
      if (e.code == 'MissingPluginException') {
        _useMemoryFallback = true;
        return fallback();
      }
      rethrow;
    } on AssertionError {
      _useMemoryFallback = true;
      return fallback();
    }
  }

  static Future<String?> read(String key) {
    return _withBackend<String?>(
      () => _storage.read(key: key),
      () => _memoryFallback[key],
    );
  }

  static Future<void> write(String key, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return delete(key);
    return _withBackend<void>(
      () => _storage.write(key: key, value: trimmed),
      () {
        _memoryFallback[key] = trimmed;
      },
    );
  }

  static Future<void> delete(String key) {
    return _withBackend<void>(
      () => _storage.delete(key: key),
      () {
        _memoryFallback.remove(key);
      },
    );
  }

  @visibleForTesting
  static Future<void> debugResetForTest() async {
    _useMemoryFallback = false;
    _memoryFallback.clear();
  }
}

class AccountSecretStore {
  AccountSecretStore._();

  static const String _prefix = 'glacier.sec';
  static const String _embyNs = 'emby';
  static const String _webDavNs = 'webdav';

  static String _indexKey(String namespace) => '$_prefix.$namespace.ids';
  static String _fieldKey(String namespace, String id, String field) =>
      '$_prefix.$namespace.$id.$field';

  static Future<Set<String>> _readIds(String namespace) async {
    final raw = await SecureStore.read(_indexKey(namespace));
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _writeIds(String namespace, Set<String> ids) async {
    if (ids.isEmpty) {
      await SecureStore.delete(_indexKey(namespace));
      return;
    }
    final sorted = ids.toList()..sort();
    await SecureStore.write(_indexKey(namespace), jsonEncode(sorted));
  }

  static Future<Map<String, String>> _readFields(
    String namespace,
    String id,
    List<String> fields,
  ) async {
    final out = <String, String>{};
    final safeId = id.trim();
    if (safeId.isEmpty) return out;
    for (final field in fields) {
      final value =
          (await SecureStore.read(_fieldKey(namespace, safeId, field)) ?? '')
              .trim();
      if (value.isNotEmpty) out[field] = value;
    }
    return out;
  }

  static Future<void> _syncFields(
    String namespace,
    List<String> fields,
    Map<String, Map<String, String>> byId,
  ) async {
    final keepIds = <String>{};
    for (final entry in byId.entries) {
      final id = entry.key.trim();
      if (id.isEmpty) continue;
      var hasAnySecret = false;
      for (final field in fields) {
        final value = (entry.value[field] ?? '').trim();
        if (value.isEmpty) {
          await SecureStore.delete(_fieldKey(namespace, id, field));
          continue;
        }
        hasAnySecret = true;
        await SecureStore.write(_fieldKey(namespace, id, field), value);
      }
      if (hasAnySecret) keepIds.add(id);
    }

    final previousIds = await _readIds(namespace);
    for (final staleId in previousIds.difference(keepIds)) {
      for (final field in fields) {
        await SecureStore.delete(_fieldKey(namespace, staleId, field));
      }
    }
    await _writeIds(namespace, keepIds);
  }

  static Future<Map<String, String>> readEmby(String id) {
    return _readFields(_embyNs, id, const ['password', 'apiKey']);
  }

  static Future<Map<String, String>> readWebDav(String id) {
    return _readFields(_webDavNs, id, const ['password']);
  }

  static Future<void> syncEmby(Map<String, Map<String, String>> byId) {
    return _syncFields(_embyNs, const ['password', 'apiKey'], byId);
  }

  static Future<void> syncWebDav(Map<String, Map<String, String>> byId) {
    return _syncFields(_webDavNs, const ['password'], byId);
  }

  @visibleForTesting
  static Future<void> debugResetForTest() async {
    final embyIds = await _readIds(_embyNs);
    final webDavIds = await _readIds(_webDavNs);
    for (final id in embyIds) {
      await SecureStore.delete(_fieldKey(_embyNs, id, 'password'));
      await SecureStore.delete(_fieldKey(_embyNs, id, 'apiKey'));
    }
    for (final id in webDavIds) {
      await SecureStore.delete(_fieldKey(_webDavNs, id, 'password'));
    }
    await SecureStore.delete(_indexKey(_embyNs));
    await SecureStore.delete(_indexKey(_webDavNs));
    await SecureStore.debugResetForTest();
  }
}
