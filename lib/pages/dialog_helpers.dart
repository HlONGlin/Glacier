part of '../pages.dart';

/// =========================
/// No-animation dialogs / menus
/// =========================
Future<T?> _panel<T>(BuildContext context, Widget child,
    {Color barrier = Colors.black26}) {
  return showAdaptivePanel<T>(
    context: context,
    child: child,
    barrierColor: barrier,
    barrierLabel: 'panel',
  );
}

Future<String?> _textInput(BuildContext context,
    {required String title, required String hint, String? initial}) {
  final c = TextEditingController(text: initial ?? '');
  return _panel<String>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
                controller: c,
                autofocus: true,
                decoration: InputDecoration(hintText: hint),
                onSubmitted: (_) => Navigator.pop(context, c.text.trim())),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, c.text.trim()),
                  child: const Text('确定')),
            ]),
          ]),
        ),
      ),
    ),
  );
}

Future<bool> _confirm(BuildContext context,
    {required String title, required String message}) async {
  final res = await _panel<bool>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(message),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确定')),
            ]),
          ]),
        ),
      ),
    ),
  );
  return res ?? false;
}

/// Pick files and copy into targetDir (no move). Returns copied count.
Future<int> _addFilesToDir(String targetDir) async {
  final dir = Directory(targetDir);
  if (!await dir.exists()) return 0;

  final res = await FilePicker.platform.pickFiles(
    dialogTitle: '选择要添加的文件（将复制到当前目录）',
    allowMultiple: true,
    type: FileType.custom,
    allowedExtensions: [...kPageImageExts, ...kPageVideoExts]
        .map((e) => e.substring(1))
        .toList(),
  );
  if (res == null || res.files.isEmpty) return 0;

  int ok = 0;
  for (final f in res.files) {
    final srcPath = f.path;
    if (srcPath == null) continue;
    final src = File(srcPath);
    if (!await src.exists()) continue;

    final base = p.basename(srcPath);
    var dst = p.join(targetDir, base);

    if (await File(dst).exists()) {
      final name = p.basenameWithoutExtension(base);
      final ext = p.extension(base);
      int i = 1;
      while (await File(dst).exists()) {
        dst = p.join(targetDir, '$name($i)$ext');
        i++;
      }
    }

    try {
      await src.copy(dst);
      ok++;
    } catch (_) {}
  }
  return ok;
}

class _CtxItem<T> {
  final T value;
  final String label;
  final IconData icon;
  const _CtxItem(this.value, this.label, this.icon);
}

Future<T?> _ctxMenu<T>(
    BuildContext context, Offset pos, List<_CtxItem<T>> items) {
  // App-friendly: full-screen bottom sheet style, no animation.
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'ctx',
    barrierColor: Colors.black54,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, __) {
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Theme.of(ctx).colorScheme.surface,
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height,
              width: double.infinity,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('选择操作',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (c, i) {
                        final it = items[i];
                        return ListTile(
                          leading: Icon(it.icon),
                          title: Text(it.label),
                          onTap: () => Navigator.of(ctx).pop(it.value),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<T?> _picker<T>(
  BuildContext context, {
  required String title,
  required T current,
  required List<T> options,
  required String Function(T) labelOf,
  required IconData Function(T) iconOf,
}) {
  Widget optionsBody(BuildContext ctx) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        for (final o in options)
          InkWell(
            onTap: () => Navigator.of(ctx).pop(o),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Icon(iconOf(o), size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(labelOf(o))),
                if (o == current) const Icon(Icons.check, size: 18),
              ]),
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }

  if (isCompactWidth(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final insets = MediaQuery.of(ctx).viewInsets;
        final maxH = (size.height * 0.58).clamp(220.0, 420.0);
        final estimated = options.length * 52.0 + 80.0;
        final h = estimated.clamp(180.0, maxH);
        return AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: SizedBox(
            height: h,
            child: optionsBody(ctx),
          ),
        );
      },
    );
  }

  return _panel<T>(
    context,
    Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: optionsBody(context),
      ),
    ),
  );
}

/// Edit sources (no animation). Returns a fully updated FavoriteCollection.
/// - Added: WebDAV source add (root/dir/file)
Future<FavoriteCollection?> _editSourcesDialog(
    BuildContext context, FavoriteCollection c) {
  final work = c.copy();
  return showAdaptivePanel<FavoriteCollection>(
    context: context,
    barrierColor: Colors.black26,
    barrierLabel: 'edit',
    child: StatefulBuilder(builder: (ctx2, setState) {
      Future<void> addLocal() async {
        final dir = await FilePicker.platform
            .getDirectoryPath(dialogTitle: '选择要加入的文件夹');
        if (dir == null) return;
        final norm = p.normalize(dir);
        if (!work.sources.contains(norm)) {
          setState(() => work.sources.add(norm));
        }
      }

      Future<void> addWebDav() async {
        final src = await WebDavPickSourcePage.pick(context);
        if (src == null) return;
        if (!work.sources.contains(src)) setState(() => work.sources.add(src));
      }

      Future<void> addEmby() async {
        final src = await EmbyPickSourcePage.pick(context);
        if (src == null) return;
        if (!work.sources.contains(src)) setState(() => work.sources.add(src));
      }

      void rm(String s) => setState(() => work.sources.remove(s));

      return Center(
        child: Material(
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                child: Row(children: [
                  Expanded(
                      child: Text('编辑收藏夹：${work.name}',
                          style: Theme.of(ctx2).textTheme.titleMedium)),
                  IconButton(
                      onPressed: addLocal,
                      tooltip: '添加本地文件夹',
                      icon: const Icon(Icons.create_new_folder_outlined)),
                  IconButton(
                      onPressed: addWebDav,
                      tooltip: '添加 WebDAV（本体/目录/文件）',
                      icon: const Icon(Icons.cloud_outlined)),
                  IconButton(
                      onPressed: addEmby,
                      tooltip: '添加 Emby（收藏）',
                      icon: const Icon(Icons.video_library_outlined)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: work.sources.isEmpty
                    ? const Center(
                        child: Text('还没有添加来源。\n右上角按钮可添加本地或 WebDAV。',
                            textAlign: TextAlign.center))
                    : ListView.separated(
                        itemCount: work.sources.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = work.sources[i];
                          final isWd = isPageWebDavSource(s);
                          final isEmby = isPageEmbySource(s);
                          final title = (isWd || isEmby)
                              ? s
                              : (p.basename(s).isEmpty ? s : p.basename(s));
                          final subtitle =
                              isWd ? 'WebDAV' : (isEmby ? 'Emby' : s);
                          return ListTile(
                            leading: Icon(
                              isWd
                                  ? Icons.cloud_outlined
                                  : (isEmby
                                      ? Icons.video_library_outlined
                                      : Icons.folder_outlined),
                            ),
                            title: Text(title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(subtitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                                onPressed: () => rm(s),
                                tooltip: '移除',
                                icon: const Icon(Icons.close)),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx2),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx2, work),
                      child: const Text('保存')),
                ]),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}
