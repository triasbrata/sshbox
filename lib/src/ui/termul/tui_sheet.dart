// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_sheet.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_button.dart';
import 'tui_progress.dart';

/// Default max width on wide viewports — phone stays edge-to-edge.
const tuiSheetMaxWidth = 480.0;

/// Opens a Termul bottom sheet over [context].
///
/// Full width on a phone; on desktop the sheet is capped at [maxWidth] and
/// centred horizontally (Flutter's modal sheet constraints). Tall content
/// should scroll inside the builder (see [TuiSheet]). A drag handle is drawn
/// unless [showHandle] is false.
Future<T?> showTuiSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
  bool showHandle = true,
  double maxWidth = tuiSheetMaxWidth,
  double maxHeightFactor = 0.9,
}) {
  final p = TermulThemeData.of(context).palette;
  final size = MediaQuery.sizeOf(context);

  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: true,
    backgroundColor: p.panel,
    barrierColor: p.text.withValues(alpha: 0.35),
    shape: const RoundedRectangleBorder(),
    constraints: BoxConstraints(
      maxWidth: maxWidth,
      maxHeight: size.height * maxHeightFactor,
    ),
    builder: (ctx) {
      final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [if (showHandle) const TuiSheetHandle(), builder(ctx)],
        ),
      );
    },
  );
}

/// Hairline drag affordance at the top of a sheet.
class TuiSheetHandle extends StatelessWidget {
  const TuiSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      label: 'Drag handle',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
        child: Center(child: Container(width: 36, height: 3, color: p.dim)),
      ),
    );
  }
}

/// Sheet body chrome: accent title, optional message/detail, [child], actions.
///
/// Prefer putting long content in [child] wrapped with a scroll view or a
/// height-bounded list (see [showTuiChoiceSheet]).
class TuiSheet extends StatelessWidget {
  const TuiSheet({
    super.key,
    required this.title,
    this.message,
    this.detail,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 20),
    this.child,
  });

  final String title;
  final String? message;
  final String? detail;
  final List<Widget> actions;
  final EdgeInsets padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);

    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall!.copyWith(
                color: p.accent,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              style: theme.textTheme.headlineMedium!.copyWith(
                color: p.text,
                fontSize: 22,
              ),
            ),
          ],
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail!,
              style: theme.textTheme.bodySmall!.copyWith(
                color: p.muted,
                height: 1.45,
              ),
            ),
          ],
          if (child != null) ...[const SizedBox(height: 16), child!],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                actions.first,
                if (actions.length > 1) ...[
                  const Spacer(),
                  for (final action in actions.skip(1)) ...[
                    const SizedBox(width: 8),
                    action,
                  ],
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline loading block for sheets (connect progress, waiting on auth).
class TuiSheetLoading extends StatelessWidget {
  const TuiSheetLoading({super.key, this.label = 'Connecting…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return TuiSpinner(label: label, size: 14);
  }
}

/// One row in a choice sheet — mono label, optional meta, tap target.
class TuiSheetOption extends StatelessWidget {
  const TuiSheetOption({
    super.key,
    required this.label,
    this.meta,
    this.selected = false,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final String? meta;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final fg = enabled ? p.text : p.dim;

    return Material(
      color: selected ? p.selection : Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        hoverColor: p.selection,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: fg,
                        height: 1.3,
                      ),
                    ),
                    if (meta != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta!,
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 11,
                          color: p.dim,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                Text(
                  '▸',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    color: p.accent,
                    fontSize: 14,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirm / prompt sheet with cancel + primary (or destructive) action.
///
/// Returns `true` on confirm, `false` on cancel, `null` if dismissed.
Future<bool?> showTuiConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  String? detail,
  String confirmLabel = 'confirm',
  String cancelLabel = 'cancel',
  TuiButtonVariant confirmVariant = TuiButtonVariant.primary,
  Widget? child,
}) {
  return showTuiSheet<bool>(
    context,
    builder: (ctx) => TuiSheet(
      title: title,
      message: message,
      detail: detail,
      actions: [
        TuiButton(
          label: cancelLabel,
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        TuiButton(
          label: confirmLabel,
          variant: confirmVariant,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
      child: child,
    ),
  );
}

/// Error sheet with optional retry — returns `true` if retry tapped.
Future<bool?> showTuiErrorSheet(
  BuildContext context, {
  required String title,
  required String message,
  String? detail,
  String retryLabel = 'retry',
  String dismissLabel = 'close',
}) {
  return showTuiSheet<bool>(
    context,
    builder: (ctx) => TuiSheet(
      title: title,
      message: message,
      detail: detail,
      actions: [
        TuiButton(
          label: dismissLabel,
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        TuiButton(
          label: retryLabel,
          prefix: '↻',
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
}

/// Loading sheet — caller dismisses via [Navigator.pop] when done.
Future<T?> showTuiLoadingSheet<T>(
  BuildContext context, {
  String title = 'status',
  String message = 'Working…',
  String loadingLabel = 'Connecting…',
  bool isDismissible = false,
  bool enableDrag = false,
}) {
  return showTuiSheet<T>(
    context,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showHandle: isDismissible,
    builder: (ctx) => TuiSheet(
      title: title,
      message: message,
      child: TuiSheetLoading(label: loadingLabel),
    ),
  );
}

/// Pick one option from a list. Returns the selected value, or null.
Future<T?> showTuiChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? message,
  String? detail,
  required List<({T value, String label, String? meta})> options,
  T? selected,
}) {
  return showTuiSheet<T>(
    context,
    builder: (ctx) {
      final maxListH = MediaQuery.sizeOf(ctx).height * 0.45;
      return TuiSheet(
        title: title,
        message: message,
        detail: detail,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxListH),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: options.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: TermulThemeData.of(ctx).palette.border,
            ),
            itemBuilder: (context, i) {
              final opt = options[i];
              return TuiSheetOption(
                label: opt.label,
                meta: opt.meta,
                selected: selected == opt.value,
                onTap: () => Navigator.pop(ctx, opt.value),
              );
            },
          ),
        ),
      );
    },
  );
}
