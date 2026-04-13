import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glacier/emby.dart';
import 'package:glacier/secure_store.dart';
import 'package:glacier/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AccountSecretStore.debugResetForTest();
  });

  test('EmbyStore migrates plaintext password and token out of preferences',
      () async {
    SharedPreferences.setMockInitialValues({
      'emby_accounts_v3': jsonEncode([
        {
          'id': 'emby-1',
          'name': 'Emby',
          'serverUrl': 'http://host:8096',
          'username': 'alice',
          'password': 'secret-pass',
          'userId': '12345678-1234-1234-1234-1234567890ab',
          'apiKey': 'secret-token',
        }
      ]),
    });
    await AccountSecretStore.debugResetForTest();

    final list = await EmbyStore.load();
    expect(list, hasLength(1));
    expect(list.first.password, 'secret-pass');
    expect(list.first.apiKey, 'secret-token');

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('emby_accounts_v3')!) as List;
    final first = (stored.first as Map).cast<String, dynamic>();
    expect(first.containsKey('password'), isFalse);
    expect(first.containsKey('apiKey'), isFalse);
    expect(first['userId'], '12345678-1234-1234-1234-1234567890ab');
  });

  test('WebDavStore migrates plaintext password out of preferences', () async {
    SharedPreferences.setMockInitialValues({
      'webdav_accounts_v1': jsonEncode([
        {
          'id': 'wd-1',
          'name': 'WebDAV',
          'baseUrl': 'https://dav.example.com/',
          'username': 'bob',
          'password': 'dav-secret',
        }
      ]),
    });
    await AccountSecretStore.debugResetForTest();

    final list = await WebDavStore.load();
    expect(list, hasLength(1));
    expect(list.first.password, 'dav-secret');

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('webdav_accounts_v1')!) as List;
    final first = (stored.first as Map).cast<String, dynamic>();
    expect(first.containsKey('password'), isFalse);
    expect(first['username'], 'bob');
  });
}
