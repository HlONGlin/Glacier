import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart';

import '../core/utils/app_shared.dart';
import '../webdav.dart';

class ThumbnailInspector {
  /// 在收藏夹长按菜单调用：检查后把“为什么没有封面/缩略图”用弹窗告诉用户。
  ///
  /// 说明：
  /// - 本地图片：本身就是封面源，通常不会“生成失败”
  /// - 本地视频：检查列表缩略图缓存是否存在；若不存在，做一次“干跑抽帧”来捕获错误原因（不落盘）
  /// - WebDAV：当前层拿不到鉴权与真实下载地址，无法直接抽帧；会提示用户先让其落地缓存
  static Future<void> inspectAndExplain(
    BuildContext context, {
    required String name,
    required bool isWebDav,
    String? localPath,
    String? wdHref,
    String? wdAccountId,
    String? wdRelPath,
  }) async {
    if (!context.mounted) return;
    Future<void> safeShow(List<String> lines, {String title = '封面检查结果'}) async {
      if (!context.mounted) return;
      await _showDialog(context, title: title, lines: lines);
    }

    // WebDAV：Android 上可以通过 WebDavClient 下载到临时缓存，再用本地抽帧检查原因。
    if (isWebDav) {
      final lines = <String>[
        '类型：WebDAV',
        '文件：$name',
        if (wdRelPath != null && wdRelPath.trim().isNotEmpty) '路径：$wdRelPath',
        if (wdHref != null && wdHref.trim().isNotEmpty) 'Href：$wdHref',
      ];

      if (wdAccountId == null || wdAccountId.trim().isEmpty) {
        lines.add('原因：缺少 wdAccountId，无法获取鉴权信息。');
        await safeShow(lines);
        return;
      }

      final ext = p.extension(name).toLowerCase();
      final isImg = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'}
          .contains(ext);
      final isVid = <String>{
        '.mp4',
        '.mkv',
        '.mov',
        '.avi',
        '.wmv',
        '.flv',
        '.webm',
        '.m4v'
      }.contains(ext);

      if (isImg) {
        lines.add('类型：图片');
        lines.add('结论：图片本身就是封面源，不需要抽帧生成。');
        await safeShow(lines);
        return;
      }
      if (!isVid) {
        lines.add('类型：其它文件');
        lines.add('原因：当前仅支持 图片/视频 的封面检查。');
        await safeShow(lines);
        return;
      }

      try {
        if (!WebDavManager.instance.isLoaded) {
          await WebDavManager.instance.reload(notify: false);
        }
        final acc = WebDavManager.instance.accountsMap[wdAccountId.trim()];
        if (acc == null) {
          lines.add('原因：WebDAV 账号不存在/已删除：$wdAccountId');
          await safeShow(lines);
          return;
        }
        final client = WebDavClient(acc);

        final wdHrefTrimmed = wdHref?.trim() ?? '';
        final wdRelPathTrimmed = wdRelPath?.trim() ?? '';

        final href = wdHrefTrimmed.isNotEmpty
            ? wdHrefTrimmed
            : (wdRelPathTrimmed.isNotEmpty
                ? client.resolveRel(wdRelPathTrimmed).toString()
                : '');

        if (href.trim().isEmpty) {
          lines.add('原因：缺少 href/relPath，无法下载检查。');
          await safeShow(lines);
          return;
        }

        lines.add('步骤：下载到临时缓存（优先使用已缓存文件）');

        File? cachedFull;
        try {
          // 这里可以使用新的 WebDavFileCache，也可以保留原有的逻辑
          // 为了兼容你现有的 webdav.dart，这里暂时保留 client 调用
          cachedFull = await client.cacheFileForHref(href, suggestedName: name);
          if (await cachedFull.exists() && await cachedFull.length() > 0) {
            lines.add('✅ 已存在本地缓存：${cachedFull.path}');
          } else {
            cachedFull = null;
          }
        } catch (_) {
          cachedFull = null;
        }

        File? localForThumb = cachedFull;
        if (localForThumb == null) {
          try {
            final part = await client.ensureCachedForThumb(href, name,
                maxBytes: 4 * 1024 * 1024);
            if (await part.exists() && await part.length() > 0) {
              localForThumb = part;
              lines.add('✅ 已下载前缀缓存：${part.path}');
            }
          } catch (e) {
            lines.add('⚠️ 前缀下载失败：$e');
          }
        }

        if (localForThumb == null) {
          lines.add('原因：下载失败，无法进行本地抽帧。');
          await safeShow(lines);
          return;
        }

        // 🟢 修复点 1：使用 _checkExistingCache 替代 getCachedVideoThumb
        final cachedThumb = await _checkExistingCache(localForThumb.path);
        if (cachedThumb != null) {
          lines.add('✅ 已存在列表缩略图缓存：${cachedThumb.path}');
          lines.add('结论：封面已生成过；若仍看到占位图，可能是 UI 未刷新或缓存 key 变化。');
          await safeShow(lines);
          return;
        }

        lines.add('⚠️ 列表缩略图缓存不存在，开始抽帧测试…');

        try {
          final data = await VideoThumbnail.thumbnailData(
            video: localForThumb.path,
            imageFormat: ImageFormat.JPEG,
            timeMs: 1000,
            quality: 80,
            maxWidth: 512,
          );
          if (data == null || data.isEmpty) {
            lines.add('原因：抽帧返回空数据（thumbnailData 为 null 或空）。');
            lines.add('可能原因：视频损坏/不含关键帧/解码器不支持。');
          } else {
            lines.add('✅ 抽帧测试成功（得到 ${data.length} bytes）。');
            lines.add('结论：生成能力正常；缺封面多半是“未触发生成/缓存被清理”。');

            // 🟢 修复点 2：调用新的生成 API
            final out = await ThumbCache.getOrCreateVideoPreviewFrame(
              localForThumb.path,
              const Duration(seconds: 1), // 这里的 1s 对应上面的 timeMs: 1000
            );
            if (out != null) lines.add('✅ 已写入封面缓存：${out.path}');
          }
        } catch (e) {
          lines.add('原因：抽帧抛异常');
          lines.add('异常：$e');
        }

        await safeShow(lines);
        return;
      } catch (e) {
        lines.add('原因：WebDAV 检查流程异常');
        lines.add('异常：$e');
        await safeShow(lines);
        return;
      }
    }

    if (localPath == null || localPath.trim().isEmpty) {
      await safeShow(const <String>['原因：本地路径为空（localPath 为空），无法检查/生成封面。']);
      return;
    }

    final lp = localPath.trim();
    final f = File(lp);
    if (!await f.exists()) {
      await safeShow(<String>['原因：文件不存在', '路径：$lp']);
      return;
    }

    final len = await f.length();
    if (len <= 0) {
      await safeShow(<String>['原因：文件大小为 0（空文件）', '路径：$lp']);
      return;
    }

    final ext = p.extension(lp).toLowerCase();
    final isImg = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'}
        .contains(ext);
    final isVid = <String>{
      '.mp4',
      '.mkv',
      '.mov',
      '.avi',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v'
    }.contains(ext);

    final lines = <String>[];
    lines.add('文件：$name');
    lines.add('路径：$lp');
    lines.add('大小：$len bytes');
    lines.add('后缀：$ext');

    if (isImg) {
      lines.add('类型：图片');
      lines.add('结论：图片本身就是封面源，不需要抽帧生成封面。');
      await safeShow(lines);
      return;
    }

    if (!isVid) {
      lines.add('类型：其它文件');
      lines.add('原因：当前仅支持 图片/视频 的封面检查。');
      await safeShow(lines);
      return;
    }

    // 视频：先看列表缩略图缓存（VideoThumbImage 使用）
    lines.add('类型：视频');

    // 🟢 修复点 3：使用 _checkExistingCache 替代 getCachedVideoThumb
    File? cached = await _checkExistingCache(lp);
    if (cached != null) {
      lines.add('✅ 已存在列表缩略图缓存：${cached.path}');
      lines.add('结论：列表封面已经生成过。若你仍看到占位图，可能是 UI 未刷新或路径变化导致缓存 key 变化。');
      await safeShow(lines);
      return;
    }

    lines.add('⚠️ 列表缩略图缓存不存在（可能：从未生成/生成失败/缓存被系统清理）');

    // 做一次“干跑抽帧”来获取失败原因（不写文件）
    try {
      final data = await VideoThumbnail.thumbnailData(
        video: lp,
        imageFormat: ImageFormat.JPEG,
        timeMs: 1000,
        quality: 80,
        maxWidth: 512,
      );

      if (data == null || data.isEmpty) {
        lines.add('原因：抽帧返回空数据（thumbnailData 为 null 或空）。');
        lines.add('可能原因：视频损坏/不含关键帧/解码器不支持/权限或路径问题。');
      } else {
        lines.add('✅ 抽帧测试成功（得到 ${data.length} bytes）。');
        lines.add('结论：生成能力正常；缺封面多数是“缓存未写入或被清理”。可尝试重新进入列表触发生成。');
      }
    } catch (e) {
      lines.add('原因：抽帧抛异常');
      lines.add('异常：$e');
      lines.add('提示：常见是编码格式不支持、视频文件损坏、或 Android 端缺少解码能力。');
    }

    await safeShow(lines);
  }

  /// 🟢 新增：手动检查持久化存储中是否存在缩略图
  /// 模拟 `utils.dart` 中 ThumbCache 的 key 生成逻辑
  static Future<File?> _checkExistingCache(String videoPath) async {
    // 假设列表页默认使用：
    // pos = 0ms (Duration.zero)
    // width = 320, height = 180
    // 如果你的列表页逻辑变了，这里也要相应调整才能匹配到 key
    const posMs = 0;
    const width = 320;
    const height = 180;

    // 生成 Key (与 utils.dart 保持一致)
    final keyStr = '$videoPath|$posMs|$width|$height';
    final key = PersistentStore.instance.makeKey(keyStr);

    // 查询文件
    final file = await PersistentStore.instance.getFile(key, 'thumbs', '.jpg');
    if (await file.exists() && await file.length() > 0) {
      return file;
    }
    return null;
  }

  static Future<void> _showDialog(
    BuildContext context, {
    required String title,
    required List<String> lines,
  }) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: Text(lines.join('\n'))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
        ],
      ),
    );
  }
}
