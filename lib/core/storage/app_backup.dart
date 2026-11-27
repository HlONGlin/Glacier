import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../emby.dart';
import '../../features/accounts/webdav/data/webdav_account_model.dart';
import '../../features/accounts/webdav/data/webdav_store.dart';
import '../../core/utils/app_settings.dart';
import '../../models/favorite_models.dart';
import '../../stores/favorite_store.dart';
import '../../tag.dart';
import '../../tag/tag_store_persistence.dart';

class AppBackup {
  AppBackup._();

  static const _format = 'glacier-backup-v1';
  static const _tagFileName = 'tag_module_store_v2.json';
  static const _pbkdfIterations = 100000;
  static final _cipher = AesGcm.with256bits();

  static Future<String> export({String? credentialPassword}) async {
    final prefs = await SharedPreferences.getInstance();
    final emby = await EmbyStore.load();
    final webdav = await WebDavStore.load();
    final collections = await FavoriteStore.load();
    await TagStore.I.ensureLoaded();
    final tagFile = await TagStorePersistence.storeFile(_tagFileName);
    final tagPayload = await TagStorePersistence.readPayloadFromFile(tagFile);
    final data = <String, dynamic>{
      'preferences': <String, Object>{
        for (final key in prefs.getKeys())
          if (key.startsWith('glacier_settings_')) key: prefs.get(key)!,
      },
      'emby': emby.map((account) => account.toStorageJson()).toList(),
      'webdav': webdav.map((account) => account.toStorageJson()).toList(),
      'favorites': collections.map((item) => item.toJson()).toList(),
      'tags': tagPayload ??
          <String, dynamic>{
            'tags': <dynamic>[],
            'assignments': <String, dynamic>{},
            'targets': <String, dynamic>{},
          },
    };

    if (credentialPassword != null) {
      if (credentialPassword.length < 8) {
        throw const FormatException('备份口令至少需要 8 个字符');
      }
      final secrets = <String, dynamic>{
        'emby': emby.map((account) => account.toJson()).toList(),
        'webdav': webdav.map((account) => account.toJson()).toList(),
      };
      data['credentialBundle'] = await _encrypt(
        utf8.encode(jsonEncode(secrets)),
        credentialPassword,
      );
    }
    return jsonEncode(<String, dynamic>{
      'format': _format,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'data': data,
    });
  }

  static Future<void> restore(String raw, {String? credentialPassword}) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['format'] != _format ||
        decoded['data'] is! Map) {
      throw const FormatException('不支持的 Glacier 备份文件');
    }
    final data = (decoded['data'] as Map).cast<String, dynamic>();
    final embyRaw = _requiredList(data, 'emby');
    final webdavRaw = _requiredList(data, 'webdav');
    final favoriteRaw = _requiredList(data, 'favorites');
    final emby = embyRaw
        .whereType<Map>()
        .map((entry) => EmbyAccount.fromJson(entry.cast<String, dynamic>()))
        .toList();
    final webdav = webdavRaw
        .whereType<Map>()
        .map((entry) => WebDavAccount.fromJson(entry.cast<String, dynamic>()))
        .toList();
    final favorites = favoriteRaw
        .whereType<Map>()
        .map((entry) =>
            FavoriteCollection.fromJson(entry.cast<String, dynamic>()))
        .toList();
    final tags = data['tags'];
    final preferences = data['preferences'];
    if (tags is! Map || preferences is! Map) {
      throw const FormatException('备份文件缺少设置或标签数据');
    }
    final tagPayload = tags.cast<String, dynamic>();
    if (tagPayload['tags'] is! List ||
        tagPayload['assignments'] is! Map ||
        tagPayload['targets'] is! Map) {
      throw const FormatException('备份中的标签数据格式无效');
    }
    for (final entry in preferences.entries) {
      final value = entry.value;
      if (value is! bool &&
          value is! int &&
          value is! double &&
          value is! String &&
          (value is! List || value.any((item) => item is! String))) {
        throw FormatException('备份中的设置值格式无效：${entry.key}');
      }
    }

    Map<String, dynamic>? secrets;
    final encrypted = data['credentialBundle'];
    if (encrypted != null) {
      if (credentialPassword == null || credentialPassword.isEmpty) {
        throw const FormatException('此备份包含加密凭据，需要输入备份口令');
      }
      final decrypted = await _decrypt(encrypted, credentialPassword);
      final secretData = jsonDecode(utf8.decode(decrypted));
      if (secretData is! Map) throw const FormatException('凭据数据格式无效');
      secrets = secretData.cast<String, dynamic>();
    }

    if (secrets != null) {
      final embySecrets =
          _accountSecrets(secrets['emby'], EmbyAccount.fromJson);
      final webdavSecrets =
          _accountSecrets(secrets['webdav'], WebDavAccount.fromJson);
      final byEmbyId = {for (final account in embySecrets) account.id: account};
      final byWebdavId = {
        for (final account in webdavSecrets) account.id: account
      };
      for (final account in emby) {
        final secret = byEmbyId[account.id];
        if (secret != null) {
          account.password = secret.password;
          account.apiKey = secret.apiKey;
        }
      }
      for (final account in webdav) {
        account.password = byWebdavId[account.id]?.password ?? '';
      }
    }

    await EmbyStore.save(emby);
    await WebDavStore.save(webdav);
    await FavoriteStore.save(favorites);
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs
        .getKeys()
        .where((key) => key.startsWith('glacier_settings_'))) {
      await prefs.remove(key);
    }
    for (final entry in preferences.entries) {
      final key = entry.key.toString();
      if (!key.startsWith('glacier_settings_')) continue;
      await _setPreference(prefs, key, entry.value);
    }
    await TagStore.I.importPayload(tagPayload);
    AppSettings.instance.notifyRestored();
  }

  static List<dynamic> _requiredList(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! List) throw FormatException('备份文件缺少 $key 数据');
    return value;
  }

  static List<T> _accountSecrets<T>(
    dynamic raw,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (raw is! List) throw const FormatException('凭据列表格式无效');
    return raw
        .whereType<Map>()
        .map((entry) => fromJson(entry.cast<String, dynamic>()))
        .toList();
  }

  static Future<Map<String, dynamic>> _encrypt(
    List<int> cleartext,
    String password,
  ) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final key = await _deriveKey(password, salt);
    final box = await _cipher.encrypt(cleartext, secretKey: key, nonce: nonce);
    return <String, dynamic>{
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  static Future<List<int>> _decrypt(dynamic raw, String password) async {
    if (raw is! Map) throw const FormatException('加密凭据格式无效');
    final value = raw.cast<String, dynamic>();
    try {
      final salt = base64Decode(value['salt'] as String);
      final nonce = base64Decode(value['nonce'] as String);
      final cipherText = base64Decode(value['cipherText'] as String);
      final mac = base64Decode(value['mac'] as String);
      final key = await _deriveKey(password, salt);
      return await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
    } catch (_) {
      throw const FormatException('备份口令错误或凭据数据损坏');
    }
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: _pbkdfIterations,
        bits: 256,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<void> _setPreference(
    SharedPreferences prefs,
    String key,
    dynamic value,
  ) async {
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.cast<String>());
    } else {
      throw FormatException('不支持的设置值类型：$key');
    }
  }
}
