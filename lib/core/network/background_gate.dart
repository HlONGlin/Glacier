import 'dart:async';
import 'dart:io';

import 'http_client_factory.dart';

class WebDavPausedException implements IOException {
  final String message;
  WebDavPausedException(this.message);

  @override
  String toString() => message;
}

class AsyncSemaphore {
  AsyncSemaphore(this._maxPermits);

  final int _maxPermits;
  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  void cancelWaiters(Object error) {
    final waiters = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  Future<void> _acquire() {
    if (_active < _maxPermits) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future.then((_) {
      _active++;
    });
  }

  void _release() {
    if (_active > 0) _active--;
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
  }
}

final AsyncSemaphore webDavBgSemaphore = AsyncSemaphore(2);
final AsyncSemaphore webDavUiSemaphore = AsyncSemaphore(4);

class WebDavBackgroundHttpPool {
  WebDavBackgroundHttpPool._();
  static final WebDavBackgroundHttpPool instance = WebDavBackgroundHttpPool._();

  HttpClient? _client;
  int _generation = 0;

  int get generation => _generation;

  HttpClient get client {
    final existing = _client;
    if (existing != null) return existing;
    final created = HttpClientFactory.createBackground(
      connectionTimeout: const Duration(seconds: 15),
      idleTimeout: const Duration(seconds: 10),
      maxConnectionsPerHost: 2,
    );
    _client = created;
    return created;
  }

  void abortAll() {
    _generation++;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

class WebDavBackgroundGate {
  static int _pauseDepth = 0;
  static Completer<void>? _resumeCompleter;
  static int _pauseToken = 0;

  static bool get isPaused => _pauseDepth > 0;
  static int get pauseToken => _pauseToken;

  static void pause() {
    _pauseDepth++;
    _pauseToken++;
    _resumeCompleter ??= Completer<void>();
  }

  static void pauseHard() {
    pause();
    WebDavBackgroundHttpPool.instance.abortAll();
    webDavBgSemaphore.cancelWaiters(
      WebDavPausedException('background tasks aborted by playback'),
    );
  }

  static void resume() {
    if (_pauseDepth <= 0) return;
    _pauseDepth--;
    if (_pauseDepth == 0 &&
        _resumeCompleter != null &&
        !_resumeCompleter!.isCompleted) {
      _resumeCompleter!.complete();
      _resumeCompleter = null;
    }
  }

  static Future<void> waitIfPaused() async {
    if (_pauseDepth == 0) return;
    final completer = _resumeCompleter;
    if (completer != null) await completer.future;
  }
}
