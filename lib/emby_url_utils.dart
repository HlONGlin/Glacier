String preferOriginalEmbyUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  try {
    final u = Uri.parse(raw);
    final qp = Map<String, String>.from(u.queryParameters);
    qp.removeWhere((k, _) {
      final lk = k.toLowerCase();
      return lk == 'maxwidth' || lk == 'maxheight' || lk == 'quality';
    });
    final out =
        qp.isEmpty ? u.replace(query: '') : u.replace(queryParameters: qp);
    return out.toString();
  } catch (_) {
    return raw;
  }
}
