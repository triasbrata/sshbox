// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_dialog.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// The title is named to a screen reader as written, not in capitals, as a
// node of its own, and
// the actions after the first wrap to a second line rather than overflow a
// phone's width.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_button.dart';

/// Centered confirm sheet — panel + mono labels.
Future<bool> showTuiConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? detail,
  String confirmLabel = 'confirm',
  String cancelLabel = 'cancel',
  TuiButtonVariant confirmVariant = TuiButtonVariant.danger,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: TermulThemeData.of(context).palette.text
        .withValues(alpha: 0.35),
    builder: (ctx) => TuiDialog(
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
    ),
  );
  return result ?? false;
}

class TuiDialog extends StatelessWidget {
  const TuiDialog({
    super.key,
    required this.title,
    this.message,
    this.detail,
    this.child,
    this.actions = const [],
    this.maxWidth = 360,
  });

  final String title;
  final String? message;
  final String? detail;
  final Widget? child;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Dialog(
      backgroundColor: p.panel,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                header: true,
                label: title,
                excludeSemantics: true,
                child: Text(
                  title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall!
                      .copyWith(color: p.accent, letterSpacing: 0.4),
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 12),
                Text(
                  message!,
                  style: Theme.of(context).textTheme.headlineMedium!
                      .copyWith(color: p.text, fontSize: 22),
                ),
              ],
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail!,
                  style: Theme.of(context).textTheme.bodySmall!
                      .copyWith(color: p.muted, height: 1.45),
                ),
              ],
              if (child != null) ...[const SizedBox(height: 12), child!],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    actions.first,
                    if (actions.length > 1) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [...actions.skip(1)],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
