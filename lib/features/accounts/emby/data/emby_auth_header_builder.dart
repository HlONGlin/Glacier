class EmbyAuthHeaderBuilder {
  EmbyAuthHeaderBuilder._();

  static Map<String, String> buildTokenHeaders(String apiKey) {
    final token = apiKey.trim();
    if (token.isEmpty) return const <String, String>{};
    return <String, String>{'X-Emby-Token': token};
  }

  static String buildAuthorization({
    String client = 'FlutterClient',
    String device = 'Android',
    required String deviceId,
    String version = '1.0.0',
  }) {
    return 'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version"';
  }
}
