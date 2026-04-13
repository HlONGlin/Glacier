import '../emby.dart';
import 'read_scheme.dart';
import 'exclusive_folder_helpers.dart';
import 'exclusive_models.dart';

class EmbyExclusiveQuickPreviewResult {
  final List<EmbyExclusiveUiItem> mergedVideos;
  final List<EmbyExclusiveUiItem> mergedImages;
  final EmbyFolderTopTab nextTopTab;

  const EmbyExclusiveQuickPreviewResult({
    required this.mergedVideos,
    required this.mergedImages,
    required this.nextTopTab,
  });
}

class EmbyExclusiveReloadStageResult {
  final List<EmbyExclusiveUiItem> directItems;
  final List<EmbyExclusiveUiItem> recursiveVideos;
  final List<EmbyExclusiveUiItem> recursiveImages;
  final EmbyLibraryKind libraryKind;
  final EmbyFolderTopTab nextTopTab;

  const EmbyExclusiveReloadStageResult({
    required this.directItems,
    required this.recursiveVideos,
    required this.recursiveImages,
    required this.libraryKind,
    required this.nextTopTab,
  });
}

class EmbyExclusiveFolderLoadHelpers {
  EmbyExclusiveFolderLoadHelpers._();

  static EmbyExclusiveQuickPreviewResult? mergeQuickPreview({
    required EmbyMediaSplit quick,
    required List<EmbyExclusiveUiItem> currentRecursiveVideos,
    required List<EmbyExclusiveUiItem> currentRecursiveImages,
    required List<EmbyExclusiveUiItem> Function(
      Iterable<EmbyItem> items, {
      required int maxWidth,
      Map<String, EmbyExclusiveUiItem>? seed,
    }) toUiItemsWithSeed,
    required List<EmbyExclusiveUiItem> Function(
      List<EmbyExclusiveUiItem> base,
      List<EmbyExclusiveUiItem> extra,
    ) mergeUiById,
    required EmbyFolderTopTab currentTopTab,
    required List<EmbyExclusiveUiItem> directItems,
    required EmbyFolderTopTab Function({
      required EmbyFolderTopTab current,
      required List<EmbyExclusiveUiItem> directItems,
      required List<EmbyExclusiveUiItem> videos,
      required List<EmbyExclusiveUiItem> images,
      bool preferPriority,
    }) chooseTopTab,
    required bool preferPriority,
  }) {
    final existingVideoIds = currentRecursiveVideos
        .map((item) => item.item.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final existingImageIds = currentRecursiveImages
        .map((item) => item.item.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    final quickVideos = toUiItemsWithSeed(
      quick.videos.where((item) => !existingVideoIds.contains(item.id.trim())),
      maxWidth: 520,
    );
    final quickImages = toUiItemsWithSeed(
      quick.images.where((item) => !existingImageIds.contains(item.id.trim())),
      maxWidth: 520,
    );
    if (quickVideos.isEmpty && quickImages.isEmpty) return null;

    final mergedVideos = mergeUiById(currentRecursiveVideos, quickVideos);
    final mergedImages = mergeUiById(currentRecursiveImages, quickImages);
    final nextTopTab = chooseTopTab(
      current: currentTopTab,
      directItems: directItems,
      videos: mergedVideos,
      images: mergedImages,
      preferPriority: preferPriority,
    );
    return EmbyExclusiveQuickPreviewResult(
      mergedVideos: mergedVideos,
      mergedImages: mergedImages,
      nextTopTab: nextTopTab,
    );
  }

  static EmbyExclusiveReloadStageResult buildReloadStage({
    required EmbyFolderImmediateSnapshot immediateSnapshot,
    required List<EmbyExclusiveUiItem> Function(
      Iterable<EmbyItem> items, {
      required int maxWidth,
      Map<String, EmbyExclusiveUiItem>? seed,
    }) toUiItemsWithSeed,
    required Map<String, EmbyExclusiveUiItem> Function(
      List<EmbyExclusiveUiItem> src,
    ) indexUiById,
    required EmbyFolderTopTab currentTopTab,
    required EmbyFolderTopTab Function({
      required EmbyFolderTopTab current,
      required List<EmbyExclusiveUiItem> directItems,
      required List<EmbyExclusiveUiItem> videos,
      required List<EmbyExclusiveUiItem> images,
      bool preferPriority,
    }) chooseTopTab,
    required bool preferPriority,
  }) {
    final directItems = toUiItemsWithSeed(
      immediateSnapshot.directItems,
      maxWidth: 520,
    );
    final immediateIndex = indexUiById(directItems);
    final recursiveVideos = toUiItemsWithSeed(
      immediateSnapshot.directMedia.videos,
      maxWidth: 520,
      seed: immediateIndex,
    );
    final recursiveImages = toUiItemsWithSeed(
      immediateSnapshot.directMedia.images,
      maxWidth: 520,
      seed: immediateIndex,
    );
    final libraryKind = EmbyExclusiveFolderHelpers.libraryKindFromSignal(
        immediateSnapshot.libraryKind);
    final nextTopTab = chooseTopTab(
      current: currentTopTab,
      directItems: directItems,
      videos: recursiveVideos,
      images: recursiveImages,
      preferPriority: preferPriority,
    );
    return EmbyExclusiveReloadStageResult(
      directItems: directItems,
      recursiveVideos: recursiveVideos,
      recursiveImages: recursiveImages,
      libraryKind: libraryKind,
      nextTopTab: nextTopTab,
    );
  }
}
