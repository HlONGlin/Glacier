import 'dart:async';
import 'dart:io';

import '../logging/app_logger.dart';
import '../utils/redaction.dart';

class NetworkRunner {
  NetworkRunner._();

  static const Duration defaultConnectTimeout = Duration(seconds: 15);
  static const Duration defaultReadTimeout = Duration(seconds: 20);

  static Future<T> run<T>(
    Future<T> Function() action, {
    String? label,
    Duration? timeout,
    int retries = 0,
  }) async {
    final effectiveTimeout = timeout ?? defaultReadTimeout;
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await action().timeout(effectiveTimeout);
      } on TimeoutException catch (error, stackTrace) {
        lastError = TimeoutException(
          'Network timeout${label == null ? '' : ' ($label)'} after ${effectiveTimeout.inSeconds}s',
        );
        lastStackTrace = stackTrace;
      } on SocketException catch (error, stackTrace) {
        lastError = HttpException(redactSensitiveText(error.message));
        lastStackTrace = stackTrace;
      } on HttpException catch (error, stackTrace) {
        lastError =
            HttpException(redactSensitiveText(error.message), uri: error.uri);
        lastStackTrace = stackTrace;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }

      final shouldRetry = attempt < retries;
      AppLogger.warning(
        shouldRetry
            ? 'network attempt ${attempt + 1} failed, retrying${label == null ? '' : ' ($label)'}'
            : 'network request failed${label == null ? '' : ' ($label)'}',
        tag: 'network',
      );
      if (!shouldRetry) break;
    }

    if (lastError is Error) {
      throw lastError;
    }
    Error.throwWithStackTrace(
      lastError ?? StateError('unknown network error'),
      lastStackTrace ?? StackTrace.current,
    );
  }
}
