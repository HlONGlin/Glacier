import 'dart:collection';
import 'dart:convert';

class ImageRatioCache {
  static final LinkedHashMap<String, double> _cache =
      LinkedHashMap<String, double>();
  static const int _cap = 800;

  static String exportJson({int maxEntries = 400}) {
    if (_cache.isEmpty || maxEntries <= 0) return '';
    final entries = _cache.entries.toList();
    final start = entries.length > maxEntries ? entries.length - maxEntries : 0;
    final map = <String, double>{};
    for (final entry in entries.sublist(start)) {
      final value = entry.value;
      if (value > 0 && value.isFinite) {
        map[entry.key] = value;
      }
    }
    if (map.isEmpty) return '';
    return jsonEncode(map);
  }

  static void restoreFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        final value = entry.value;
        final ratio =
            value is num ? value.toDouble() : double.tryParse('$value');
        if (ratio == null || ratio <= 0 || !ratio.isFinite) continue;
        _cache.remove(key);
        _cache[key] = ratio;
      }
      _trim();
    } catch (_) {}
  }

  static void remember(String key, double ratio) {
    if (key.trim().isEmpty || ratio <= 0 || !ratio.isFinite) return;
    _cache.remove(key);
    _cache[key] = ratio;
    _trim();
  }

  static double? lookup(String key) {
    final ratio = _cache[key.trim()];
    if (ratio == null || ratio <= 0 || !ratio.isFinite) return null;
    return ratio;
  }

  static void _trim() {
    while (_cache.length > _cap) {
      _cache.remove(_cache.keys.first);
    }
  }
}
