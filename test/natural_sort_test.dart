import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/pages.dart';

void main() {
  group('compareNaturalText', () {
    test('keeps natural ordering for ordinary numbers', () {
      expect(compareNaturalText('video_2.mp4', 'video_10.mp4'), lessThan(0));
      expect(compareNaturalText('episode12', 'episode2'), greaterThan(0));
    });

    test('handles very long numeric chunks without overflow', () {
      const huge = 'video_123456789012345678901234567890.mp4';
      const small = 'video_9.mp4';

      expect(() => compareNaturalText(huge, small), returnsNormally);
      expect(compareNaturalText(huge, small), greaterThan(0));
    });

    test('stays deterministic when numeric values are equal', () {
      expect(compareNaturalText('file001', 'file1'), greaterThan(0));
      expect(compareNaturalText('file000', 'file0'), greaterThan(0));
    });

    test('continues comparing suffixes after equal numeric chunks', () {
      expect(compareNaturalText('a1b2', 'a01b1'), greaterThan(0));
      expect(compareNaturalText('a01b1', 'a1b2'), lessThan(0));
    });
  });
}
