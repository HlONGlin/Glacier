part of '../video.dart';

extension _DesktopPlayerSurface on _VideoPlayerPageState {
  List<Widget> _buildDesktopPlayerOverlays(BuildContext context) {
    return <Widget>[
      if (_uiVisible || _isScreenLocked)
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: IconButton(
                      tooltip: '返回',
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () {
                        Navigator.pop(context);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (_isMobile && (_uiVisible || _isScreenLocked))
        Positioned(
          right: 10,
          top: MediaQuery.of(context).size.height * 0.40,
          child: SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(999),
              ),
              child: IconButton(
                tooltip: _isScreenLocked ? '已锁定方向' : '锁定方向',
                iconSize: 18,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: Icon(
                  _isScreenLocked ? Icons.lock : Icons.lock_open,
                  color: Colors.white,
                ),
                onPressed: _toggleScreenLock,
              ),
            ),
          ),
        ),
      Positioned(
        right: 0,
        top: 0,
        child: SafeArea(
          bottom: false,
          child: MouseRegion(
            opaque: false,
            onEnter: (_) {
              if (!_isDesktop || !_canOpenCatalogPopup) {
                return;
              }
              _catalogHotspotTimer?.cancel();
              _catalogHotspotTimer =
                  Timer(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                if (!_canOpenCatalogPopup) return;
                _showCatalogPopup(fromHotspot: true);
              });
            },
            onExit: (_) => _catalogHotspotTimer?.cancel(),
            child: const SizedBox(width: 36, height: 90),
          ),
        ),
      ),
      ValueListenableBuilder<_DesktopGestureOverlayViewData>(
        valueListenable: _desktopGestureOverlayNotifier,
        builder: (_, overlay, __) {
          if (!overlay.active || overlay.icon == null) {
            return const SizedBox.shrink();
          }
          return Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(overlay.icon, color: Colors.white, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    overlay.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ];
  }
}
