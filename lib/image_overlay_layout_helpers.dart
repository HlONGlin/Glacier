import 'package:flutter/material.dart';

class ImageOverlayLayoutHelpers {
  static const double contextMenuWidth = 220.0;
  static const double sizeMenuWidth = 240.0;
  static const double overlayPadding = 8.0;
  static const double menuItemHeight = 44.0;

  static double clampPointX(double dx, Size overlaySize) {
    return dx.clamp(overlayPadding, overlaySize.width - overlayPadding);
  }

  static double clampPointY(double dy, Size overlaySize) {
    return dy.clamp(overlayPadding, overlaySize.height - overlayPadding);
  }

  static double contextMenuLeft(double dx, Size overlaySize) {
    return (dx + contextMenuWidth <= overlaySize.width - overlayPadding)
        ? dx
        : (dx - contextMenuWidth).clamp(overlayPadding,
            overlaySize.width - contextMenuWidth - overlayPadding);
  }

  static double contextMenuTop({
    required double dy,
    required Size overlaySize,
    required int itemCount,
  }) {
    final estimatedHeight = itemCount * menuItemHeight;
    return (dy + estimatedHeight <= overlaySize.height - overlayPadding)
        ? dy
        : (dy - estimatedHeight).clamp(
            overlayPadding,
            overlaySize.height - estimatedHeight - overlayPadding,
          );
  }

  static double sizeMenuLeft({
    required double parentLeft,
    required double parentWidth,
    required Size overlaySize,
  }) {
    return (parentLeft + parentWidth + 6.0).clamp(
      overlayPadding,
      overlaySize.width - sizeMenuWidth - overlayPadding,
    );
  }

  static double sizeMenuTop({
    required double parentTop,
    required Size overlaySize,
  }) {
    return parentTop.clamp(overlayPadding, overlaySize.height - overlayPadding);
  }
}
