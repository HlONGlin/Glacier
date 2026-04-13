import 'dart:math';

import 'package:flutter/material.dart';

class ImageStripLayoutHelpers {
  static const double placeholderHeight = 220.0;
  static const double itemGap = 12.0;
  static const double visibleAlignment = 0.15;
  static const double safeTopInset = 8.0;

  static double estimateOffsetForIndex(int index) {
    final safeIndex = max(0, index);
    return safeIndex * (placeholderHeight + itemGap);
  }

  static double safeTopOffset(BuildContext context) {
    return MediaQuery.of(context).padding.top + safeTopInset;
  }

  static double pageJumpDelta(BuildContext context) {
    return MediaQuery.of(context).size.height * 0.82;
  }
}
