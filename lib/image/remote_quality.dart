import 'dart:math';

enum RemoteImageQualityMode {
  original,
  balanced,
  compressed,
}

extension RemoteImageQualityModeX on RemoteImageQualityMode {
  String get storageValue {
    switch (this) {
      case RemoteImageQualityMode.original:
        return 'original';
      case RemoteImageQualityMode.balanced:
        return 'balanced';
      case RemoteImageQualityMode.compressed:
        return 'compressed';
    }
  }

  String get label {
    switch (this) {
      case RemoteImageQualityMode.original:
        return '画质：原图优先';
      case RemoteImageQualityMode.balanced:
        return '画质：平衡压缩';
      case RemoteImageQualityMode.compressed:
        return '画质：高压缩';
    }
  }

  int scaledWidth(int viewportWidth) {
    switch (this) {
      case RemoteImageQualityMode.original:
        return max(viewportWidth, 2200);
      case RemoteImageQualityMode.balanced:
        return max(viewportWidth, 1400);
      case RemoteImageQualityMode.compressed:
        return max(viewportWidth, 960);
    }
  }

  int scaledHeight(int viewportHeight) {
    switch (this) {
      case RemoteImageQualityMode.original:
        return max(viewportHeight, 2200);
      case RemoteImageQualityMode.balanced:
        return max(viewportHeight, 1400);
      case RemoteImageQualityMode.compressed:
        return max(viewportHeight, 960);
    }
  }

  int? embyMaxWidth(int viewportWidth) {
    switch (this) {
      case RemoteImageQualityMode.original:
        return null;
      case RemoteImageQualityMode.balanced:
        return max(viewportWidth, 1600);
      case RemoteImageQualityMode.compressed:
        return max(viewportWidth, 960);
    }
  }

  int? get embyQuality {
    switch (this) {
      case RemoteImageQualityMode.original:
        return null;
      case RemoteImageQualityMode.balanced:
        return 90;
      case RemoteImageQualityMode.compressed:
        return 72;
    }
  }
}

RemoteImageQualityMode remoteImageQualityModeFromStorage(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'compressed':
      return RemoteImageQualityMode.compressed;
    case 'balanced':
      return RemoteImageQualityMode.balanced;
    case 'original':
    default:
      return RemoteImageQualityMode.original;
  }
}
