import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tag_models.dart';

class TagStorePersistence {
  TagStorePersistence._();

  static Future<File> storeFile(String fileName) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'tag_store'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  static Future<File> storeTmpFile(String fileName) async {
    final store = await storeFile(fileName);
    return File('${store.path}.tmp');
  }

  static Future<Map<String, dynamic>?> readPayloadFromFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final payload = jsonDecode(raw);
      if (payload is Map) return payload.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  static Future<void> recoverStoreIfNeeded(File store, File tmp) async {
    final tmpPayload = await readPayloadFromFile(tmp);
    if (tmpPayload == null) return;

    final storePayload = await readPayloadFromFile(store);
    if (storePayload == null) {
      await store.writeAsString(jsonEncode(tmpPayload), flush: true);
    }

    try {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    } catch (_) {}
  }

  static void hydrateFromPayload(
    Map<String, dynamic> payload, {
    required Map<String, Tag> tagsById,
    required Map<String, Set<String>> targetToTagIds,
    required Map<String, TagTargetMeta> targetsByKey,
  }) {
    final rawTags = payload['tags'];
    if (rawTags is List) {
      for (final entry in rawTags) {
        if (entry is Map) {
          final tag = Tag.fromJson(entry.cast<String, dynamic>());
          if (tag.id.isNotEmpty) tagsById[tag.id] = tag;
        }
      }
    }

    final rawAssignments = payload['assignments'];
    if (rawAssignments is Map) {
      for (final entry in rawAssignments.entries) {
        final value = entry.value;
        if (value is List) {
          targetToTagIds[entry.key.toString()] =
              value.map((item) => item.toString()).toSet();
        }
      }
    }

    final rawTargets = payload['targets'];
    if (rawTargets is Map) {
      for (final entry in rawTargets.entries) {
        final value = entry.value;
        if (value is Map) {
          targetsByKey[entry.key.toString()] =
              TagTargetMeta.fromJson(value.cast<String, dynamic>());
        }
      }
    }
  }

  static Future<Map<String, dynamic>> readLegacyPayload({
    required String tagsKey,
    required String assignmentsKey,
    required String targetsKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'tags': const <dynamic>[],
      'assignments': const <String, dynamic>{},
      'targets': const <String, dynamic>{},
    };

    final rawTags = prefs.getString(tagsKey);
    if (rawTags != null && rawTags.trim().isNotEmpty) {
      try {
        payload['tags'] = (jsonDecode(rawTags) as List).cast<dynamic>();
      } catch (_) {}
    }

    final rawAssignments = prefs.getString(assignmentsKey);
    if (rawAssignments != null && rawAssignments.trim().isNotEmpty) {
      try {
        payload['assignments'] =
            (jsonDecode(rawAssignments) as Map).cast<String, dynamic>();
      } catch (_) {}
    }

    final rawTargets = prefs.getString(targetsKey);
    if (rawTargets != null && rawTargets.trim().isNotEmpty) {
      try {
        payload['targets'] =
            (jsonDecode(rawTargets) as Map).cast<String, dynamic>();
      } catch (_) {}
    }

    return payload;
  }

  static Future<void> persistPayload(
    Map<String, dynamic> payload, {
    required String fileName,
  }) async {
    final store = await storeFile(fileName);
    final tmp = await storeTmpFile(fileName);
    final encoded = jsonEncode(payload);
    await tmp.writeAsString(encoded, flush: true);
    await store.writeAsString(encoded, flush: true);

    try {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    } catch (_) {}
  }

  static Color pickColor(String seed) {
    const palette = <Color>[
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.red,
      Colors.indigo,
      Colors.brown,
      Colors.pink,
    ];
    var hash = 0;
    for (final code in seed.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}
