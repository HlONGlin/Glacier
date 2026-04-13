import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glacier/utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppHistory.debugResetForTest();
    debugResetThumbCacheFailures();
  });

  group('CoverCache', () {
    test('cacheNull true caches null hits', () async {
      final cache = CoverCache.instance;
      final key = 'null-hit-${DateTime.now().microsecondsSinceEpoch}';
      var calls = 0;

      final first = await cache.getOrCreate<String?>(
        key,
        () async {
          calls++;
          return null;
        },
        cacheNull: true,
      );
      final second = await cache.getOrCreate<String?>(
        key,
        () async {
          calls++;
          return 'unexpected';
        },
        cacheNull: true,
      );

      expect(first, isNull);
      expect(second, isNull);
      expect(calls, 1);

      cache.invalidate(key);
    });

    test('cacheNull false retries null results', () async {
      final cache = CoverCache.instance;
      final key = 'null-miss-${DateTime.now().microsecondsSinceEpoch}';
      var calls = 0;

      final first = await cache.getOrCreate<String?>(
        key,
        () async {
          calls++;
          return null;
        },
      );
      final second = await cache.getOrCreate<String?>(
        key,
        () async {
          calls++;
          return 'loaded';
        },
      );

      expect(first, isNull);
      expect(second, 'loaded');
      expect(calls, 2);

      cache.invalidate(key);
    });
  });

  group('AppHistoryFolderCtx', () {
    test('constructors preserve expected fields', () {
      const local = AppHistoryFolderCtx.local('C:/media');
      const webdav = AppHistoryFolderCtx.webdav(
        accountId: 'wd-1',
        rel: 'TV/Season 1/',
      );
      const emby = AppHistoryFolderCtx.emby(
        accountId: 'emby-1',
        path: 'view:abc',
      );

      expect(local.kind, 'local');
      expect(local.localDir, 'C:/media');
      expect(webdav.kind, 'webdav');
      expect(webdav.wdAccountId, 'wd-1');
      expect(webdav.wdRel, 'TV/Season 1/');
      expect(emby.kind, 'emby');
      expect(emby.embyAccountId, 'emby-1');
      expect(emby.embyPath, 'view:abc');
    });
  });

  group('AppHistory', () {
    test('upsert de-duplicates path and updates progress from cache', () async {
      await AppHistory.upsert(path: '/video/a.mp4', title: 'A');
      await AppHistory.updateProgress(path: '/video/a.mp4', positionMs: 3210);
      await AppHistory.upsert(path: '/video/a.mp4', title: 'A newer');

      final list = await AppHistory.load();
      expect(list, hasLength(1));
      expect(list.first['title'], 'A newer');
      expect(list.first['pos'], isNull);

      await AppHistory.updateProgress(path: '/video/a.mp4', positionMs: 6543);
      final updated = await AppHistory.load();
      expect(updated.first['pos'], 6543);
    });

    test('clear resets in-memory cache immediately', () async {
      await AppHistory.upsert(path: '/video/b.mp4', title: 'B');
      expect(await AppHistory.load(), hasLength(1));

      await AppHistory.clear();

      expect(await AppHistory.load(), isEmpty);
    });
  });

  group('ThumbCache', () {
    test('remote sources short-circuit without attempting generation',
        () async {
      final f = await ThumbCache.getOrCreateVideoPreviewFrame(
        'webdav://account/video.mp4',
        Duration.zero,
      );
      expect(f, isNull);
    });
  });
}
