import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

class SharedImageProviderCacheEntry {
  final ImageProvider provider;
  final int cost;

  const SharedImageProviderCacheEntry({
    required this.provider,
    required this.cost,
  });
}

class SharedImageProviderCache {
  static final LinkedHashMap<String, SharedImageProviderCacheEntry> _cache =
      LinkedHashMap<String, SharedImageProviderCacheEntry>();
  static const int _kCap = 512;
  static const int _kMaxCost = 48 * 1000 * 1000;
  static int _totalCost = 0;
  static int _hitCount = 0;
  static int _missCount = 0;
  static int _evictionCount = 0;

  static int _estimateCost(int width, int height) {
    return max(1, width * height);
  }

  static ImageProvider local(
    String filePath, {
    required int width,
    required int height,
  }) {
    final key = 'file|${filePath.trim()}|$width|$height';
    final hit = _cache.remove(key);
    if (hit != null) {
      _hitCount++;
      _cache[key] = hit;
      return hit.provider;
    }
    _missCount++;
    final provider = ResizeImage(
      FileImage(File(filePath)),
      width: width,
      height: height,
    );
    final entry = SharedImageProviderCacheEntry(
      provider: provider,
      cost: _estimateCost(width, height),
    );
    _cache[key] = entry;
    _totalCost += entry.cost;
    _trim();
    return provider;
  }

  static ImageProvider network(
    String url, {
    Map<String, String>? headers,
    required int width,
    required int height,
  }) {
    final headerKey = headers == null || headers.isEmpty
        ? ''
        : (headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => '${e.key}=${e.value}')
            .join('&');
    final key = 'net|$url|$headerKey|$width|$height';
    final hit = _cache.remove(key);
    if (hit != null) {
      _hitCount++;
      _cache[key] = hit;
      return hit.provider;
    }
    _missCount++;
    final provider = ResizeImage(
      NetworkImage(url, headers: headers),
      width: width,
      height: height,
    );
    final entry = SharedImageProviderCacheEntry(
      provider: provider,
      cost: _estimateCost(width, height),
    );
    _cache[key] = entry;
    _totalCost += entry.cost;
    _trim();
    return provider;
  }

  static void _trim() {
    while (_cache.length > _kCap || _totalCost > _kMaxCost) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) {
        _evictionCount++;
        _totalCost = max(0, _totalCost - removed.cost);
      }
    }
  }

  static Map<String, int> debugSnapshot() {
    return <String, int>{
      'entries': _cache.length,
      'totalCost': _totalCost,
      'hitCount': _hitCount,
      'missCount': _missCount,
      'evictionCount': _evictionCount,
    };
  }
}

class LocalImageThumb extends StatelessWidget {
  final String filePath;
  final int cacheWidth;
  final int cacheHeight;
  final BoxFit fit;

  const LocalImageThumb({
    super.key,
    required this.filePath,
    required this.cacheWidth,
    required this.cacheHeight,
    this.fit = BoxFit.cover,
  });

  ImageProvider _provider() {
    return SharedImageProviderCache.local(
      filePath,
      width: cacheWidth,
      height: cacheHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Image(
        image: _provider(),
        fit: fit,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}
