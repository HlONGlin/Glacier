import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/redaction.dart';

class AppLogger {
  AppLogger._();

  static const int _maxLogBytes = 2 * 1024 * 1024;
  static Future<void> _writeQueue = Future<void>.value();
  static Future<File>? _logFileFuture;

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
    final line = '${DateTime.now().toIso8601String()} $prefix $clean';
    debugPrint(line);
    _writeQueue = _writeQueue.then((_) => _append(line)).catchError((_) {});
  }

  static Future<File> _logFile() => _logFileFuture ??= () async {
        final directory = await getApplicationSupportDirectory();
        final logs =
            Directory('${directory.path}${Platform.pathSeparator}logs');
        await logs.create(recursive: true);
        return File('${logs.path}${Platform.pathSeparator}glacier.log');
      }();

  static Future<void> _append(String line) async {
    final file = await _logFile();
    final bytes = await file.exists() ? await file.length() : 0;
    if (bytes >= _maxLogBytes) {
      final content = await file.readAsLines();
      final keepFrom = content.length ~/ 2;
      await file.writeAsString('${content.skip(keepFrom).join('\n')}\n');
    }
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  static Future<String> readLogs() async {
    await _writeQueue;
    final file = await _logFile();
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  static Future<void> clearLogs() async {
    await _writeQueue;
    final file = await _logFile();
    if (await file.exists()) await file.writeAsString('');
  }
}
