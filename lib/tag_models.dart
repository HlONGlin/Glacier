import 'package:flutter/material.dart';

enum TagKind { image, video, other }

extension TagKindX on TagKind {
  String get label {
    switch (this) {
      case TagKind.image:
        return '图片';
      case TagKind.video:
        return '视频';
      case TagKind.other:
        return '文件';
    }
  }

  IconData get icon {
    switch (this) {
      case TagKind.image:
        return Icons.image_outlined;
      case TagKind.video:
        return Icons.play_circle_outline;
      case TagKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }

  static TagKind fromFilename(String name) {
    final normalized = name.toLowerCase();
    const imageExtensions = <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp',
    };
    const videoExtensions = <String>{
      '.mp4',
      '.mkv',
      '.mov',
      '.avi',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v',
      '.mpg',
      '.mpeg',
      '.m2v',
      '.ts',
      '.m2ts',
      '.mts',
      '.vob',
      '.3gp',
      '.rm',
      '.rmvb',
      '.iso',
      '.dat',
      '.asf',
      '.f4v',
      '.divx',
      '.dv',
      '.ogv',
      '.hevc',
      '.264',
      '.265',
    };
    final dot = normalized.lastIndexOf('.');
    final ext = dot >= 0 ? normalized.substring(dot) : '';
    if (imageExtensions.contains(ext)) return TagKind.image;
    if (videoExtensions.contains(ext)) return TagKind.video;
    return TagKind.other;
  }
}

class Tag {
  final String id;
  String name;
  final int colorValue;
  String? localPath;

  Tag({
    required this.id,
    required this.name,
    required this.colorValue,
    this.localPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'c': colorValue,
        'lp': localPath,
      };

  static Tag fromJson(Map<String, dynamic> json) => Tag(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? '') as String,
        colorValue:
            (json['c'] is int) ? json['c'] as int : Colors.blue.toARGB32(),
        localPath: json['lp'] as String?,
      );
}

class TagTargetMeta {
  final String key;
  final String name;
  final TagKind kind;

  final bool isWebDav;
  final String? wdAccountId;
  final String? wdRelPath;
  final String? wdHref;

  final String? localPath;

  final bool isDir;
  final bool isEmby;
  final String? embyAccountId;
  final String? embyItemId;
  final String? embyCoverUrl;

  const TagTargetMeta({
    required this.key,
    required this.name,
    required this.kind,
    required this.isWebDav,
    this.wdAccountId,
    this.wdRelPath,
    this.wdHref,
    this.localPath,
    this.isDir = false,
    this.isEmby = false,
    this.embyAccountId,
    this.embyItemId,
    this.embyCoverUrl,
  });

  Map<String, dynamic> toJson() => {
        'k': key,
        'n': name,
        't': kind.index,
        'w': isWebDav,
        'wa': wdAccountId,
        'wr': wdRelPath,
        'wh': wdHref,
        'lp': localPath,
        'd': isDir,
        'e': isEmby,
        'ea': embyAccountId,
        'ei': embyItemId,
        'ec': embyCoverUrl,
      };

  static TagTargetMeta fromJson(Map<String, dynamic> json) {
    return TagTargetMeta(
      key: (json['k'] ?? '') as String,
      name: (json['n'] ?? '') as String,
      kind: TagKind.values[((json['t'] is int) ? json['t'] as int : 2)
          .clamp(0, TagKind.values.length - 1)],
      isWebDav: (json['w'] is bool) ? json['w'] as bool : false,
      wdAccountId: json['wa'] as String?,
      wdRelPath: json['wr'] as String?,
      wdHref: json['wh'] as String?,
      localPath: json['lp'] as String?,
      isDir: (json['d'] is bool) ? json['d'] as bool : false,
      isEmby: (json['e'] is bool) ? json['e'] as bool : false,
      embyAccountId: json['ea'] as String?,
      embyItemId: json['ei'] as String?,
      embyCoverUrl: json['ec'] as String?,
    );
  }
}
