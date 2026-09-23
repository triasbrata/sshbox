// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_tooltip.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.

import 'package:flutter/material.dart';

import 'termul_palette.dart';
import 'termul_theme.dart';

/// Default wait before a hover tooltip appears.
const tuiTooltipWait = Duration(milliseconds: 450);

/// How long a touch long-press tooltip stays up.
const tuiTooltipShow = Duration(seconds: 2);

/// Termul-styled tooltip — mono label, sharp panel, hairline border.
///
/// Desktop: appears on hover after [waitDuration].
/// Touch: appears on long-press ([TooltipTriggerMode.longPress]).
class TuiTooltip extends StatelessWidget {
  const TuiTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = tuiTooltipWait,
    this.showDuration = tuiTooltipShow,
    this.preferBelow,
    this.excludeFromSemantics = false,
    this.enabled = true,
  });

  final String message;
  final Widget child;
  final Duration waitDuration;
  final Duration showDuration;
  final bool? preferBelow;
  final bool excludeFromSemantics;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || message.trim().isEmpty) return child;

    final p = TermulThemeData.of(context).palette;
    final look = _TuiTooltipLook.of(p);

    return Tooltip(
      message: message,
      waitDuration: waitDuration,
      showDuration: showDuration,
      preferBelow: preferBelow,
      excludeFromSemantics: excludeFromSemantics,
      triggerMode: TooltipTriggerMode.longPress,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      verticalOffset: 12,
      decoration: look.decoration,
      textStyle: look.textStyle,
      child: child,
    );
  }
}

/// Icon-only chrome control with a built-in [TuiTooltip].
///
/// Use for app-bar actions, tab close, key-bar icons — anything that would
/// otherwise be a bare glyph with no visible label.
class TuiIconButton extends StatelessWidget {
  const TuiIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 36,
    this.iconSize = 16,
  });

  /// Mono glyph or short mark (`×`, `⚙`, `＋`, …).
  final String icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = onPressed != null;

    return TuiTooltip(
      message: tooltip,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: tooltip,
        child: InkWell(
          onTap: onPressed,
          hoverColor: p.selection,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: ExcludeSemantics(
                child: Text(
                  icon,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: iconSize,
                    height: 1,
                    color: enabled ? p.text : p.dim,
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

/// App-wide [TooltipThemeData] matching [TuiTooltip] visuals.
TooltipThemeData tuiTooltipTheme(TermulPalette palette) {
  final look = _TuiTooltipLook.of(palette);
  return TooltipThemeData(
    waitDuration: tuiTooltipWait,
    showDuration: tuiTooltipShow,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    margin: const EdgeInsets.symmetric(horizontal: 8),
    verticalOffset: 12,
    triggerMode: TooltipTriggerMode.longPress,
    decoration: look.decoration,
    textStyle: look.textStyle,
  );
}

class _TuiTooltipLook {
  const _TuiTooltipLook({required this.decoration, required this.textStyle});

  final BoxDecoration decoration;
  final TextStyle textStyle;

  factory _TuiTooltipLook.of(TermulPalette p) {
    // Light themes: deep indigo field + bone type.
    // Dark themes: raised surface + muted border.
    final bg = p.isLight ? p.deep : p.surface;
    final fg = p.isLight ? p.panel : p.text;
    return _TuiTooltipLook(
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: p.isLight ? p.deep : p.border),
      ),
      textStyle: TextStyle(
        fontFamily: TermulFonts.mono,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        height: 1.25,
        color: fg,
      ),
    );
  }
}
