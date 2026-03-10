import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/source_refs.dart';

void main() {
  group('source refs', () {
    test('parse emby source ref', () {
      final ref = parseEmbySourceRef('emby://acc-1/item:abc123?name=Hello');
      expect(ref, isNotNull);
      expect(ref!.accountId, 'acc-1');
      expect(ref.itemId, 'abc123');
    });

    test('parse emby stream info', () {
      final info = parseEmbyStreamInfo(
        'https://demo.example/emby/Videos/item-9/stream.mp4?api_key=xx',
      );
      expect(info, isNotNull);
      expect(info!.itemId, 'item-9');
    });

    test('build and parse webdav source', () {
      final source =
          buildWebDavSource('wd-1', 'TV Shows/Season 1/Episode 01.mkv');
      expect(isWebDavSource(source), isTrue);
      final ref = parseWebDavSource(source);
      expect(ref, isNotNull);
      expect(ref!.accountId, 'wd-1');
      expect(ref.relPath, 'TV Shows/Season 1/Episode 01.mkv');
      expect(ref.isDir, isFalse);
    });

    test('parse webdav source with bare percent safely', () {
      final ref = parseWebDavSource('webdav://wd-1/TV%Shows/Season%201/');
      expect(ref, isNotNull);
      expect(ref!.accountId, 'wd-1');
      expect(ref.relPath, 'TV%Shows/Season 1/');
      expect(ref.isDir, isTrue);
    });

    test('decode path at most twice for legacy names', () {
      expect(decodeMaybeTwice('A%2520B'), 'A B');
      expect(decodeMaybeTwice('A%20B'), 'A B');
    });

    test('encode path preserve slash', () {
      expect(
        encodePathPreserveSlash('/TV Shows/Season 1/Episode 01.mkv'),
        'TV%20Shows/Season%201/Episode%2001.mkv',
      );
    });

    test('reject invalid sources', () {
      expect(parseEmbySourceRef('https://example.com/video.mp4'), isNull);
      expect(parseWebDavSource('/local/file.mp4'), isNull);
      expect(isEmbySource('emby://acc/item:1'), isTrue);
      expect(isWebDavSource('webdav://acc/folder/file.mp4'), isTrue);
    });
  });
}
