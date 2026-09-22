// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_button.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// The label's accessibility text is the label as written, not the
// upper-cased one drawn, so a finder or a screen reader reads the word;
// and the button is a node of its own, so that word is not run together
// with the text beside it.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

enum TuiButtonVariant { primary, ghost, danger }

/// Tappable chrome control — paper primary on light themes.
class TuiButton extends StatefulWidget {
  const TuiButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = TuiButtonVariant.primary,
    this.prefix,
  });

  final String label;
  final VoidCallback? onPressed;
  final TuiButtonVariant variant;
  final String? prefix;

  @override
  State<TuiButton> createState() => _TuiButtonState();
}

class _TuiButtonState extends State<TuiButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = widget.onPressed != null;

    // Light primary: paper fill + ink label + indigo mark square.
    // Dark themes keep filled accent primary.
    final lightPrimary =
        p.isLight && widget.variant == TuiButtonVariant.primary;

    late final Color fg;
    late final Color bg;
    late final Color border;

    switch (widget.variant) {
      case TuiButtonVariant.primary:
        if (lightPrimary) {
          fg = enabled ? p.text : p.dim;
          bg = enabled ? (_hover ? p.bg : p.panel) : p.bg;
          border = Colors.transparent;
        } else {
          fg = p.bg;
          bg = enabled
              ? (_pressed
                    ? p.accent.withValues(alpha: 0.85)
                    : (_hover ? p.accent.withValues(alpha: 0.92) : p.accent))
              : p.dim;
          border = bg;
        }
      case TuiButtonVariant.ghost:
        fg = enabled ? (p.isLight ? p.accent : p.text) : p.dim;
        bg = _hover && enabled ? p.selection : Colors.transparent;
        border = p.border;
      case TuiButtonVariant.danger:
        fg = p.isLight ? p.panel : p.bg;
        bg = enabled ? p.deep : p.dim;
        border = bg;
    }

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.only(
                    left: lightPrimary ? 12 : 12,
                    right: lightPrimary ? 8 : 12,
                    top: 6,
                    bottom: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.prefix != null && !lightPrimary) ...[
                        Text(
                          widget.prefix!,
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            color: fg,
                            fontSize: 11,
                            height: 1.2,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        widget.label.toUpperCase(),
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          color: fg,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (lightPrimary)
                  Container(
                    width: 28,
                    height: 28,
                    color: enabled ? p.accent : p.dim,
                    alignment: Alignment.center,
                    child: Text(
                      widget.prefix ?? '/',
                      style: TextStyle(
                        fontFamily: TermulFonts.display,
                        color: p.panel,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keyboard chord hint: boxed keys + dim action label.
class TuiKeyHint extends StatelessWidget {
  const TuiKeyHint({super.key, required this.keys, required this.label});

  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      label: '$keys $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: p.border),
              color: p.surface,
            ),
            child: TuiText(
              keys,
              tone: TuiTextTone.accent,
              size: 11,
              bold: true,
            ),
          ),
          const SizedBox(width: 6),
          TuiText(label, tone: TuiTextTone.dim, size: 11),
        ],
      ),
    );
  }
}
