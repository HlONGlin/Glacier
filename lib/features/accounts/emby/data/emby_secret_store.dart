import '../../../../core/storage/secure_store.dart';

class EmbySecretStore {
  EmbySecretStore._();

  static Future<Map<String, String>> read(String id) {
    return AccountSecretStore.readEmby(id);
  }

  static Future<void> sync(Map<String, Map<String, String>> byId) {
    return AccountSecretStore.syncEmby(byId);
  }
}
