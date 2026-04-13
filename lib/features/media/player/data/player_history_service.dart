import 'package:collection/collection.dart';

import '../../../../emby.dart';
import '../../../../sources/refs.dart';
import '../../../../core/utils/app_shared.dart';
import 'play_source_resolver.dart';

class PlayerHistoryService {
  PlayerHistoryService._();

  static Future<String> resolveHistoryTitle(
    String path, {
    Map<String, EmbyAccount>? embyAccounts,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return '未知视频';

    var title = PlayerSourceResolver.displayName(normalizedPath).trim();
    if (title.isEmpty) title = '未知视频';
    if (title != 'Emby 媒体' || !isEmbySource(normalizedPath)) {
      return title;
    }

    try {
      final ref = parseEmbySourceRef(normalizedPath);
      final accId = ref?.accountId.trim() ?? '';
      final itemId = ref?.itemId.trim() ?? '';
      if (accId.isEmpty || itemId.isEmpty) return title;

      final accounts =
          embyAccounts ?? await PlayerSourceResolver.loadEmbyAccountMap();
      final account = accounts[accId];
      if (account == null) return title;

      final remoteTitle = await EmbyClient(account).getItemName(itemId);
      if (remoteTitle != null && remoteTitle.trim().isNotEmpty) {
        return remoteTitle.trim();
      }
    } catch (_) {}
    return title;
  }

  static Future<void> upsertMediaHistory(
    String path, {
    int? positionMs,
    Map<String, EmbyAccount>? embyAccounts,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return;
    final title = await resolveHistoryTitle(
      normalizedPath,
      embyAccounts: embyAccounts,
    );
    await AppHistory.upsert(
      path: normalizedPath,
      title: title,
      positionMs: positionMs,
    );
  }

  static Future<void> updateHistoryProgress(
    String path, {
    required int positionMs,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return;
    await AppHistory.updateProgress(
      path: normalizedPath,
      positionMs: positionMs,
    );
  }

  static Future<int?> loadResumePositionMs(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return null;
    if (!await AppSettings.getHistoryEnabled()) return null;

    try {
      final list = await AppHistory.load();
      final hit = list.firstWhereOrNull(
        (entry) => (entry['path'] ?? '').toString().trim() == normalizedPath,
      );
      if (hit == null) return null;
      final raw = hit['pos'];
      final ms = (raw is int) ? raw : int.tryParse('$raw');
      if (ms == null || ms <= 0) return null;
      return ms;
    } catch (_) {
      return null;
    }
  }
}
