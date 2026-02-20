import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_kit.dart';

const SystemUiOverlayStyle _kDarkStatusBarStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

/// =========================
/// Emby models & store
/// =========================

class EmbyAccount {
  final String id;
  String name;
  String serverUrl; // e.g. http://host:8096 OR http://host:8096/emby
  String username;
  String password; // 为了“免输入”体验而保存的密码（仅本地存储，存在安全风险）
  String userId;
  String apiKey;

  EmbyAccount({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    this.password = '',
    required this.userId,
    required this.apiKey,
  });

  Uri get baseUri {
    var s = serverUrl.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return Uri.parse(s);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'userId': userId,
        'apiKey': apiKey,
      };

  static EmbyAccount fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString().trim();
    return EmbyAccount(
      id: id.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : id,
      name: ((j['name'] ?? '').toString().trim().isEmpty)
          ? 'Emby'
          : (j['name'] ?? '').toString(),
      serverUrl: (j['serverUrl'] ?? '').toString(),
      username: (j['username'] ?? '').toString(),
      userId: (j['userId'] ?? '').toString(),
      apiKey: (j['apiKey'] ?? '').toString(),
    );
  }
}

class EmbyStore {
  static const _k = 'emby_accounts_v3';

  static bool _isGuid(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final r1 = RegExp(r'^[0-9a-fA-F]{32}$');
    final r2 = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return r1.hasMatch(t) || r2.hasMatch(t);
  }

  static Future<List<EmbyAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k) ??
        prefs.getString('emby_accounts_v2') ??
        prefs.getString('emby_accounts_v1');

    if (raw == null || raw.trim().isEmpty) return [];

    try {
      final list = jsonDecode(raw);
      if (list is List) {
        final accs = list
            .whereType<Map>()
            .map((m) => EmbyAccount.fromJson(m.cast<String, dynamic>()))
            .toList();

        bool mutated = false;
        for (final a in accs) {
          if (a.username.trim().isEmpty &&
              a.userId.trim().isNotEmpty &&
              !_isGuid(a.userId)) {
            a.username = a.userId.trim();
            a.userId = '';
            a.apiKey = '';
            mutated = true;
          }
          if (a.userId.trim().isNotEmpty && !_isGuid(a.userId)) {
            a.userId = '';
            a.apiKey = '';
            mutated = true;
          }
        }

        if (mutated) {
          await save(accs);
        }
        return accs;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> save(List<EmbyAccount> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_k, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('emby_device_id');
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();

    final r = Random();
    final id =
        'android-${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 32)}';
    await prefs.setString('emby_device_id', id);
    return id;
  }
}

/// =========================
/// Emby client
/// =========================

class EmbyItem {
  final String id;
  final String name;
  final String type;
  final String? primaryTag;

  final String? thumbTag;
  final List<String> backdropTags;
  final bool isFolder;
  final String? mediaType;

  /// 加入日期（Emby：通常对应 DateCreated，代表资源被加入媒体库的时间）。
  /// 设计原因：
  /// - Emby 的“文件修改时间”概念并不稳定，很多条目也无法映射到真实文件时间；
  /// - 按需求：当用户选择“日期排序”时，Emby 条目需要以“加入日期”参与排序。
  final DateTime? dateCreated;

  /// 修改日期（Emby：通常对应 DateModified）。
  ///
  /// ✅ 为什么需要它：
  /// - 部分服务端/库类型不会返回 DateCreated（或语义不稳定）；
  /// - 在“按日期排序”时，如果 DateCreated 缺失，使用 DateModified 能显著提升可用性。
  final DateTime? dateModified;

  /// 文件大小（字节）。
  /// - Emby 的大小通常存在于 MediaSources[0].Size（需要 Fields=MediaSources）；
  /// - 若接口未返回该字段，则保持为 0，避免误导用户。
  final int size;

  EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    this.primaryTag,
    this.thumbTag,
    this.backdropTags = const [],
    this.isFolder = false,
    this.mediaType,
    this.dateCreated,
    this.dateModified,
    this.size = 0,
  });

  static EmbyItem fromJson(Map<String, dynamic> j) {
    final tags = (j['ImageTags'] is Map)
        ? (j['ImageTags'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final backdropTagsRaw = j['BackdropImageTags'];
    final backdropTags = <String>[];
    if (backdropTagsRaw is List) {
      for (final t in backdropTagsRaw) {
        final s = (t ?? '').toString().trim();
        if (s.isNotEmpty) backdropTags.add(s);
      }
    }

    String? _tagOrNull(dynamic v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    DateTime? _parseDate(String key) {
      final raw = (j[key] ?? '').toString().trim();
      if (raw.isEmpty) return null;
      try {
        return DateTime.parse(raw);
      } catch (_) {
        return null;
      }
    }

    int _parseSize() {
      final v = j['Size'];
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }

      final ms = j['MediaSources'];
      if (ms is List && ms.isNotEmpty) {
        final first = ms.first;
        if (first is Map) {
          final vv = first['Size'];
          if (vv is int) return vv;
          if (vv is double) return vv.toInt();
          if (vv is String) {
            final n = int.tryParse(vv);
            if (n != null) return n;
          }
        }
      }
      return 0;
    }

    final mediaTypeRaw = (j['MediaType'] ?? '').toString().trim();
    return EmbyItem(
      id: (j['Id'] ?? '').toString(),
      name: (j['Name'] ?? '').toString(),
      type: (j['Type'] ?? '').toString(),
      mediaType: mediaTypeRaw.isEmpty ? null : mediaTypeRaw,
      isFolder: j['IsFolder'] == true,
      primaryTag: _tagOrNull(tags['Primary']),
      thumbTag: _tagOrNull(tags['Thumb']),
      backdropTags: backdropTags,
      // DateAdded 在部分服务端实现中可能存在；优先 DateCreated，兜底 DateAdded。
      dateCreated: _parseDate('DateCreated') ?? _parseDate('DateAdded'),
      // DateModified 在很多库类型上更稳定（例如部分剧集/扫描器实现）。
      dateModified: _parseDate('DateModified'),
      size: _parseSize(),
    );
  }
}

class EmbyLoginResult {
  final String accessToken;
  final String userId;
  final String userName;
  EmbyLoginResult(
      {required this.accessToken,
      required this.userId,
      required this.userName});
}

/// Emby 字幕轨道信息（用于外部字幕/SRT 功能）。
///
/// 说明：Emby 的 Item 信息里会返回 MediaSources + MediaStreams（包含字幕流）。
/// 我们只取字幕类型（Type=Subtitle）的流，提供给播放器选择。
///
/// ✅ 为什么需要它：
/// - 对 Emby 视频来说，客户端本地通常没有同目录 .srt
/// - 通过 Emby API 可以直接获取/拉取字幕流，避免“字幕功能无法使用”。
///
/// 注意：不同 Emby 版本字段可能略有差异，因此解析要尽量宽容。
class EmbySubtitleTrack {
  final int index;
  final String mediaSourceId;
  final String title;
  final String? language;
  final String? codec;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;

  EmbySubtitleTrack({
    required this.index,
    required this.mediaSourceId,
    required this.title,
    this.language,
    this.codec,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
  });
}

/// Emby 播放协商（PlaybackInfo）关键信息。
///
/// ✅ 为什么需要它：
/// - Emby 官方的“播放上报/进度同步”需要 PlaySessionId + MediaSourceId。
/// - 如果只靠拼接 streamUrl 直连播放，服务端不会认为你是一个“正常客户端会话”，
///   结果就是：仪表盘不显示正在播放、进度/观看记录不更新、转码会话可能无法及时释放。
///
/// 说明：
/// - 不同 Emby 版本对 PlaybackInfo 的字段细节可能略有差异，因此这里保持字段宽松、可选。
class EmbyPlaybackInfo {
  final String playSessionId;
  final String mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;

  EmbyPlaybackInfo({
    required this.playSessionId,
    required this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });
}

/// =========================
/// Emby client (修复重定向丢失鉴权头问题 + 关键：修复 /emby 前缀与 resolve 行为)
/// =========================
class EmbyClient {
  final EmbyAccount account;
  EmbyClient(this.account);

  /// ✅ 轻量缓存：同一个 EmbyClient 实例生命周期内，只校验一次 token。
  ///
  /// 背景：播放器/排序补全等功能可能会在短时间内触发多次 API 调用。
  /// 如果每次都 validateToken()（会请求 /Users/{id}），会产生额外网络开销与卡顿。
  ///
  /// 说明：
  /// - 该缓存仅存在于单个 client 实例内；页面/播放器重新创建 client 仍会重新校验。
  /// - 若校验失败，会清空缓存，允许后续重试。
  Future<void>? _validateFuture;

  /// Emby 字幕轨道信息（用于外部字幕/SRT 功能）。
  ///
  /// 说明：Emby 的 Item 信息里会返回 MediaSources + MediaStreams（包含字幕流）。
  /// 我们只取字幕类型（Type=Subtitle）的流，提供给播放器选择。
  ///
  /// ✅ 为什么需要它：
  /// - 对 Emby 视频来说，客户端本地通常没有同目录 .srt
  /// - 通过 Emby API 可以直接获取/拉取字幕流，避免“字幕功能无法使用”。
  ///
  /// 注意：不同 Emby 版本字段可能略有差异，因此解析要尽量宽容。
  static const String _kStreamTypeSubtitle = 'Subtitle';

  /// 获取 Emby 播放协商信息（PlaySessionId / MediaSourceId 等）。
  ///
  /// ✅ 设计说明（中文解释“为什么”）：
  /// - 播放上报（/Sessions/Playing...）里 PlaySessionId / MediaSourceId 是核心字段；
  /// - 它们最好由服务端通过 PlaybackInfo 下发，而不是客户端“自己造一个”。
  /// - 这里采用“优先 PlaybackInfo，失败再回退到 Items”的策略，确保在反代/权限差异
  ///   下也尽量能拿到 MediaSourceId（至少能做基础上报）。
  Future<EmbyPlaybackInfo?> playbackInfo(String itemId) async {
    await validateToken();
    final id = itemId.trim();
    if (id.isEmpty) return null;

    Map<String, dynamic>? pb;
    try {
      final uri = _u('/Items/$id/PlaybackInfo', <String, String>{
        'UserId': account.userId,
        'IsPlayback': 'true',
        'AutoOpenLiveStream': 'false',
      });
      pb = await _getJson(uri);
    } catch (_) {
      pb = null;
    }

    String playSessionId = '';
    String mediaSourceId = '';
    int? audioIdx;
    int? subIdx;

    if (pb != null && pb.isNotEmpty) {
      playSessionId = (pb['PlaySessionId'] ?? '').toString().trim();
      final sources = (pb['MediaSources'] is List)
          ? (pb['MediaSources'] as List)
          : <dynamic>[];
      final first = sources.isNotEmpty ? sources.first : null;
      if (first is Map) {
        mediaSourceId = (first['Id'] ?? '').toString().trim();
        final a = first['DefaultAudioStreamIndex'] ?? first['AudioStreamIndex'];
        final s =
            first['DefaultSubtitleStreamIndex'] ?? first['SubtitleStreamIndex'];
        audioIdx = int.tryParse((a ?? '').toString());
        subIdx = int.tryParse((s ?? '').toString());
      }
    }

    // ✅ PlaybackInfo 拿不到 MediaSourceId 时，回退到 Items。
    if (mediaSourceId.isEmpty) {
      try {
        final uri = _u('/Items/$id', <String, String>{
          'Fields': 'MediaSources,MediaStreams',
        });
        final j = await _getJson(uri);
        final sources = (j['MediaSources'] is List)
            ? (j['MediaSources'] as List)
            : <dynamic>[];
        final first = sources.isNotEmpty ? sources.first : null;
        if (first is Map) {
          mediaSourceId = (first['Id'] ?? '').toString().trim();
        }
      } catch (_) {}
    }

    if (mediaSourceId.isEmpty) return null;

    // ✅ 兜底：如果服务端没返回 PlaySessionId，我们只能生成一个。
    // 说明：这种情况下“停止上报”可能无法精确释放服务端转码，但至少可以更新进度。
    if (playSessionId.isEmpty) {
      playSessionId = 'flutter_${DateTime.now().millisecondsSinceEpoch}_$id';
    }

    return EmbyPlaybackInfo(
      playSessionId: playSessionId,
      mediaSourceId: mediaSourceId,
      audioStreamIndex: audioIdx,
      subtitleStreamIndex: subIdx,
    );
  }

  /// 获取 Emby 视频的字幕轨道列表。
  Future<List<EmbySubtitleTrack>> listSubtitleTracks(String itemId) async {
    await validateToken();
    if (itemId.trim().isEmpty) return [];

    // ✅ 重点修复：SRT 主要在 Emby 场景使用，但部分 Emby 版本里：
    // - /Items/{id}?Fields=MediaSources 可能不返回完整的 MediaStreams
    // - 或者返回的 MediaStreams 为空（导致客户端“看不到外部字幕”）
    //
    // 更稳定的做法是优先走 PlaybackInfo：它就是给播放器准备的播放参数，
    // 通常一定包含 MediaSources + MediaStreams（字幕流也在这里）。
    Map<String, dynamic>? playback;
    try {
      final uri = _u('/Items/$itemId/PlaybackInfo', <String, String>{
        'UserId': account.userId,
        'IsPlayback': 'true',
        'AutoOpenLiveStream': 'false',
      });
      playback = await _getJson(uri);
    } catch (_) {
      // ✅ 保底：若 PlaybackInfo 被反代/权限拦截，再回退到 Items
    }

    Map<String, dynamic>? item;
    if (playback == null || playback.isEmpty) {
      try {
        final uri = _u('/Items/$itemId', <String, String>{
          'Fields': 'MediaSources,MediaStreams',
        });
        item = await _getJson(uri);
      } catch (_) {}
    }

    final srcContainer = (playback != null && playback.isNotEmpty)
        ? playback
        : (item ?? <String, dynamic>{});

    // PlaybackInfo 的 MediaSources 通常直接在根级；Items 也是。
    final sources = (srcContainer['MediaSources'] is List)
        ? (srcContainer['MediaSources'] as List)
        : <dynamic>[];
    if (sources.isEmpty) return [];

    // ✅ 选择第一个可用的 MediaSource。
    // 说明：
    // - 有些条目会返回多个 MediaSource（不同码率/容器/外挂字幕等）
    // - 我们先取第一个，后续如果你反馈仍有缺失，再做“按选择源”扩展。
    final first = sources.first;
    if (first is! Map) return [];
    final msId = (first['Id'] ?? '').toString().trim();
    if (msId.isEmpty) return [];

    final streams = (first['MediaStreams'] is List)
        ? (first['MediaStreams'] as List)
        : <dynamic>[];
    if (streams.isEmpty) {
      // ✅ 兼容：有些 PlaybackInfo 会把 MediaStreams 放在 root 字段里
      final rootStreams = (srcContainer['MediaStreams'] is List)
          ? (srcContainer['MediaStreams'] as List)
          : <dynamic>[];
      if (rootStreams.isEmpty) return [];
      // 将 rootStreams 当作 streams 使用
      return _parseSubtitleStreams(rootStreams, msId);
    }

    return _parseSubtitleStreams(streams, msId);
  }

  /// 获取条目的展示名称（用于历史记录等 UI 展示）。
  ///
  /// ✅ 为什么需要它：
  /// - 历史记录的 key 可能只有 emby://<acc>/item:<id>（没有携带 name 参数）；
  /// - 此时播放器侧无法从 URL 推出“真实名称”，会退化成“Emby 媒体”；
  /// - 通过一次轻量的 Items 查询拿到 Name，即可让历史记录显示中文标题。
  Future<String?> getItemName(String itemId) async {
    await validateToken();
    final id = itemId.trim();
    if (id.isEmpty) return null;
    try {
      final uri = _u('/Items/$id', <String, String>{});
      final j = await _getJson(uri);
      final name = (j['Name'] ?? j['OriginalTitle'] ?? '').toString().trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  /// 获取条目的 ParentId（用于“播放器目录/同文件夹播放列表”等功能）。
  ///
  /// ✅ 设计说明：
  /// - 历史记录里通常只保存 itemId；
  /// - 播放器侧需要知道“同目录/同季/同文件夹”的其它条目时，必须先拿 ParentId。
  Future<String?> getItemType(String itemId) async {
    await validateToken();
    final id = itemId.trim();
    if (id.isEmpty) return null;
    try {
      final uri = _u('/Items/$id', <String, String>{});
      final j = await _getJson(uri);
      final t = (j['Type'] ?? '').toString().trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getItemParentId(String itemId) async {
    await validateToken();
    final id = itemId.trim();
    if (id.isEmpty) return null;
    try {
      final uri = _u('/Items/$id', <String, String>{});
      final j = await _getJson(uri);
      final pid = (j['ParentId'] ?? '').toString().trim();
      return pid.isEmpty ? null : pid;
    } catch (_) {
      return null;
    }
  }

  /// 获取条目的文件大小（字节）。
  ///
  /// ✅ 为什么需要：
  /// - 部分服务端在列表接口不返回 MediaSources（或返回不完整），导致 size=0；
  /// - 在“按大小排序”时，为了让 Emby 文件数据真正生效，这里提供按需补全的能力。
  Future<int?> getItemSize(String itemId) async {
    await validateToken();
    final id = itemId.trim();
    if (id.isEmpty) return null;
    try {
      final uri = _u('/Items/$id', <String, String>{
        'Fields': 'MediaSources,Size',
      });
      final j = await _getJson(uri);
      if (j is! Map) return null;
      final item = EmbyItem.fromJson(j.cast<String, dynamic>());
      return item.size > 0 ? item.size : null;
    } catch (_) {
      return null;
    }
  }

  /// 解析字幕流（Type=Subtitle）。
  ///
  /// ✅ 单独抽出来的原因：
  /// - PlaybackInfo/Items 的字段结构可能会漂移
  /// - 拆分后更容易做兼容扩展，不影响其它逻辑
  List<EmbySubtitleTrack> _parseSubtitleStreams(
      List<dynamic> streams, String mediaSourceId) {
    final out = <EmbySubtitleTrack>[];

    for (final s in streams) {
      if (s is! Map) continue;
      final type = (s['Type'] ?? '').toString();
      if (type != _kStreamTypeSubtitle) continue;

      // Emby 常见字段：Index / StreamIndex / Language / DisplayTitle / Codec
      final idxRaw = s['Index'] ?? s['StreamIndex'] ?? s['IndexNumber'];
      final idx = int.tryParse((idxRaw ?? '').toString());
      if (idx == null) continue;

      final lang = (s['Language'] ?? '').toString().trim();
      final codec = (s['Codec'] ?? '').toString().trim();
      final display = (s['DisplayTitle'] ?? '').toString().trim();

      final isDefault = s['IsDefault'] == true;
      final isForced = s['IsForced'] == true;
      final isExternal = s['IsExternal'] == true;

      // 展示标题：优先 DisplayTitle，其次 Language + Codec。
      String title = display;
      if (title.isEmpty) {
        final parts = <String>[];
        if (lang.isNotEmpty) parts.add(lang);
        if (codec.isNotEmpty) parts.add(codec.toUpperCase());
        title = parts.isEmpty ? '字幕#$idx' : parts.join(' · ');
      }
      if (isForced) title = '$title（强制）';
      if (isExternal) title = '$title（外部）';

      out.add(EmbySubtitleTrack(
        index: idx,
        mediaSourceId: mediaSourceId,
        title: title,
        language: lang.isEmpty ? null : lang,
        codec: codec.isEmpty ? null : codec,
        isDefault: isDefault,
        isForced: isForced,
        isExternal: isExternal,
      ));
    }

    // 默认字幕优先排前，其余按 index。
    out.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.index.compareTo(b.index);
    });
    return out;
  }

  /// 构造 Emby 字幕流 URL。
  ///
  /// 说明：不同版本可能支持 Stream 或 Stream.{format}。
  /// 这里用 query 的 Format=srt 做兼容。
  String subtitleStreamUrl({
    required String itemId,
    required String mediaSourceId,
    required int subtitleIndex,
    String format = 'srt',
    String? deviceId,
  }) {
    // ✅ 重点兼容：不同 Emby/Jellyfin 版本、以及反代配置下，字幕流接口可能是：
    // 1) .../Stream?Format=srt
    // 2) .../Stream.srt
    //
    // media_kit 对“带扩展名的 URL”识别通常更稳定，因此优先使用 Stream.srt。
    final did = (deviceId ?? 'flutter_client').trim();
    final path1 =
        '/Videos/$itemId/$mediaSourceId/Subtitles/$subtitleIndex/Stream.$format';
    final uri1 = _u(path1, {
      // ✅ 这里用 query 参数的方式传 token，是因为 media_kit 的字幕拉取不方便附带自定义 header。
      'api_key': account.apiKey,
      'X-Emby-Token': account.apiKey,
      'UserId': account.userId,
      if (did.isNotEmpty) 'DeviceId': did,
      'DeviceName': 'Flutter',
    });
    return uri1.toString();
  }

  /// 上报：播放开始（/Sessions/Playing）。
  Future<void> reportPlaybackStarted(Map<String, dynamic> body) async {
    await _postPlaybackCheckIn('/Sessions/Playing', body);
  }

  /// 上报：播放进度（/Sessions/Playing/Progress）。
  ///
  /// 注意：body 需要包含 EventName（TimeUpdate/Pause/Unpause 等）。
  Future<void> reportPlaybackProgress(Map<String, dynamic> body) async {
    await _postPlaybackCheckIn('/Sessions/Playing/Progress', body);
  }

  /// 上报：播放停止（/Sessions/Playing/Stopped）。
  Future<void> reportPlaybackStopped(Map<String, dynamic> body) async {
    await _postPlaybackCheckIn('/Sessions/Playing/Stopped', body);
  }

  Future<void> _postPlaybackCheckIn(
      String path, Map<String, dynamic> body) async {
    await validateToken();
    final uri = _u(path, <String, String>{
      // ✅ 某些反代/插件会要求 query 携带 api_key；这里同时保留 header + query 的方式。
      'api_key': account.apiKey,
    });

    final deviceId = await EmbyStore.getOrCreateDeviceId();
    final headers = <String, String>{
      'X-Emby-Token': account.apiKey,
      'X-Emby-Authorization': _authHeader(deviceId: deviceId),
    };

    final bodyBytes = utf8.encode(jsonEncode(body));
    final resp =
        await _sendRequest('POST', uri, headers: headers, bodyBytes: bodyBytes);
    final text = await utf8.decodeStream(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Emby 上报失败：HTTP ${resp.statusCode}\n$text');
    }
  }

  static bool isGuid(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final r1 = RegExp(r'^[0-9a-fA-F]{32}$');
    final r2 = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return r1.hasMatch(t) || r2.hasMatch(t);
  }

  /// ✅ 统一构造 API Uri
  /// - serverUrl = http://host:8096           → API 走 http://host:8096/emby/...
  /// - serverUrl = http://host:8096/emby      → API 走 http://host:8096/emby/...
  /// - serverUrl = http://host:8096/emby/     → API 走 http://host:8096/emby/...
  Uri _u(String path, [Map<String, String>? q]) {
    final base0 = account.baseUri;

    // ✅ 关键修复：把 base 变成“目录形式”（path 必须以 / 结尾），否则 Uri.resolve 会丢最后一段
    Uri base = base0;
    if (base.path.isNotEmpty && !base.path.endsWith('/')) {
      base = base.replace(path: '${base.path}/');
    }

    // ✅ 如果用户填的是根（无 path 或只有 /），自动补 /emby/
    final needsEmbyPrefix = (base.path.isEmpty || base.path == '/');
    final apiBase = needsEmbyPrefix ? base.replace(path: '/emby/') : base;

    final u = apiBase.resolve(path.startsWith('/') ? path.substring(1) : path);
    if (q == null || q.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...q});
  }

  /// 构造标准鉴权头
  String _authHeader({
    String client = 'FlutterClient',
    String device = 'Android',
    required String deviceId,
    String version = '1.0.0',
  }) {
    return 'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version"';
  }

  Future<HttpClientResponse> _sendRequest(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
    int redirectCount = 0,
  }) async {
    if (redirectCount > 5) throw Exception('重定向次数过多');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    final req = await client.openUrl(method, uri);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (bodyBytes != null) {
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.contentLength = bodyBytes.length;
    }
    headers?.forEach((k, v) => req.headers.set(k, v));
    if (bodyBytes != null) req.add(bodyBytes);

    final resp = await req.close();

    if (resp.isRedirect) {
      final location = resp.headers.value(HttpHeaders.locationHeader);
      if (location != null) {
        final newUri = uri.resolve(location);
        return _sendRequest(
          method,
          newUri,
          headers: headers,
          bodyBytes: bodyBytes,
          redirectCount: redirectCount + 1,
        );
      }
    }
    return resp;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final headers = <String, String>{};
    if (account.apiKey.trim().isNotEmpty) {
      headers['X-Emby-Token'] = account.apiKey;
    }

    final resp = await _sendRequest('GET', uri, headers: headers);
    final body = await utf8.decodeStream(resp);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Emby 请求失败：HTTP ${resp.statusCode}\n$body');
    }
    final data = jsonDecode(body);
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  Future<EmbyLoginResult> loginByName({
    required String username,
    required String password,
    required String deviceId,
    String clientName = 'FlutterClient',
    String deviceName = 'Android',
    String version = '1.0.0',
  }) async {
    final uri = _u('/Users/AuthenticateByName');

    final bodyMap = <String, dynamic>{
      'Username': username.trim(),
      'Pw': password,
      'Password': password,
    };
    final bodyBytes = utf8.encode(jsonEncode(bodyMap));

    final headers = <String, String>{
      'X-Emby-Authorization': _authHeader(
        client: clientName,
        device: deviceName,
        deviceId: deviceId,
        version: version,
      ),
    };

    final resp =
        await _sendRequest('POST', uri, headers: headers, bodyBytes: bodyBytes);
    final text = await utf8.decodeStream(resp);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('登录失败 (HTTP ${resp.statusCode}):\n$text');
    }

    final j = jsonDecode(text);
    final m = (j is Map) ? j.cast<String, dynamic>() : <String, dynamic>{};

    final token = (m['AccessToken'] ?? '').toString().trim();
    final user = (m['User'] is Map)
        ? (m['User'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final uid = (user['Id'] ?? '').toString().trim();
    final uname = (user['Name'] ?? username).toString().trim();

    if (token.isEmpty || uid.isEmpty) {
      throw Exception('登录成功但返回数据缺失 (Token/Id):\n$text');
    }
    if (!EmbyClient.isGuid(uid)) {
      throw Exception('登录返回的 UserId 不是 Guid: $uid');
    }

    return EmbyLoginResult(accessToken: token, userId: uid, userName: uname);
  }

  Future<List<EmbyItem>> listFavorites() async {
    await validateToken();

    // ✅ 兼容性：部分服务端/版本可能不支持在列表接口里返回 MediaSources，
    // 这会导致“大小排序/显示”拿不到 Size 字段，甚至直接请求失败（例如 HTTP 400）。
    // 因此这里先尝试带 MediaSources，失败则自动回退到基础字段，保证浏览功能可用。
    Future<List<EmbyItem>> _fetch(String fields) async {
      final uri = _u('/Users/${account.userId}/Items', <String, String>{
        'Recursive': 'true',
        'Filters': 'IsFavorite',
        'IncludeItemTypes': 'Movie,Episode,Video',
        'Fields': fields,
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
      });
      final data = await _getJson(uri);
      final items =
          (data['Items'] is List) ? (data['Items'] as List) : <dynamic>[];
      return items
          .whereType<Map>()
          .map((m) => EmbyItem.fromJson(m.cast<String, dynamic>()))
          .toList();
    }

    // ✅ DateModified：用于“日期排序”兜底；部分库类型不会返回 DateCreated。
    const full =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified,MediaSources';
    const fallback =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified';

    try {
      return await _fetch(full);
    } catch (_) {
      return await _fetch(fallback);
    }
  }

  Future<void> validateToken() async {
    if (_validateFuture != null) {
      return _validateFuture!;
    }

    _validateFuture = () async {
      if (account.userId.trim().isEmpty || account.apiKey.trim().isEmpty) {
        throw Exception('Emby 未登录：请先登录获取 Token');
      }
      if (!EmbyClient.isGuid(account.userId)) {
        throw Exception('UserId 格式错误，请重新登录。');
      }
      final uri = _u('/Users/${account.userId}');
      await _getJson(uri);
    }();

    try {
      await _validateFuture!;
    } catch (_) {
      // 校验失败：允许后续重新触发校验
      _validateFuture = null;
      rethrow;
    }
  }

  Future<List<EmbyItem>> listViews() async {
    await validateToken();
    final uri = _u('/Users/${account.userId}/Views', <String, String>{
      'Fields': 'ImageTags,PrimaryImageAspectRatio',
    });
    final data = await _getJson(uri);
    final items =
        (data['Items'] is List) ? (data['Items'] as List) : <dynamic>[];
    return items
        .whereType<Map>()
        .map((m) => EmbyItem.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<List<EmbyItem>> listChildren({required String parentId}) async {
    await validateToken();

    // 同 listFavorites：优先请求 MediaSources 以获取 Size（用于大小排序/显示），失败则回退。
    Future<List<EmbyItem>> _fetch(String fields) async {
      final uri = _u('/Users/${account.userId}/Items', <String, String>{
        'ParentId': parentId,
        'Recursive': 'false',
        'Fields': fields,
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
      });
      final data = await _getJson(uri);
      final items =
          (data['Items'] is List) ? (data['Items'] as List) : <dynamic>[];
      return items
          .whereType<Map>()
          .map((m) => EmbyItem.fromJson(m.cast<String, dynamic>()))
          .toList();
    }

    // ✅ DateModified：用于“日期排序”兜底；部分库类型不会返回 DateCreated。
    const full =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified,MediaSources';
    const fallback =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified';

    try {
      return await _fetch(full);
    } catch (_) {
      return await _fetch(fallback);
    }
  }

  /// Emby 关键词搜索（服务端递归检索）。
  ///
  /// 说明：
  /// - `parentId` 为空时，在当前用户可见范围内搜索；
  /// - `parentId` 非空时，限定在该目录（可递归）搜索；
  /// - 返回值统一复用 EmbyItem，便于页面侧直接映射成目录/媒体条目。
  Future<List<EmbyItem>> searchItems({
    required String query,
    String? parentId,
    bool recursive = true,
    int limit = 300,
  }) async {
    await validateToken();
    final q = query.trim();
    if (q.isEmpty) return const <EmbyItem>[];

    Future<List<EmbyItem>> _fetch({
      required String fields,
      String? includeItemTypes,
    }) async {
      final qp = <String, String>{
        'SearchTerm': q,
        'Recursive': recursive ? 'true' : 'false',
        'Fields': fields,
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'Limit': '${limit.clamp(1, 600)}',
      };
      final include = (includeItemTypes ?? '').trim();
      if (include.isNotEmpty) {
        qp['IncludeItemTypes'] = include;
      }
      final pid = (parentId ?? '').trim();
      if (pid.isNotEmpty) qp['ParentId'] = pid;

      final uri = _u('/Users/${account.userId}/Items', qp);
      final data = await _getJson(uri);
      final items =
          (data['Items'] is List) ? (data['Items'] as List) : <dynamic>[];
      return items
          .whereType<Map>()
          .map((m) => EmbyItem.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false);
    }

    const full =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified,MediaSources';
    const fallback =
        'ImageTags,PrimaryImageAspectRatio,DateCreated,DateModified';

    // 兼容不同 Emby 版本：
    // - 第一档：目录+常见媒体类型（结果更聚焦）；
    // - 第二档：仅常见目录/视频/图片类型（避免个别版本对某些类型名敏感）；
    // - 第三档：不传 IncludeItemTypes，交由服务端默认行为处理。
    const includeTypesPrimary =
        'Folder,CollectionFolder,UserView,Series,Season,BoxSet,Movie,Episode,Video,Photo,MusicVideo';
    const includeTypesCompat =
        'Folder,Series,Season,BoxSet,Movie,Episode,Video,Photo,MusicVideo';

    Future<List<EmbyItem>> _fetchWithCompat(String fields) async {
      Object? lastErr;
      for (final types in <String?>[
        includeTypesPrimary,
        includeTypesCompat,
        null,
      ]) {
        try {
          return await _fetch(fields: fields, includeItemTypes: types);
        } catch (e) {
          lastErr = e;
        }
      }
      if (lastErr != null) throw lastErr;
      return const <EmbyItem>[];
    }

    try {
      return await _fetchWithCompat(full);
    } catch (_) {
      return await _fetchWithCompat(fallback);
    }
  }

  /// ✅ Emby 子目录封面兜底（按你测试的 Emby 行为：递归取“第一张图片”）
  /// - 先在该目录下（含所有子子目录）找第一张 Photo
  /// - 找到后返回该 Photo 的 Primary 图片 URL
  /// - 若整棵目录都没有 Photo，可选再用第一条视频兜底（仍然按 SortName）
  Future<String?> pickAutoFolderCoverUrl({
    required String folderId,
    int maxWidth = 420,
    int quality = 85,
    bool fallbackToVideo = true,
  }) async {
    await validateToken();

    // 0) 先尝试目录自身是否真的有可用图片（很多“自动生成封面”的目录本身没有 Primary，直接取会 404）
    // 但也存在目录本身有 ImageTags 的情况，此时直接用目录图片最快。
    try {
      final itemUri =
          _u('/Users/${account.userId}/Items/$folderId', <String, String>{
        'Fields': 'ImageTags,BackdropImageTags,PrimaryImageAspectRatio',
      });
      final j = await _getJson(itemUri);
      if (j is Map) {
        final self = EmbyItem.fromJson(j.cast<String, dynamic>());
        final selfUrl =
            _bestExistingImageUrl(self, maxWidth: maxWidth, quality: quality);
        if (selfUrl != null) return selfUrl;
      }
    } catch (_) {
      // 忽略：无权限/旧版本不支持该 endpoint 等
    }

    // ✅ 递归候选：一次拉一批，挑“真正有图片 tag”的第一个
    Future<EmbyItem?> _pickFirstWithImage({
      required String includeItemTypes,
      int limit = 60,
    }) async {
      final uri = _u('/Users/${account.userId}/Items', <String, String>{
        'ParentId': folderId,
        'Recursive': 'true',
        'IncludeItemTypes': includeItemTypes,
        'Fields': 'ImageTags,PrimaryImageAspectRatio',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'Limit': '$limit',
      });

      final data = await _getJson(uri);
      final items =
          (data['Items'] is List) ? (data['Items'] as List) : <dynamic>[];
      if (items.isEmpty) return null;
      for (final it in items) {
        if (it is! Map) continue;
        final item = EmbyItem.fromJson(it.cast<String, dynamic>());
        // 只接受“已有图片 tag”的条目，否则 bestCoverUrl 可能会拼出一个必 404 的 URL
        if (item.primaryTag != null ||
            item.thumbTag != null ||
            item.backdropTags.isNotEmpty) {
          return item;
        }
      }
      return null;
    }

    // 1) Photo 优先（如果你的图片被入库为 Photo）
    final photo =
        await _pickFirstWithImage(includeItemTypes: 'Photo', limit: 120);
    if (photo != null)
      return bestCoverUrl(photo, maxWidth: maxWidth, quality: quality);

    // 1.5) 很多“目录内图片文件”并不会作为 Photo 出现，而是作为某个视频/剧集的本地图片或缩略图。
    // 因此这里再把常见媒体类型也一起扫一遍，仍然取“第一个有图片 tag 的条目”。
    final media = await _pickFirstWithImage(
      includeItemTypes: 'Movie,Episode,Video,MusicVideo,Series,Season',
      limit: 200,
    );
    if (media != null)
      return bestCoverUrl(media, maxWidth: maxWidth, quality: quality);

    // 2) 可选：再用第一条视频兜底
    if (fallbackToVideo) {
      final video = await _pickFirstWithImage(
          includeItemTypes: 'Movie,Episode,Video,MusicVideo', limit: 300);
      if (video != null)
        return bestCoverUrl(video, maxWidth: maxWidth, quality: quality);
    }

    return null;
  }

  /// 仅当条目“明确有图片 tag”时，才返回 URL（避免无 tag 时拼出必 404 的 Primary）
  String? _bestExistingImageUrl(EmbyItem item,
      {int maxWidth = 420, int quality = 85}) {
    if (item.primaryTag != null) {
      return coverUrl(item.id,
          type: 'Primary',
          maxWidth: maxWidth,
          quality: quality,
          tag: item.primaryTag);
    }
    if (item.thumbTag != null) {
      return coverUrl(item.id,
          type: 'Thumb',
          maxWidth: maxWidth,
          quality: quality,
          tag: item.thumbTag);
    }
    if (item.backdropTags.isNotEmpty) {
      // backdrop 用 index=0 + tag
      return coverUrl(item.id,
          type: 'Backdrop',
          index: 0,
          maxWidth: maxWidth,
          quality: quality,
          tag: item.backdropTags.first);
    }
    return null;
  }

  static Future<List<EmbyItem>> listAllFavorites(
      List<EmbyAccount> accounts) async {
    final out = <EmbyItem>[];
    for (final a in accounts) {
      if (a.userId.trim().isEmpty || a.apiKey.trim().isEmpty) continue;
      if (!EmbyClient.isGuid(a.userId)) continue;
      try {
        final items = await EmbyClient(a).listFavorites();
        out.addAll(items);
      } catch (_) {}
    }
    return out;
  }

  // ✅ 插入位置：紧挨着你现有 `String coverUrl(` 的上一行
  Map<String, String> imageHeaders() {
    final h = <String, String>{};
    if (account.apiKey.trim().isNotEmpty) {
      h['X-Emby-Token'] = account.apiKey.trim();
    }
    return h;
  }

  // ✅ 替换整个 coverUrl 方法
  String coverUrl(
    String itemId, {
    String type = 'Primary',
    int? index,
    String? tag,
    int? maxWidth = 420,
    int? quality = 90,
  }) {
    final q = <String, String>{
      // ✅ 建议只保留 api_key（或只用 Header；二选一）
      // 如果你想“完全走 Header”，这里可以把 api_key 也删掉
      'api_key': account.apiKey.trim(),
    };
    if (maxWidth != null && maxWidth > 0) q['maxWidth'] = '$maxWidth';
    if (quality != null && quality > 0) q['quality'] = '$quality';

    // ✅ tag 可有可无：为空时不要 return ''，照样给 URL
    final t = (tag ?? '').trim();
    if (t.isNotEmpty) q['tag'] = t;

    if (index != null) q['imageIndex'] = index.toString();

    final uri = _u('/Items/$itemId/Images/$type', q);
    return uri.toString();
  }

  /// 原图 URL：不带 maxWidth/quality，尽量请求服务端原始分辨率。
  String originalImageUrl(
    String itemId, {
    String type = 'Primary',
    int? index,
    String? tag,
  }) {
    return coverUrl(
      itemId,
      type: type,
      index: index,
      tag: tag,
      maxWidth: null,
      quality: null,
    );
  }

  /// 面向图片播放：优先原图并保留 tag 命中。
  String bestImageUrl(EmbyItem item) {
    if (item.primaryTag != null) {
      return originalImageUrl(item.id, type: 'Primary', tag: item.primaryTag);
    }

    final primaryNoTag = originalImageUrl(item.id, type: 'Primary');
    if (primaryNoTag.isNotEmpty) return primaryNoTag;

    if (item.thumbTag != null) {
      return originalImageUrl(item.id, type: 'Thumb', tag: item.thumbTag);
    }
    if (item.backdropTags.isNotEmpty) {
      return originalImageUrl(
        item.id,
        type: 'Backdrop',
        index: 0,
        tag: item.backdropTags.first,
      );
    }
    return originalImageUrl(item.id, type: 'Thumb');
  }

  String bestCoverUrl(EmbyItem item, {int maxWidth = 420, int quality = 85}) {
    // 子目录（Folder/Season/Series 等）通常更依赖“海报/Primary”。
    // 1) 有 tag 的优先（缓存命中更好）
    if (item.primaryTag != null) {
      return coverUrl(item.id,
          type: 'Primary',
          maxWidth: maxWidth,
          quality: quality,
          tag: item.primaryTag);
    }

    // 2) ✅ 关键兜底：没有 tag 也先尝试 Primary（让 Emby 自己返回自动生成/继承的海报）
    // 这对“子目录海报”最关键。
    final primaryNoTag = coverUrl(item.id,
        type: 'Primary', maxWidth: maxWidth, quality: quality);
    if (primaryNoTag.isNotEmpty) {
      return primaryNoTag;
    }

    // 3) 再尝试 Thumb / Backdrop
    if (item.thumbTag != null) {
      return coverUrl(item.id,
          type: 'Thumb',
          maxWidth: maxWidth,
          quality: quality,
          tag: item.thumbTag);
    }
    if (item.backdropTags.isNotEmpty) {
      return coverUrl(item.id,
          type: 'Backdrop',
          index: 0,
          maxWidth: maxWidth,
          quality: quality,
          tag: item.backdropTags.first);
    }

    // 4) 最后兜底 Thumb（无 tag）
    return coverUrl(item.id,
        type: 'Thumb', maxWidth: maxWidth, quality: quality);
  }

  List<String> imageUrlCandidates(String itemId,
      {int maxWidth = 2048, int quality = 95}) {
    final c = <String>[
      coverUrl(itemId, type: 'Primary', maxWidth: maxWidth, quality: quality),
      coverUrl(itemId, type: 'Thumb', maxWidth: maxWidth, quality: quality),
      coverUrl(itemId,
          type: 'Backdrop', index: 0, maxWidth: maxWidth, quality: quality),
    ];
    final out = <String>[];
    for (final u in c) {
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  /// 生成 Emby 视频播放地址。
  ///
  /// 说明：
  /// - 额外携带 `name`（文件名）是为了让播放器标题能显示“真实媒体名”，
  ///   避免 UI 左上角出现 stream/stream.mp4 这种无意义文本。
  /// - 这是纯客户端参数，不影响 Emby 服务端解析。
  String streamUrl(
    String itemId, {
    String? name,
    String? deviceId,
    String deviceName = 'Flutter',
    String? mediaSourceId,
  }) {
    final msId = (mediaSourceId ?? '').trim();
    final did = (deviceId ?? 'flutter_client').trim();
    final uri = _u('/Videos/$itemId/stream', {
      'static': 'true',
      'api_key': account.apiKey,
      'X-Emby-Token': account.apiKey,
      'UserId': account.userId,
      if (did.isNotEmpty) 'DeviceId': did,
      'DeviceName': deviceName,
      if (msId.isNotEmpty) 'MediaSourceId': msId,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    });
    return uri.toString();
  }
}

/// =========================
/// Emby account management page
/// =========================

class EmbyPage extends StatefulWidget {
  const EmbyPage({super.key});
  static Route routeNoAnim() => _noAnimRoute(const EmbyPage());
  @override
  State<EmbyPage> createState() => _EmbyPageState();
}

class _EmbyPageState extends State<EmbyPage> {
  bool _loading = true;
  bool _reloading = false;
  Object? _loadError;
  List<EmbyAccount> _list = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_reloading) return;
    _reloading = true;
    setState(() => _loading = true);
    try {
      final list = await EmbyStore.load();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
      showAppToast(context, friendlyErrorMessage(e), error: true);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _save() async => EmbyStore.save(_list);

  Future<void> _addOrEdit({EmbyAccount? existing}) async {
    final isEdit = existing != null;

    final nameC = TextEditingController(text: existing?.name ?? 'Emby');
    final urlC = TextEditingController(text: existing?.serverUrl ?? '');
    final userNameC = TextEditingController(text: existing?.username ?? '');
    final pwC = TextEditingController(text: existing?.password ?? '');

    bool loggingIn = false;
    String? loginErr;

    String tmpUserId = existing?.userId ?? '';
    String tmpToken = existing?.apiKey ?? '';

    Future<void> doLogin(StateSetter setState) async {
      var url = urlC.text.trim();
      while (url.endsWith('/')) url = url.substring(0, url.length - 1);

      final uname = userNameC.text.trim();
      final pw = pwC.text;

      if (url.isEmpty || uname.isEmpty || pw.isEmpty) {
        setState(() => loginErr = 'Server URL / 用户名 / 密码 不能为空');
        return;
      }

      setState(() {
        loggingIn = true;
        loginErr = null;
      });

      try {
        final temp = EmbyAccount(
          id: existing?.id ?? 'tmp',
          name: nameC.text.trim().isEmpty ? 'Emby' : nameC.text.trim(),
          serverUrl: url,
          username: uname,
          userId: '',
          apiKey: '',
        );

        final client = EmbyClient(temp);
        final deviceId = await EmbyStore.getOrCreateDeviceId();
        final r = await client.loginByName(
            username: uname, password: pw, deviceId: deviceId);

        tmpUserId = r.userId;
        tmpToken = r.accessToken;

        if (!mounted) return;
        showAppToast(context, '登录成功：${r.userName}');
      } catch (e) {
        setState(() => loginErr = e.toString());
      } finally {
        setState(() => loggingIn = false);
      }
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(isEdit ? '编辑 Emby' : '添加 Emby'),
          content: SizedBox(
            width: isCompactWidth(context) ? double.maxFinite : 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                      controller: nameC,
                      decoration: const InputDecoration(labelText: '名称')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlC,
                    decoration: const InputDecoration(
                        labelText:
                            'Server URL (如 http://host:8096 或 http://host:8096/emby)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                      controller: userNameC,
                      decoration: const InputDecoration(labelText: '用户名')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: pwC,
                    decoration: const InputDecoration(labelText: '密码'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: loggingIn ? null : () => doLogin(setState),
                          icon: loggingIn
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.login),
                          label: Text(loggingIn ? '正在登录…' : '登录验证'),
                        ),
                      ),
                    ],
                  ),
                  if (loginErr != null) ...[
                    const SizedBox(height: 10),
                    Text(loginErr!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: loggingIn ? null : () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final name = nameC.text.trim().isEmpty ? 'Emby' : nameC.text.trim();
    var url = urlC.text.trim();
    while (url.endsWith('/')) url = url.substring(0, url.length - 1);
    final username = userNameC.text.trim();

    String userId = tmpUserId.trim();
    String token = tmpToken.trim();

    if (userId.isEmpty || token.isEmpty) {
      final pw = pwC.text;
      if (url.isEmpty || username.isEmpty || pw.isEmpty) {
        if (!mounted) return;
        showAppToast(context, '请先填写完整并登录', error: true);
        return;
      }
      try {
        final tmp = EmbyAccount(
            id: 'tmp',
            name: name,
            serverUrl: url,
            username: username,
            userId: '',
            apiKey: '');
        final client = EmbyClient(tmp);
        final deviceId = await EmbyStore.getOrCreateDeviceId();
        final r = await client.loginByName(
            username: username, password: pw, deviceId: deviceId);
        userId = r.userId;
        token = r.accessToken;
      } catch (e) {
        if (!mounted) return;
        showAppToast(context, '自动登录失败：${friendlyErrorMessage(e)}', error: true);
        return;
      }
    }

    if (!EmbyClient.isGuid(userId)) {
      if (!mounted) return;
      showAppToast(context, '无效的 UserId，请重试', error: true);
      return;
    }

    try {
      final probe = EmbyAccount(
        id: existing?.id ?? 'probe',
        name: name,
        serverUrl: url,
        username: username,
        userId: userId,
        apiKey: token,
      );
      await EmbyClient(probe).validateToken();
      int favCount = 0;
      try {
        final fav = await EmbyClient(probe).listFavorites();
        favCount = fav.length;
      } catch (_) {}
      if (!mounted) return;
      showAppToast(context, '连接测试通过：鉴权正常 · 收藏 $favCount 条');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '连接测试失败：${friendlyErrorMessage(e)}', error: true);
      return;
    }

    setState(() {
      if (isEdit) {
        existing!.name = name;
        existing.serverUrl = url;
        existing.username = username;
        existing.userId = userId;
        existing.apiKey = token;
      } else {
        _list.add(
          EmbyAccount(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: name,
            serverUrl: url,
            username: username,
            userId: userId,
            apiKey: token,
          ),
        );
      }
    });

    await _save();
    if (!mounted) return;
    showAppToast(context, '已保存');
  }

  Future<void> _remove(EmbyAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Emby'),
        content: Text('确定删除「${a.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _list.removeWhere((x) => x.id == a.id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: Scaffold(
        appBar: GlassAppBar(
        title: const Text('Emby 账号'),
        actions: [
          IconButton(
              onPressed: () => _addOrEdit(),
              tooltip: '添加',
              icon: const Icon(Icons.add)),
          IconButton(
              onPressed: _reloading ? null : _reload,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const AppLoadingState()
          : _loadError != null
              ? AppErrorState(
                  title: '加载 Emby 配置失败',
                  details: friendlyErrorMessage(_loadError!),
                  onRetry: _reload,
                )
              : (_list.isEmpty
                  ? const AppEmptyState(
                      title: '还没有 Emby 配置',
                      subtitle: '点击右上角添加账号',
                      icon: Icons.video_library_outlined,
                    )
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: AppViewport(
                        child: ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _list.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final a = _list[i];
                            return Card(
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                              child: ListTile(
                                title: Text(a.name),
                                subtitle: Text(
                                  '${a.serverUrl}\n用户: ${a.username}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                isThreeLine: true,
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _addOrEdit(existing: a);
                                    if (v == 'del') _remove(a);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'edit', child: Text('编辑')),
                                    PopupMenuItem(
                                        value: 'del', child: Text('删除')),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    )),
      ),
    );
  }
}

class EmbyPickSourcePage extends StatelessWidget {
  const EmbyPickSourcePage({super.key});
  static Future<String?> pick(BuildContext context) async {
    return Navigator.push<String>(
        context, _noAnimRoute(const EmbyPickSourcePage()));
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: FutureBuilder<List<EmbyAccount>>(
        future: EmbyStore.load(),
        builder: (_, snap) {
        final accs = snap.data ?? [];
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: AppLoadingState());
        }
        if (accs.isEmpty) {
          return Scaffold(
            appBar: GlassAppBar(title: const Text('选择 Emby')),
            body: const AppEmptyState(
              title: '还没有 Emby 配置',
              subtitle: '请先返回添加账号',
              icon: Icons.video_library_outlined,
            ),
          );
        }
        return Scaffold(
          appBar: GlassAppBar(title: const Text('选择 Emby')),
          body: AppViewport(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: accs.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.collections_bookmark_outlined),
                      title: const Text('所有收藏集（合并）'),
                      subtitle: const Text('合并所有已登录账号的收藏'),
                      onTap: () =>
                          Navigator.pop(context, 'emby://all/favorites'),
                    ),
                  );
                }
                final a = accs[i - 1];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.video_library_outlined),
                    title: Text(a.name),
                    subtitle: Text(a.serverUrl,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () =>
                        Navigator.pop(context, 'emby://${a.id}/favorites'),
                  ),
                );
              },
            ),
          ),
        );
        },
      ),
    );
  }
}

Route<T> _noAnimRoute<T>(Widget child) {
  return PageRouteBuilder<T>(
    pageBuilder: (_, __, ___) => child,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}
