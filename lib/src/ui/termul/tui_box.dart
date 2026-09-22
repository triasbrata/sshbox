// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_box.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// Box-drawing panel frame: ┌─┐ / │ │ / └─┘
class TuiBox extends StatelessWidget {
  const TuiBox({
    super.key,
    required this.child,
    this.title,
    this.footer,
    this.padding = const EdgeInsets.all(10),
    this.fill,
    this.expanded = true,
  });

  final Widget child;
  final String? title;
  final String? footer;
  final EdgeInsets padding;
  final Color? fill;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final border = p.border;
    final bg = fill ?? p.panel;

    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border.symmetric(vertical: BorderSide(color: border)),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBorder(title: title, color: border, accent: p.accent),
          Expanded(child: body),
          _BottomBorder(footer: footer, color: border, muted: p.dim),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBorder(title: title, color: border, accent: p.accent),
        body,
        _BottomBorder(footer: footer, color: border, muted: p.dim),
      ],
    );
  }
}

class _TopBorder extends StatelessWidget {
  const _TopBorder({
    required this.title,
    required this.color,
    required this.accent,
  });

  final String? title;
  final Color color;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: CustomPaint(
        painter: _HBorderPainter(
          color: color,
          top: true,
          label: title,
          labelColor: accent,
        ),
        child: title == null
            ? null
            : Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: TuiText(
                    ' $title ',
                    tone: TuiTextTone.accent,
                    size: 11,
                    bold: true,
                  ),
                ),
              ),
      ),
    );
  }
}

class _BottomBorder extends StatelessWidget {
  const _BottomBorder({
    required this.footer,
    required this.color,
    required this.muted,
  });

  final String? footer;
  final Color color;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: CustomPaint(
        painter: _HBorderPainter(
          color: color,
          top: false,
          label: footer,
          labelColor: muted,
        ),
        child: footer == null
            ? null
            : Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TuiText(footer!, tone: TuiTextTone.dim, size: 11),
                ),
              ),
      ),
    );
  }
}

class _HBorderPainter extends CustomPainter {
  _HBorderPainter({
    required this.color,
    required this.top,
    this.label,
    this.labelColor,
  });

  final Color color;
  final bool top;
  final String? label;
  final Color? labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final y = top ? size.height - 0.5 : 0.5;
    final left = Offset(0, y);
    final right = Offset(size.width, y);
    canvas.drawLine(left, right, paint);

    // Corner glyphs as short vertical stubs
    if (top) {
      canvas.drawLine(Offset(0.5, size.height), Offset(0.5, 4), paint);
      canvas.drawLine(
        Offset(size.width - 0.5, size.height),
        Offset(size.width - 0.5, 4),
        paint,
      );
    } else {
      canvas.drawLine(Offset(0.5, 0), Offset(0.5, size.height - 4), paint);
      canvas.drawLine(
        Offset(size.width - 0.5, 0),
        Offset(size.width - 0.5, size.height - 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.label != label;
}
