import '../emby.dart';
import 'native_logic.dart';
import 'url_utils.dart';

final RegExp kMovieMetaTagBracketPattern = RegExp(
  r'\s*\[(?:tmdbid|imdbid|tvdbid|doubanid)[^\]]*\]',
  caseSensitive: false,
);
final RegExp kMultiSpacePattern = RegExp(r'\s{2,}');

bool isAsciiDigitCodeUnit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

int naturalTitleCompare(String a, String b) {
  final sa = a.trim().toLowerCase();
  final sb = b.trim().toLowerCase();
  if (sa == sb) return 0;

  var ia = 0;
  var ib = 0;
  while (ia < sa.length && ib < sb.length) {
    final ca = sa.codeUnitAt(ia);
    final cb = sb.codeUnitAt(ib);
    final da = isAsciiDigitCodeUnit(ca);
    final db = isAsciiDigitCodeUnit(cb);

    if (da && db) {
      final startA = ia;
      final startB = ib;
      while (ia < sa.length && isAsciiDigitCodeUnit(sa.codeUnitAt(ia))) {
        ia++;
      }
      while (ib < sb.length && isAsciiDigitCodeUnit(sb.codeUnitAt(ib))) {
        ib++;
      }

      var nzA = startA;
      var nzB = startB;
      while (nzA < ia - 1 && sa.codeUnitAt(nzA) == 0x30) {
        nzA++;
      }
      while (nzB < ib - 1 && sb.codeUnitAt(nzB) == 0x30) {
        nzB++;
      }

      final lenA = ia - nzA;
      final lenB = ib - nzB;
      if (lenA != lenB) return lenA.compareTo(lenB);

      for (var i = 0; i < lenA; i++) {
        final cmp = sa.codeUnitAt(nzA + i).compareTo(sb.codeUnitAt(nzB + i));
        if (cmp != 0) return cmp;
      }

      final leadingA = nzA - startA;
      final leadingB = nzB - startB;
      if (leadingA != leadingB) return leadingA.compareTo(leadingB);
      continue;
    }

    if (ca != cb) return ca.compareTo(cb);
    ia++;
    ib++;
  }
  return sa.length.compareTo(sb.length);
}

String movieCoverUrlFor(
  EmbyClient client,
  EmbyItem item, {
  int maxWidth = 420,
}) {
  final itemId = item.id.trim();
  if (itemId.isEmpty) return '';

  final preferredWidth = maxWidth < 420 ? 420 : maxWidth;
  final primaryTag = (item.primaryTag ?? '').trim();
  if (primaryTag.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Primary',
      maxWidth: preferredWidth,
      quality: 86,
      tag: primaryTag,
    );
  }

  final thumbTag = (item.thumbTag ?? '').trim();
  if (thumbTag.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Thumb',
      maxWidth: preferredWidth,
      quality: 84,
      tag: thumbTag,
    );
  }

  if (item.backdropTags.isNotEmpty) {
    return client.coverUrl(
      itemId,
      type: 'Backdrop',
      index: 0,
      maxWidth: preferredWidth < 760 ? 760 : preferredWidth,
      quality: 82,
      tag: item.backdropTags.first,
    );
  }

  return client.coverUrl(
    itemId,
    type: 'Primary',
    maxWidth: preferredWidth,
    quality: 84,
  );
}

String coverUrlFor(EmbyClient client, EmbyItem item, {int maxWidth = 420}) {
  if (embyNativeTypeIsMovie(item.type)) {
    final movieCover = movieCoverUrlFor(client, item, maxWidth: maxWidth);
    if (movieCover.trim().isNotEmpty) return movieCover;
  }
  return client.bestCoverUrl(item, maxWidth: maxWidth);
}

String preferOriginalUrl(String url) => preferOriginalEmbyUrl(url);

String cleanMovieFolderTitle(String raw) {
  final stripped = raw.replaceAll(kMovieMetaTagBracketPattern, ' ');
  return stripped.replaceAll(kMultiSpacePattern, ' ').trim();
}
