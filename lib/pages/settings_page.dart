part of '../pages.dart';

/// =========================
/// SettingsPage (新：应用设置)
/// =========================
/// 设计目标：
/// - 提供更完整的“交互/字幕/历史/收藏夹”设置。
/// - 只做“必要字段”的持久化，避免侵入式重构。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;
  bool _busyDataAction = false;
  int _mediaCacheLimitMb = 512;
  int _doubleTapSeekSeconds = 10;
  String _themeMode = 'light';

  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;
  double _subtitleBackgroundOpacity = 0.55;
  bool _subtitleOutlineEnabled = true;

  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  bool _videoMiniProgressWhenHidden = true;
  bool _videoAutoNextAfterEnd = false;
  bool _videoCatalogEnabled = true;
  bool _videoEpisodeNavButtonsEnabled = true;
  bool _videoLockPauseSeekEnabled = true;
  bool _videoCatalogLocateCurrentOnOpen = true;
  bool _embyImageLibrarySimpleModeEnabled = true;
  int _embyImageDominantThresholdPercent = 67;
  bool _videoResumeEnabled = true;
  bool _videoResumeHintEnabled = true;
  bool _imageVolumeKeyPaging = false;
  bool _imageExitLocateEnabled = true;

  bool _autoEnterLastFavorite = false;
  bool _favoritePerDirectoryDisplaySettingsEnabled = false;
  bool _embyExclusiveFavoritesUiEnabled = false;
  bool _embyContentDeletionEnabled = false;

  bool _historyEnabled = true;
  bool _tagEnabled = true;

  SystemUiOverlayStyle get _statusBarStyle => _themeMode == 'dark'
      ? const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        )
      : _kDarkStatusBarStyle;

  void _onAppSettingsChanged() {
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onAppSettingsChanged);
    _load();
    _loadCacheLimit();
  }

  Future<void> _loadCacheLimit() async {
    final limit = await AppSettings.getMediaCacheLimitMb();
    if (mounted) setState(() => _mediaCacheLimitMb = limit);
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        AppSettings.getSubtitleFontSize(),
        AppSettings.getSubtitleBottomOffset(),
        AppSettings.getSubtitleBackgroundOpacity(),
        AppSettings.getSubtitleOutlineEnabled(),
        AppSettings.getLongPressSpeedEnabled(),
        AppSettings.getLongPressSpeedMultiplier(),
        AppSettings.getVideoMiniProgressWhenHidden(),
        AppSettings.getVideoCatalogEnabled(),
        AppSettings.getVideoEpisodeNavButtonsEnabled(),
        AppSettings.getVideoLockPauseSeekEnabled(),
        AppSettings.getVideoCatalogLocateCurrentOnOpen(),
        AppSettings.getEmbyImageDominantThresholdPercent(),
        AppSettings.getEmbyImageLibrarySimpleModeEnabled(),
        AppSettings.getVideoResumeEnabled(),
        AppSettings.getVideoResumeHintEnabled(),
        AppSettings.getImageVolumeKeyPaging(),
        AppSettings.getImageExitLocateEnabled(),
        AppSettings.getAutoEnterLastFavorite(),
        AppSettings.getFavoritePerDirectoryDisplaySettingsEnabled(),
        AppSettings.getEmbyExclusiveFavoritesUiEnabled(),
        AppSettings.getEmbyContentDeletionEnabled(),
        AppSettings.getHistoryEnabled(),
        AppSettings.getTagEnabled(),
        AppSettings.getDoubleTapSeekSeconds(),
        AppSettings.getThemeMode(),
        AppSettings.getVideoAutoNextAfterEnd(),
      ]);

      final font = values[0] as double;
      final bottom = values[1] as double;
      final bgOpacity = values[2] as double;
      final outlineEnabled = values[3] as bool;
      final lpEnabled = values[4] as bool;
      final lpMul = values[5] as double;
      final miniProgress = values[6] as bool;
      final catalogEnabled = values[7] as bool;
      final episodeNavEnabled = values[8] as bool;
      final lockPauseSeekEnabled = values[9] as bool;
      final locateCurrentOnOpen = values[10] as bool;
      final imageDominantThreshold = values[11] as int;
      final imageLibrarySimpleMode = values[12] as bool;
      final videoResumeEnabled = values[13] as bool;
      final videoResumeHint = values[14] as bool;
      final imageVolumePaging = values[15] as bool;
      final imageExitLocate = values[16] as bool;
      final autoFav = values[17] as bool;
      final perDirDisplay = values[18] as bool;
      final embyExclusiveFavoritesUiEnabled = values[19] as bool;
      final embyContentDeletionEnabled = values[20] as bool;
      final his = values[21] as bool;
      final tagEnabled = values[22] as bool;
      final seekSeconds = values[23] as int;
      final themeMode = values[24] as String;
      final autoNext = values[25] as bool;

      if (!mounted) return;
      setState(() {
        _subtitleFontSize = font;
        _subtitleBottomOffset = bottom;
        _subtitleBackgroundOpacity = bgOpacity.clamp(0.0, 1.0);
        _subtitleOutlineEnabled = outlineEnabled;
        _longPressSpeedEnabled = lpEnabled;
        _longPressSpeedMultiplier = lpMul;
        _videoMiniProgressWhenHidden = miniProgress;
        _videoCatalogEnabled = catalogEnabled;
        _videoEpisodeNavButtonsEnabled = episodeNavEnabled;
        _videoLockPauseSeekEnabled = lockPauseSeekEnabled;
        _videoCatalogLocateCurrentOnOpen = locateCurrentOnOpen;
        _embyImageLibrarySimpleModeEnabled = imageLibrarySimpleMode;
        _embyImageDominantThresholdPercent = imageDominantThreshold;
        _videoResumeEnabled = videoResumeEnabled;
        _videoResumeHintEnabled = videoResumeHint;
        _imageVolumeKeyPaging = imageVolumePaging;
        _imageExitLocateEnabled = imageExitLocate;
        _autoEnterLastFavorite = autoFav;
        _favoritePerDirectoryDisplaySettingsEnabled = perDirDisplay;
        _embyExclusiveFavoritesUiEnabled = embyExclusiveFavoritesUiEnabled;
        _embyContentDeletionEnabled = embyContentDeletionEnabled;
        _historyEnabled = his;
        _tagEnabled = tagEnabled;
        _doubleTapSeekSeconds = seekSeconds;
        _themeMode = themeMode;
        _videoAutoNextAfterEnd = autoNext;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _exportLogs() async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出应用日志',
        fileName: 'glacier.log',
        bytes: Uint8List.fromList(utf8.encode(await AppLogger.readLogs())),
      );
      if (path != null && mounted) showAppToast(context, '日志已导出');
    } catch (error, stackTrace) {
      AppLogger.error('log export failed',
          error: error, stackTrace: stackTrace, tag: 'settings');
      if (mounted) {
        showAppToast(context, '日志导出失败：${friendlyErrorMessage(error)}',
            error: true);
      }
    }
  }

  Future<void> _exportBackup() async {
    final passwordController = TextEditingController();
    var includeCredentials = false;
    final include = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('导出备份'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: includeCredentials,
                title: const Text('包含账号凭据'),
                subtitle: const Text('使用口令加密后写入备份'),
                onChanged: (value) =>
                    setDialogState(() => includeCredentials = value ?? false),
              ),
              if (includeCredentials)
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '备份口令（至少 8 位）'),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('继续')),
          ],
        ),
      ),
    );
    if (include != true) {
      passwordController.dispose();
      return;
    }
    setState(() => _busyDataAction = true);
    try {
      final json = await AppBackup.export(
        credentialPassword: includeCredentials ? passwordController.text : null,
      );
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: '保存 Glacier 备份',
        fileName: 'glacier-backup.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      if (saved != null && mounted) showAppToast(context, '备份已导出');
    } catch (error, stackTrace) {
      AppLogger.error('backup export failed',
          error: error, stackTrace: stackTrace, tag: 'settings');
      if (mounted) {
        showAppToast(context, '备份导出失败：${friendlyErrorMessage(error)}',
            error: true);
      }
    } finally {
      passwordController.dispose();
      if (mounted) setState(() => _busyDataAction = false);
    }
  }

  Future<String?> _askBackupPassword() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入备份口令'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: '备份口令'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('解密')),
        ],
      ),
    );
    controller.dispose();
    return password;
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Glacier 备份',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file?.bytes == null) return;
    if (!mounted) return;
    final ok = await _confirm(
      context,
      title: '恢复备份',
      message: '恢复会替换当前账号、收藏、标签和应用设置。建议先导出当前数据。',
    );
    if (!ok) return;
    setState(() => _busyDataAction = true);
    try {
      final raw = utf8.decode(file!.bytes!);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final data = envelope['data'] as Map<String, dynamic>?;
      final encrypted = data?.containsKey('credentialBundle') ?? false;
      final password = encrypted ? await _askBackupPassword() : null;
      if (encrypted && password == null) return;
      await AppBackup.restore(raw, credentialPassword: password);
      await _load();
      if (mounted) showAppToast(context, '备份已恢复');
    } catch (error, stackTrace) {
      AppLogger.error('backup import failed',
          error: error, stackTrace: stackTrace, tag: 'settings');
      if (mounted) {
        showAppToast(context, '备份恢复失败：${friendlyErrorMessage(error)}',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _busyDataAction = false);
    }
  }

  Future<void> _showCacheUsage() async {
    try {
      final usage = await TagThumbCache.cacheBytesByCategory();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('媒体缓存'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  '总占用 ${_formatBytes(usage.values.fold<int>(0, (a, b) => a + b))}，上限 $_mediaCacheLimitMb MB'),
              _cacheCategoryTile(
                  dialogContext, 'thumbnails', '缩略图', usage['thumbnails'] ?? 0),
              _cacheCategoryTile(
                  dialogContext, 'webdav', 'WebDAV 文件缓存', usage['webdav'] ?? 0),
              _cacheCategoryTile(dialogContext, 'networkImages', '网络图片缓存',
                  usage['networkImages'] ?? 0),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
            TextButton.icon(
              onPressed: () async {
                await TagThumbCache.clearCache();
                await DefaultCacheManager().emptyCache();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) showAppToast(context, '媒体缓存已清理');
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('全部清理'),
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.error('media cache cleanup failed',
          error: error, stackTrace: stackTrace, tag: 'settings');
      if (mounted) {
        showAppToast(context, '缓存清理失败：${friendlyErrorMessage(error)}',
            error: true);
      }
    }
  }

  Widget _cacheCategoryTile(
    BuildContext dialogContext,
    String key,
    String title,
    int bytes,
  ) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(_formatBytes(bytes)),
      trailing: IconButton(
        tooltip: '清理$title',
        icon: const Icon(Icons.delete_outline),
        onPressed: bytes == 0
            ? null
            : () async {
                await TagThumbCache.clearCacheCategory(key);
                if (key == 'networkImages') {
                  await DefaultCacheManager().emptyCache();
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  showAppToast(context, '$title已清理，请重新打开缓存查看用量');
                }
              },
      ),
    );
  }

  Future<void> _showAppInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: info.appName,
      applicationVersion: '${info.version} (${info.buildNumber})',
      applicationLegalese: 'Glacier',
    );
  }

  Future<void> _showOfflineDownloads() async {
    var downloads = await OfflineDownloadStore.load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('下载与离线文件'),
          content: SizedBox(
            width: 480,
            child: downloads.isEmpty
                ? const Text('还没有由应用下载的文件。')
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: downloads.length,
                      itemBuilder: (context, index) {
                        final item = downloads[index];
                        final exists = File(item.path).existsSync();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(exists
                              ? Icons.offline_pin_outlined
                              : Icons.cloud_off_outlined),
                          title: Text(item.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              exists
                                  ? '${_formatBytes(item.size)} · ${item.path}'
                                  : '文件已不存在 · ${item.path}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          trailing: PopupMenuButton<String>(
                            tooltip: '管理下载',
                            onSelected: (action) async {
                              if (action == 'delete') {
                                final confirmed = await _confirm(
                                  dialogContext,
                                  title: '删除离线文件',
                                  message: '将从设备中永久删除“${item.name}”。',
                                );
                                if (!confirmed) return;
                              }
                              await OfflineDownloadStore.remove(
                                item.path,
                                deleteFile: action == 'delete',
                              );
                              final refreshed =
                                  await OfflineDownloadStore.load();
                              if (dialogContext.mounted) {
                                setDialogState(() => downloads = refreshed);
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'record',
                                child: Text('移除记录'),
                              ),
                              if (exists)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除本地文件'),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resetSettings() async {
    final confirmed = await _confirm(
      context,
      title: '恢复默认设置',
      message: '仅恢复应用偏好设置，不会删除账号、收藏、历史记录或下载文件。',
    );
    if (!confirmed) return;
    await AppSettings.resetToDefaults();
    if (mounted) showAppToast(context, '已恢复默认设置');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: _statusBarStyle,
        child: const Scaffold(body: AppLoadingState()),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _statusBarStyle,
      child: Scaffold(
        appBar: const GlassAppBar(title: Text('设置')),
        body: AppViewport(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            children: [
              const _SettingsSectionTitle('外观与应用'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('主题模式'),
                subtitle: const Text('切换浅色或深色界面'),
                trailing: DropdownButton<String>(
                  value: _themeMode,
                  items: const [
                    DropdownMenuItem(value: 'light', child: Text('浅色')),
                    DropdownMenuItem(value: 'dark', child: Text('深色')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => _themeMode = value);
                    await AppSettings.setThemeMode(value);
                  },
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('应用信息'),
                subtitle: const Text('查看版本号和构建号'),
                trailing: const Icon(Icons.info_outline),
                onTap: _showAppInfo,
              ),
              const _SettingsSectionTitle('字幕'),
              _SettingsSliderTile(
                title: '字幕大小',
                subtitle: '调整字幕字号（建议 18~30 之间）',
                value: _subtitleFontSize,
                min: 12,
                max: 48,
                divisions: 36,
                valueText: _subtitleFontSize.toStringAsFixed(0),
                onChanged: (v) async {
                  setState(() => _subtitleFontSize = v);
                  await AppSettings.setSubtitleFontSize(v);
                },
              ),
              _SettingsSliderTile(
                title: '字幕位置（距底部）',
                subtitle: '避免遮挡画面关键区域',
                value: _subtitleBottomOffset,
                min: 0,
                max: 200,
                divisions: 40,
                valueText: _subtitleBottomOffset.toStringAsFixed(0),
                onChanged: (v) async {
                  setState(() => _subtitleBottomOffset = v);
                  await AppSettings.setSubtitleBottomOffset(v);
                },
              ),
              _SettingsSliderTile(
                title: '字幕背景透明度',
                subtitle: '调整字幕背景板深浅，0 为完全透明，1 为完全不透明',
                value: _subtitleBackgroundOpacity,
                min: 0,
                max: 1,
                divisions: 20,
                valueText: _subtitleBackgroundOpacity.toStringAsFixed(2),
                onChanged: (v) async {
                  setState(() => _subtitleBackgroundOpacity = v);
                  await AppSettings.setSubtitleBackgroundOpacity(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('字幕描边'),
                subtitle: const Text('开启后为字幕文字增加黑色描边，提升亮背景下可读性'),
                value: _subtitleOutlineEnabled,
                onChanged: (v) async {
                  setState(() => _subtitleOutlineEnabled = v);
                  await AppSettings.setSubtitleOutlineEnabled(v);
                },
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('交互'),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('单击唤出控制栏 / 双击播放暂停'),
                subtitle: Text('移动端采用主流观影播放器交互'),
              ),
              _SettingsSliderTile(
                title: '双击快进 / 快退时长',
                subtitle: '设置播放器左右区域双击跳转的秒数',
                value: _doubleTapSeekSeconds.toDouble(),
                min: 5,
                max: 60,
                divisions: 11,
                valueText: '$_doubleTapSeekSeconds 秒',
                onChanged: (value) async {
                  final seconds = (value / 5).round() * 5;
                  setState(() => _doubleTapSeekSeconds = seconds);
                  await AppSettings.setDoubleTapSeekSeconds(seconds);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('长按倍数播放'),
                subtitle: const Text('按住屏幕临时加速播放，松开恢复原倍速'),
                value: _longPressSpeedEnabled,
                onChanged: (v) async {
                  setState(() => _longPressSpeedEnabled = v);
                  await AppSettings.setLongPressSpeedEnabled(v);
                },
              ),
              if (_longPressSpeedEnabled)
                _SettingsSliderTile(
                  title: '长按倍速乘数',
                  subtitle: '最终倍速 = 当前倍速 × 乘数',
                  value: _longPressSpeedMultiplier,
                  min: 1.25,
                  max: 4.0,
                  divisions: 11,
                  valueText: _longPressSpeedMultiplier.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _longPressSpeedMultiplier = v);
                    await AppSettings.setLongPressSpeedMultiplier(v);
                  },
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('隐藏控制栏时显示底部细进度'),
                subtitle: const Text('关闭后全屏更干净，但无法看到当前进度'),
                value: _videoMiniProgressWhenHidden,
                onChanged: (v) async {
                  setState(() => _videoMiniProgressWhenHidden = v);
                  await AppSettings.setVideoMiniProgressWhenHidden(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示目录按钮'),
                subtitle: const Text('关闭后隐藏播放器目录入口，并禁用 L/Ctrl+L 与右上热区'),
                value: _videoCatalogEnabled,
                onChanged: (v) async {
                  setState(() => _videoCatalogEnabled = v);
                  await AppSettings.setVideoCatalogEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示上下集按钮'),
                subtitle: const Text('关闭后隐藏播放器底部的上一集/下一集按钮'),
                value: _videoEpisodeNavButtonsEnabled,
                onChanged: (v) async {
                  setState(() => _videoEpisodeNavButtonsEnabled = v);
                  await AppSettings.setVideoEpisodeNavButtonsEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放结束后自动播放下一集'),
                value: _videoAutoNextAfterEnd,
                onChanged: (value) async {
                  setState(() => _videoAutoNextAfterEnd = value);
                  await AppSettings.setVideoAutoNextAfterEnd(value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('锁定后允许手势快进/拖动'),
                subtitle: const Text('锁定状态下隐藏进度条，但保留双击快进和水平手势拖动'),
                value: _videoLockPauseSeekEnabled,
                onChanged: (v) async {
                  setState(() => _videoLockPauseSeekEnabled = v);
                  await AppSettings.setVideoLockPauseSeekEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('打开目录时定位当前播放项'),
                subtitle: const Text('展开目录后第一屏优先看到当前视频附近位置'),
                value: _videoCatalogLocateCurrentOnOpen,
                onChanged: (v) async {
                  setState(() => _videoCatalogLocateCurrentOnOpen = v);
                  await AppSettings.setVideoCatalogLocateCurrentOnOpen(v);
                },
              ),
              _SettingsSliderTile(
                title: 'Emby 图片主导阈值',
                subtitle: '混合库中图片占比达到该阈值时，默认优先目录/图片（50~90%）',
                value: _embyImageDominantThresholdPercent.toDouble(),
                min: 50,
                max: 90,
                divisions: 40,
                valueText:
                    '${_embyImageDominantThresholdPercent.toStringAsFixed(0)}%',
                onChanged: (v) async {
                  final next = v.round().clamp(50, 90);
                  setState(() => _embyImageDominantThresholdPercent = next);
                  await AppSettings.setEmbyImageDominantThresholdPercent(next);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Emby 图片库简化模式'),
                subtitle: const Text('目录优先、图片就近展示，减少递归全量带来的复杂感'),
                value: _embyImageLibrarySimpleModeEnabled,
                onChanged: (v) async {
                  setState(() => _embyImageLibrarySimpleModeEnabled = v);
                  await AppSettings.setEmbyImageLibrarySimpleModeEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('图片音量键翻页'),
                subtitle: const Text('开启后：音量+ 上一张，音量- 下一张（移动端可能受系统限制）'),
                value: _imageVolumeKeyPaging,
                onChanged: (v) async {
                  setState(() => _imageVolumeKeyPaging = v);
                  await AppSettings.setImageVolumeKeyPaging(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('退出图片后定位到最后浏览项'),
                subtitle: const Text('从图片查看器返回时，列表自动跳到你最后浏览的那张图'),
                value: _imageExitLocateEnabled,
                onChanged: (v) async {
                  setState(() => _imageExitLocateEnabled = v);
                  await AppSettings.setImageExitLocateEnabled(v);
                },
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('收藏夹'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启动后自动进入上次收藏夹'),
                subtitle: const Text('开启后，下次打开软件会自动进入你上次打开的收藏夹'),
                value: _autoEnterLastFavorite,
                onChanged: (v) async {
                  setState(() => _autoEnterLastFavorite = v);
                  await AppSettings.setAutoEnterLastFavorite(v);
                  if (!v) {
                    await AppSettings.setLastFavoriteId(null);
                  }
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('按目录独立记忆视图与排序'),
                subtitle:
                    const Text('开启后每个目录独立保存视图模式、排序方式和升降序（本地/WebDAV/Emby）'),
                value: _favoritePerDirectoryDisplaySettingsEnabled,
                onChanged: (v) async {
                  setState(
                      () => _favoritePerDirectoryDisplaySettingsEnabled = v);
                  await AppSettings
                      .setFavoritePerDirectoryDisplaySettingsEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 Emby 专用收藏夹 UI'),
                subtitle: const Text('启用后，点击含 Emby 来源的收藏夹时进入 Emby UI'),
                value: _embyExclusiveFavoritesUiEnabled,
                onChanged: (v) async {
                  setState(() => _embyExclusiveFavoritesUiEnabled = v);
                  await AppSettings.setEmbyExclusiveFavoritesUiEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('允许删除 Emby 媒体'),
                subtitle: const Text(
                    '默认关闭。开启后，仅在当前 Emby 账号有删除权限时显示删除操作，删除会直接作用于服务器。'),
                value: _embyContentDeletionEnabled,
                onChanged: (v) async {
                  setState(() => _embyContentDeletionEnabled = v);
                  await AppSettings.setEmbyContentDeletionEnabled(v);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: _embyExclusiveFavoritesUiEnabled,
                title: const Text('打开 Emby 专用收藏夹'),
                subtitle: Text(_embyExclusiveFavoritesUiEnabled
                    ? '传统 Emby 风格首页（深色分区）'
                    : '请先开启上方开关'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _embyExclusiveFavoritesUiEnabled
                    ? () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EmbyExclusiveFavoritesPage(
                              openFolder: (ctx,
                                  {required title, required source}) {
                                return openTagSourceAsFolder(ctx,
                                    title: title, source: source);
                              },
                              openSettings: (ctx) {
                                return Navigator.push(
                                  ctx,
                                  MaterialPageRoute(
                                      builder: (_) => const SettingsPage()),
                                );
                              },
                            ),
                          ),
                        )
                    : null,
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('历史记录'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('记录播放历史'),
                subtitle: const Text('关闭后不会新增历史记录（已有历史不会自动删除）'),
                value: _historyEnabled,
                onChanged: (v) async {
                  setState(() => _historyEnabled = v);
                  await AppSettings.setHistoryEnabled(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动从上次进度继续播放'),
                subtitle: const Text('关闭后每次都从头播放'),
                value: _videoResumeEnabled,
                onChanged: (v) async {
                  setState(() {
                    _videoResumeEnabled = v;
                    if (!v) _videoResumeHintEnabled = false;
                  });
                  await AppSettings.setVideoResumeEnabled(v);
                  if (!v) {
                    await AppSettings.setVideoResumeHintEnabled(false);
                  }
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示“继续播放”提示'),
                subtitle: const Text('关闭后仍会续播，但不显示“从 xx 继续播放”提示'),
                value: _videoResumeHintEnabled,
                onChanged: _videoResumeEnabled
                    ? (v) async {
                        setState(() => _videoResumeHintEnabled = v);
                        await AppSettings.setVideoResumeHintEnabled(v);
                      }
                    : null,
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('标签'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用标签功能'),
                subtitle: const Text('关闭后隐藏标签管理入口，并禁用长按打 Tag 与标签筛选'),
                value: _tagEnabled,
                onChanged: (v) async {
                  setState(() => _tagEnabled = v);
                  await AppSettings.setTagEnabled(v);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('清空历史记录'),
                subtitle: const Text('不可恢复，请谨慎操作'),
                trailing: const Icon(Icons.delete_outline),
                onTap: () async {
                  final ok = await _confirm(context,
                      title: '清空历史', message: '确定要清空全部历史记录吗？');
                  if (!ok) return;
                  await AppHistory.clear();
                  if (!context.mounted) return;
                  showAppToast(context, '已清空历史记录');
                },
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('数据与诊断'),
              ValueListenableBuilder<bool>(
                valueListenable: SecureStore.fallbackStatus,
                builder: (context, usingFallback, _) => usingFallback
                    ? const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.warning_amber_rounded,
                            color: Colors.deepOrange),
                        title: Text('凭据仅保存在内存中'),
                        subtitle: Text('安全存储不可用，应用重启后账号密码不会保留。'),
                      )
                    : const SizedBox.shrink(),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('导出账号、收藏与设置'),
                subtitle: const Text('账号凭据可选择使用口令加密'),
                trailing: const Icon(Icons.file_upload_outlined),
                onTap: _busyDataAction ? null : _exportBackup,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('恢复备份'),
                subtitle: const Text('从 Glacier JSON 备份恢复账号、收藏、标签和设置'),
                trailing: const Icon(Icons.file_download_outlined),
                onTap: _busyDataAction ? null : _importBackup,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('查看或导出应用日志'),
                subtitle: const Text('日志会自动隐藏账号令牌和密码'),
                trailing: const Icon(Icons.description_outlined),
                onTap: _exportLogs,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('清除应用日志'),
                trailing: const Icon(Icons.delete_outline),
                onTap: () async {
                  final ok = await _confirm(context,
                      title: '清除日志', message: '确定删除本地应用日志吗？');
                  if (!ok) return;
                  await AppLogger.clearLogs();
                  if (!context.mounted) return;
                  showAppToast(context, '日志已清除');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('媒体缓存'),
                subtitle: const Text('查看并分类清理缩略图、WebDAV 与网络图片缓存'),
                trailing: const Icon(Icons.cleaning_services_outlined),
                onTap: _showCacheUsage,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('下载与离线文件'),
                subtitle: const Text('查看应用下载的文件，移除记录或删除本地文件'),
                trailing: const Icon(Icons.folder_open_outlined),
                onTap: _showOfflineDownloads,
              ),
              _SettingsSliderTile(
                title: '媒体缓存上限',
                subtitle: '超出上限时自动清理较早使用的缓存文件',
                value: _mediaCacheLimitMb.toDouble(),
                min: 64,
                max: 2048,
                divisions: 31,
                valueText: '$_mediaCacheLimitMb MB',
                onChanged: (value) async {
                  final limit = (value / 64).round() * 64;
                  setState(() => _mediaCacheLimitMb = limit);
                  await AppSettings.setMediaCacheLimitMb(limit);
                  await TagThumbCache.enforceCacheLimit();
                },
              ),
              const SizedBox(height: 10),
              const _SettingsSectionTitle('应用设置'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('恢复默认设置'),
                subtitle: const Text('保留账号、收藏、历史记录和下载文件'),
                trailing: const Icon(Icons.settings_backup_restore),
                onTap: _resetSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  final String text;
  const _SettingsSectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

class _SettingsSliderTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueText;
  final ValueChanged<double> onChanged;

  const _SettingsSliderTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            Text(valueText,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: onChanged,
        ),
        const Divider(height: 10),
      ],
    );
  }
}
