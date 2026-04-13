import 'dart:io';

class HttpClientFactory {
  HttpClientFactory._();

  static HttpClient createForeground({
    Duration connectionTimeout = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 45),
    int maxConnectionsPerHost = 12,
  }) {
    final client = HttpClient();
    client.connectionTimeout = connectionTimeout;
    client.idleTimeout = idleTimeout;
    client.maxConnectionsPerHost = maxConnectionsPerHost;
    return client;
  }

  static HttpClient createBackground({
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration idleTimeout = const Duration(seconds: 30),
    int maxConnectionsPerHost = 6,
  }) {
    final client = HttpClient();
    client.connectionTimeout = connectionTimeout;
    client.idleTimeout = idleTimeout;
    client.maxConnectionsPerHost = maxConnectionsPerHost;
    return client;
  }
}
