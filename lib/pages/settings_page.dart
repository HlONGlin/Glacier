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

  double _subtitleFontSize = 22.0;
  double _subtitleBottomOffset = 36.0;

  bool _longPressSpeedEnabled = true;
  double _longPressSpeedMultiplier = 2.0;
  bool _videoMiniProgressWhenHidden = true;
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

  bool _historyEnabled = true;
  bool _tagEnabled = true;

  void _onAppSettingsChanged() {
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onAppSettingsChanged);
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        AppSettings.getSubtitleFontSize(),
        AppSettings.getSubtitleBottomOffset(),
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
        AppSettings.getHistoryEnabled(),
        AppSettings.getTagEnabled(),
      ]);

      final font = values[0] as double;
      final bottom = values[1] as double;
      final lpEnabled = values[2] as bool;
      final lpMul = values[3] as double;
      final miniProgress = values[4] as bool;
      final catalogEnabled = values[5] as bool;
      final episodeNavEnabled = values[6] as bool;
      final lockPauseSeekEnabled = values[7] as bool;
      final locateCurrentOnOpen = values[8] as bool;
      final imageDominantThreshold = values[9] as int;
      final imageLibrarySimpleMode = values[10] as bool;
      final videoResumeEnabled = values[11] as bool;
      final videoResumeHint = values[12] as bool;
      final imageVolumePaging = values[13] as bool;
      final imageExitLocate = values[14] as bool;
      final autoFav = values[15] as bool;
      final perDirDisplay = values[16] as bool;
      final embyExclusiveFavoritesUiEnabled = values[17] as bool;
      final his = values[18] as bool;
      final tagEnabled = values[19] as bool;

      if (!mounted) return;
      setState(() {
        _subtitleFontSize = font;
        _subtitleBottomOffset = bottom;
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
        _historyEnabled = his;
        _tagEnabled = tagEnabled;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AnnotatedRegion<SystemUiOverlayStyle>(
        value: _kDarkStatusBarStyle,
        child: Scaffold(body: AppLoadingState()),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _kDarkStatusBarStyle,
      child: Scaffold(
        appBar: const GlassAppBar(title: Text('设置')),
        body: AppViewport(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            children: [
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
              const SizedBox(height: 10),
              const _SettingsSectionTitle('交互'),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('单击唤出控制栏 / 双击播放暂停'),
                subtitle: Text('移动端采用主流观影播放器交互'),
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
