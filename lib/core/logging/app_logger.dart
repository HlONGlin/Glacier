import 'package:flutter/foundation.dart';

import '../utils/redaction.dart';

class AppLogger {
  AppLogger._();

  static void info(String message, {String? tag}) {
    _log('INFO', message, tag: tag);
  }

  static void warning(String message, {String? tag}) {
    _log('WARN', message, tag: tag);
  }

  static void error(String message,
      {Object? error, StackTrace? stackTrace, String? tag}) {
    final buffer = StringBuffer(message);
    if (error != null) {
      buffer.write(' | error=');
      buffer.write(redactSensitiveText(error.toString()));
    }
    if (stackTrace != null) {
      final firstLine = stackTrace.toString().split('\n').first.trim();
      if (firstLine.isNotEmpty) {
        buffer.write(' | stack=');
        buffer.write(redactSensitiveText(firstLine));
      }
    }
    _log('ERROR', buffer.toString(), tag: tag);
  }

  static void _log(String level, String message, {String? tag}) {
    final clean = redactSensitiveText(message);
    final prefix = tag == null || tag.trim().isEmpty
        ? '[Glacier][$level]'
        : '[Glacier][$level][${tag.trim()}]';
    debugPrint('$prefix $clean');
  }
}
