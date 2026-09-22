// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_chrome.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// TuiSectionLabel is named to a screen reader as written, not in the
// capitals it is drawn in, and as a node of its own.

import 'package:flutter/material.dart';

import 'termul_theme.dart';

/// Uppercase section heading used in settings and gallery rails.
class TuiSectionLabel extends StatelessWidget {
  const TuiSectionLabel(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      container: true,
      header: true,
      label: title,
      excludeSemantics: true,
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          color: p.accent,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Hairline horizontal rule — chrome divider.
class TuiDivider extends StatelessWidget {
  const TuiDivider({super.key, this.height = 1, this.indent = 0});

  final double height;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(height: height, color: p.border),
    );
  }
}
