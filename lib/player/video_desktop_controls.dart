part of '../video.dart';

Future<double?> _showDesktopRatePicker(
  BuildContext buttonContext, {
  required double currentRate,
}) async {
  final box = buttonContext.findRenderObject() as RenderBox?;
  if (box == null) return null;
  final overlay =
      Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
  final pos = box.localToGlobal(Offset.zero, ancestor: overlay);

  return showGeneralDialog<double>(
    context: buttonContext,
    barrierDismissible: true,
    barrierLabel: '倍速',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, anim1, anim2) {
      const items = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
      const w = 160.0;
      final top = (pos.dy - items.length * 44 - 8) > 0
          ? (pos.dy - items.length * 44 - 8)
          : (pos.dy + box.size.height + 8);
      final left = (pos.dx).clamp(8.0, overlay.size.width - w - 8);

      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: w,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final v = items[i];
                  final selected = (v == currentRate);
                  return InkWell(
                    onTap: () => Navigator.of(ctx).pop(v),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$v 倍',
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.white70,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (selected)
                            const Icon(Icons.check,
                                color: Colors.white, size: 18),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    },
  );
}

extension _DesktopVideoControls on _VideoPlayerPageState {
  void _pokeUI() {
    _pageController.showDesktopUi();
    if (_isDesktop) {
      _pageController.showDesktopCursor();
      _showTitleHint();
    }
    _pageController.scheduleDesktopUiHide(
      delay: _VideoPlayerPageState._hideDelay,
      enabled: true,
      onHide: () {
        if (!mounted) return;
        _pageController.hideDesktopUi();
      },
    );
    if (_isDesktop) {
      _pageController.scheduleDesktopCursorHide(
        delay: _VideoPlayerPageState._cursorDelay,
        enabled: true,
        onHide: () {
          if (!mounted) return;
          _pageController.hideDesktopCursor();
        },
      );
    }
  }
}
