import '../../../../secure_store.dart';

class WebDavSecretStore {
  WebDavSecretStore._();

  static Future<Map<String, String>> read(String id) {
    return AccountSecretStore.readWebDav(id);
  }

  static Future<void> sync(Map<String, Map<String, String>> byId) {
    return AccountSecretStore.syncWebDav(byId);
  }
}
