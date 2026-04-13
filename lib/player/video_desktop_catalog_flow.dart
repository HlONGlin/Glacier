part of '../video.dart';

extension _DesktopVideoCatalogFlow on _VideoPlayerPageState {
  Future<List<Media>> _buildMedias() async {
    final out = <Media>[];
    final accountCache = await (_webDavAccountCacheFuture ??
        Future.value(<String, Map<String, String>>{}));
    final embyAccs = await EmbyStore.load();
    final embyAccMap = {for (final a in embyAccs) a.id: a};

    for (int i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (isWebDavSource(s)) {
        final media = await _createWebDavMediaAsync(s, accountCache);
        if (media != null) {
          out.add(media);
        } else {
          debugPrint('WebDAV source failed: $s');
          out.add(Media('error://load_failed_placeholder_$i'));
        }
      } else if (isEmbySource(s)) {
        final media = await _createEmbyMediaAsync(
          s,
          embyAccMap,
          prefetchPlaybackInfo: i == _index,
        );
        if (media != null) {
          out.add(media);
        } else {
          debugPrint('Emby source failed: $s');
          out.add(Media('error://emby_failed_placeholder_$i'));
        }
      } else {
        out.add(Media(s));
      }
    }
    if (out.isEmpty && _sources.isNotEmpty) {
      return [Media('error://all_sources_failed')];
    }
    return out;
  }

  Future<int?> _showDesktopCatalogPicker({bool fromHotspot = false}) async {
    if (!_canOpenCatalogPopup) return null;
    _pokeUI();
    _pageController.setDesktopCatalogOpen(true);
    try {
      if (_sources.length <= 1 && !_sourcesExpandedOnce) {
        await _runWithBusyDialog(
          () => _ensureCatalogSourcesReady(),
          message:
              PlayerUiTextService.catalogLoadingMessage(initialExpansion: true),
        );
      }

      _prefetchCatalogThumbsAround(_index);

      if (_isMobile) {
        return _showCatalogBottomSheetMobile();
      }
      return _showCatalogSidePanelDesktop();
    } catch (e) {
      _showDesktopErrorSnack('目录打开失败：${redactSensitiveText(e.toString())}');
      return null;
    } finally {
      if (mounted) {
        _pageController.setDesktopCatalogOpen(false);
      }
    }
  }
}
