import 'dart:async';

import 'package:flutter/foundation.dart';

class PlayerController extends ChangeNotifier {
  bool _controlsVisible = true;
  bool _catalogMenuOpen = false;
  bool _lockButtonVisible = true;
  Timer? _autoHideTimer;
  bool _desktopUiVisible = false;
  bool _desktopCursorHidden = false;
  bool _desktopCatalogOpen = false;
  Timer? _desktopUiHideTimer;
  Timer? _desktopCursorHideTimer;

  bool get controlsVisible => _controlsVisible;
  bool get catalogMenuOpen => _catalogMenuOpen;
  bool get lockButtonVisible => _lockButtonVisible;
  bool get desktopUiVisible => _desktopUiVisible;
  bool get desktopCursorHidden => _desktopCursorHidden;
  bool get desktopCatalogOpen => _desktopCatalogOpen;

  void showControls() {
    if (_controlsVisible) return;
    _controlsVisible = true;
    notifyListeners();
  }

  void hideControls() {
    if (!_controlsVisible) return;
    _controlsVisible = false;
    notifyListeners();
  }

  void toggleControls() {
    _controlsVisible = !_controlsVisible;
    notifyListeners();
  }

  void setCatalogMenuOpen(bool value) {
    if (_catalogMenuOpen == value) return;
    _catalogMenuOpen = value;
    notifyListeners();
  }

  void toggleLockButtonVisible() {
    _lockButtonVisible = !_lockButtonVisible;
    notifyListeners();
  }

  void showLockButton() {
    if (_lockButtonVisible) return;
    _lockButtonVisible = true;
    notifyListeners();
  }

  void hideLockButton() {
    if (!_lockButtonVisible) return;
    _lockButtonVisible = false;
    notifyListeners();
  }

  void cancelAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  void scheduleAutoHide({
    required Duration delay,
    required bool enabled,
    required VoidCallback onHide,
  }) {
    cancelAutoHide();
    if (!enabled || !_controlsVisible) return;
    _autoHideTimer = Timer(delay, onHide);
  }

  void showDesktopUi() {
    if (_desktopUiVisible) return;
    _desktopUiVisible = true;
    notifyListeners();
  }

  void hideDesktopUi() {
    if (!_desktopUiVisible) return;
    _desktopUiVisible = false;
    notifyListeners();
  }

  void toggleDesktopUi() {
    _desktopUiVisible = !_desktopUiVisible;
    notifyListeners();
  }

  void showDesktopCursor() {
    if (!_desktopCursorHidden) return;
    _desktopCursorHidden = false;
    notifyListeners();
  }

  void hideDesktopCursor() {
    if (_desktopCursorHidden) return;
    _desktopCursorHidden = true;
    notifyListeners();
  }

  void setDesktopCatalogOpen(bool value) {
    if (_desktopCatalogOpen == value) return;
    _desktopCatalogOpen = value;
    notifyListeners();
  }

  void cancelDesktopUiHide() {
    _desktopUiHideTimer?.cancel();
    _desktopUiHideTimer = null;
  }

  void cancelDesktopCursorHide() {
    _desktopCursorHideTimer?.cancel();
    _desktopCursorHideTimer = null;
  }

  void scheduleDesktopUiHide({
    required Duration delay,
    required bool enabled,
    required VoidCallback onHide,
  }) {
    cancelDesktopUiHide();
    if (!enabled || !_desktopUiVisible) return;
    _desktopUiHideTimer = Timer(delay, onHide);
  }

  void scheduleDesktopCursorHide({
    required Duration delay,
    required bool enabled,
    required VoidCallback onHide,
  }) {
    cancelDesktopCursorHide();
    if (!enabled || _desktopCursorHidden) return;
    _desktopCursorHideTimer = Timer(delay, onHide);
  }

  @override
  void dispose() {
    cancelAutoHide();
    cancelDesktopUiHide();
    cancelDesktopCursorHide();
    super.dispose();
  }
}
