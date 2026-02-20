import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double kMinTapTarget = 44;

bool isCompactWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 768;

String friendlyErrorMessage(Object error) {
  final raw = error.toString().trim();
  final text = raw.isEmpty ? 'Unknown error' : raw;
  final lower = text.toLowerCase();

  if (error is TimeoutException || lower.contains('timed out')) {
    return 'Network timeout, please retry.';
  }
  if (error.runtimeType.toString().contains('SocketException') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable')) {
    return 'Network unavailable, check your connection.';
  }

  final code = RegExp(r'(?:http\s*|status\s*)(\d{3})', caseSensitive: false)
      .firstMatch(text)
      ?.group(1);
  switch (code) {
    case '401':
      return 'Session expired, please login again.';
    case '403':
      return 'Permission denied.';
    case '404':
      return 'Resource not found.';
    case '500':
    case '502':
    case '503':
    case '504':
      return 'Server is unavailable, please retry later.';
  }
  return text;
}

void showAppToast(
  BuildContext context,
  String message, {
  bool error = false,
  Duration duration = const Duration(seconds: 2),
  SnackBarAction? action,
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      duration: duration,
      action: action,
      backgroundColor:
          error ? const Color(0xFFC0392B) : const Color(0xFF1F2937),
      content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}

Future<T?> showAdaptivePanel<T>({
  required BuildContext context,
  required Widget child,
  Color barrierColor = Colors.black26,
  bool barrierDismissible = true,
  String barrierLabel = 'panel',
}) {
  final compact = isCompactWidth(context);
  if (compact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final insets = MediaQuery.of(ctx).viewInsets;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: FractionallySizedBox(
            heightFactor: 0.96,
            child: child,
          ),
        );
      },
    );
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, __) => Center(child: child),
  );
}

/// iOS-like glass UI kit (minimal animation, focus on consistency)
class AppThemeColors {
  static const Color seed = Color(0xFF0E7490);
  static const Color bg = Color(0xFFF3F7FB);
  static const Color text = Color(0xFF111827);
  static const Color subtext = Color(0xFF64748B);
  static const Color glass = Color(0xCCFFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color divider = Color(0x1A000000);
}

class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppThemeColors.seed,
      brightness: Brightness.light,
    );

    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: Colors.black.withOpacity(0.08)),
    );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );

    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      colorScheme: scheme.copyWith(
        surface: Colors.white,
        background: AppThemeColors.bg,
      ),
      scaffoldBackgroundColor: AppThemeColors.bg,
      dividerColor: AppThemeColors.divider,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppThemeColors.text,
        ),
        iconTheme: IconThemeData(color: AppThemeColors.text),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppThemeColors.text,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppThemeColors.text,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          height: 1.3,
          color: AppThemeColors.text,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 1.3,
          color: AppThemeColors.text,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: AppThemeColors.subtext,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppThemeColors.glass,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppThemeColors.glass,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.86),
        border: baseBorder,
        enabledBorder: baseBorder,
        focusedBorder: baseBorder.copyWith(
          borderSide:
              BorderSide(color: scheme.primary.withOpacity(0.65), width: 1.4),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(
              const Size(kMinTapTarget, kMinTapTarget)),
          fixedSize: MaterialStateProperty.all(
              const Size(kMinTapTarget, kMinTapTarget)),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(
              const Size(kMinTapTarget, kMinTapTarget)),
          shape: MaterialStateProperty.all(buttonShape),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(
              const Size(kMinTapTarget, kMinTapTarget)),
          padding: MaterialStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          shape: MaterialStateProperty.all(buttonShape),
          textStyle: MaterialStateProperty.all(
            const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(
              const Size(kMinTapTarget, kMinTapTarget)),
          padding: MaterialStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          shape: MaterialStateProperty.all(buttonShape),
          side: MaterialStateProperty.all(
            BorderSide(color: Colors.black.withOpacity(0.10)),
          ),
          textStyle: MaterialStateProperty.all(
            const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minVerticalPadding: 8,
        iconColor: AppThemeColors.text,
        textColor: AppThemeColors.text,
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle:
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.58)),
        ),
      ),
    );
  }
}

class AppLoadingState extends StatelessWidget {
  final String message;
  final int skeletonRows;
  const AppLoadingState({
    super.key,
    this.message = 'Loading...',
    this.skeletonRows = 5,
  });

  @override
  Widget build(BuildContext context) {
    return AppViewport(
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          for (var i = 0; i < skeletonRows; i++) ...[
            const _SkeletonBlock(height: 72),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          Center(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  const AppEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 10),
            Text(title, textAlign: TextAlign.center),
            if ((subtitle ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class AppErrorState extends StatelessWidget {
  final String title;
  final String? details;
  final VoidCallback? onRetry;
  const AppErrorState({
    super.key,
    this.title = 'Load failed',
    this.details,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 46, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 10),
            Text(title, textAlign: TextAlign.center),
            if ((details ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                details!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AppViewport extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const AppViewport({
    super.key,
    required this.child,
    this.maxWidth = 1200,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  final double height;
  const _SkeletonBlock({required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE9EEF6), Color(0xFFF2F5FA)],
        ),
      ),
    );
  }
}

/// A reusable glass container (blur + translucent surface + subtle border).
class Glass extends StatelessWidget {
  final Widget child;
  final double blur;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final Gradient? gradient;
  final Border? border;

  const Glass({
    super.key,
    required this.child,
    this.blur = 18,
    this.radius = 16,
    this.padding,
    this.color,
    this.gradient,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceColor = color ?? AppThemeColors.glass;
    final b = border ?? Border.all(color: AppThemeColors.glassBorder, width: 1);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: gradient == null ? surfaceColor : null,
            gradient: gradient,
            border: b,
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 16,
    this.blur = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: radius,
      blur: blur,
      padding: padding,
      child: child,
    );
  }
}

/// iOS-like translucent AppBar (with blur).
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final bool centerTitle;
  final double blur;
  final double opacity;
  final Color? tint;

  const GlassAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.centerTitle = true,
    this.blur = 18,
    this.opacity = 0.78,
    this.tint,
  });

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    final bg = (tint ?? Colors.white).withOpacity(opacity);

    return AppBar(
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      title: title,
      actions: actions,
      leading: leading,
      centerTitle: centerTitle,
      bottom: bottom,
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            color: bg,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.black.withOpacity(0.06),
                    width: 0.8,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ControlChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? tint;

  const ControlChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = tint ?? Theme.of(context).colorScheme.primary;
    final bg = selected ? c.withOpacity(0.14) : Colors.white.withOpacity(0.82);
    final border =
        selected ? c.withOpacity(0.25) : Colors.black.withOpacity(0.08);
    final fg = selected ? c : AppThemeColors.text;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TopActionMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;

  const TopActionMenuItem({
    required this.value,
    required this.icon,
    required this.label,
  });
}

class TopActionMenu<T> extends StatelessWidget {
  final List<TopActionMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String tooltip;

  const TopActionMenu({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip = '更多',
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<T>(
            value: it.value,
            child: Row(
              children: [
                Icon(it.icon, size: 18),
                const SizedBox(width: 8),
                Text(it.label),
              ],
            ),
          ),
      ],
      child: Container(
        height: 40,
        width: 40,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.84),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withOpacity(0.08)),
        ),
        child: const Icon(Icons.more_horiz, size: 20),
      ),
    );
  }
}

class FilterBar extends StatelessWidget {
  final List<Widget> children;

  const FilterBar({
    super.key,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        itemBuilder: (_, i) => children[i],
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: children.length,
      ),
    );
  }
}

class SelectionBarAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const SelectionBarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class SelectionBar extends StatelessWidget {
  final String title;
  final List<SelectionBarAction> actions;

  const SelectionBar({
    super.key,
    required this.title,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          border: Border(
            top: BorderSide(color: Colors.black.withOpacity(0.08)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final a in actions) ...[
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  onPressed: a.onTap,
                  icon: Icon(a.icon, size: 18),
                  label: Text(a.label),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Default page padding that looks good with glass cards.
class PagePadding extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const PagePadding({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) => Padding(padding: padding, child: child);
}
