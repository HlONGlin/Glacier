typedef ImageWarmWindow = ({int forward, int backward});

class ImagePreloadWindows {
  static const int preloadForward = 3;
  static const int preloadBackward = 2;
  static const int stripActiveRadius = 8;
  static const int stripWarmForward = 10;
  static const int stripWarmBackward = 4;

  static ImageWarmWindow warmWindowForDelta(int delta) {
    if (delta >= 4) {
      return (forward: 16, backward: 5);
    }
    if (delta >= 2) {
      return (forward: 13, backward: 5);
    }
    return (forward: stripWarmForward, backward: stripWarmBackward);
  }

  static ImageWarmWindow pagedWindowForDelta(int delta, int direction) {
    if (delta >= 4) {
      return direction >= 0
          ? (forward: 8, backward: 2)
          : (forward: 2, backward: 8);
    }
    if (delta >= 2) {
      return direction >= 0
          ? (forward: 6, backward: 2)
          : (forward: 2, backward: 6);
    }
    return direction >= 0
        ? (forward: preloadForward + 2, backward: preloadBackward)
        : (forward: preloadBackward + 2, backward: preloadForward);
  }

  static ImageWarmWindow pagedSourceWarmWindowForDelta(
    int delta,
    int direction,
  ) {
    if (delta >= 4) {
      return direction >= 0
          ? (forward: 12, backward: 3)
          : (forward: 3, backward: 12);
    }
    if (delta >= 2) {
      return direction >= 0
          ? (forward: 9, backward: 3)
          : (forward: 3, backward: 9);
    }
    return direction >= 0
        ? (forward: 7, backward: 2)
        : (forward: 2, backward: 7);
  }

  static int activeRadiusForDelta(int delta) {
    if (delta >= 4) return 12;
    if (delta >= 2) return 10;
    return stripActiveRadius;
  }
}
