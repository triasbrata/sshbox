// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_progress.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';

/// Visual tone for progress chrome.
enum TuiProgressTone { accent, muted, danger }

extension on TuiProgressTone {
  Color color(TermulThemeData theme) {
    final p = theme.palette;
    return switch (this) {
      TuiProgressTone.accent => p.accent,
      TuiProgressTone.muted => p.dim,
      TuiProgressTone.danger => p.isLight ? p.deep : p.red,
    };
  }
}

/// Linear progress — determinate (`value` 0–1) or indeterminate (`value` null).
///
/// Hairline track with a sharp fill. Use inside transfer rows, toolbars, and
/// page headers (git busy, file browser load, …).
class TuiProgressBar extends StatelessWidget {
  const TuiProgressBar({
    super.key,
    this.value,
    this.height = 2,
    this.tone = TuiProgressTone.accent,
  }) : assert(value == null || (value >= 0 && value <= 1));

  /// `null` = indeterminate sweep; otherwise a 0–1 fraction.
  final double? value;
  final double height;
  final TuiProgressTone tone;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final fill = tone.color(TermulThemeData.of(context));

    return Semantics(
      label: value == null
          ? 'Loading'
          : 'Progress ${(value! * 100).round()} percent',
      value: value?.toStringAsFixed(2),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: value == null
            ? _IndeterminateBar(color: fill, track: p.border, height: height)
            : DecoratedBox(
                decoration: BoxDecoration(color: p.border),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: value!.clamp(0.0, 1.0),
                    child: ColoredBox(color: fill),
                  ),
                ),
              ),
      ),
    );
  }
}

class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({
    required this.color,
    required this.track,
    required this.height,
  });

  final Color color;
  final Color track;
  final double height;

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        // Sweep a 30% block across the track.
        final t = _ctl.value;
        final start = (t * 1.3) - 0.3;
        return CustomPaint(
          painter: _SweepPainter(
            track: widget.track,
            fill: widget.color,
            start: start,
            width: 0.3,
          ),
          size: Size(double.infinity, widget.height),
        );
      },
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({
    required this.track,
    required this.fill,
    required this.start,
    required this.width,
  });

  final Color track;
  final Color fill;
  final double start;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final left = (start * size.width).clamp(-size.width, size.width);
    final w = width * size.width;
    canvas.drawRect(
      Rect.fromLTWH(left, 0, w, size.height),
      Paint()..color = fill,
    );
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) =>
      old.start != start || old.fill != fill || old.track != track;
}

/// Spinning mark — TUI glyph cycle, or a thin Material ring.
enum TuiSpinnerStyle { glyph, ring }

class TuiSpinner extends StatefulWidget {
  const TuiSpinner({
    super.key,
    this.style = TuiSpinnerStyle.glyph,
    this.size = 16,
    this.tone = TuiProgressTone.accent,
    this.label,
  });

  /// Braille spinner frames shared with [TuiProgressBanner].
  static const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  final TuiSpinnerStyle style;
  final double size;
  final TuiProgressTone tone;
  final String? label;

  @override
  State<TuiSpinner> createState() => _TuiSpinnerState();
}

class _TuiSpinnerState extends State<TuiSpinner>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctl;

  @override
  void initState() {
    super.initState();
    if (widget.style == TuiSpinnerStyle.glyph) {
      _ctl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 800),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _ctl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final color = widget.tone.color(TermulThemeData.of(context));
    final frames = TuiSpinner.frames;
    final ctl = _ctl;

    final mark = switch (widget.style) {
      TuiSpinnerStyle.ring => SizedBox(
        width: widget.size,
        height: widget.size,
        child: CircularProgressIndicator(
          strokeWidth: (widget.size / 8).clamp(1.5, 2.5),
          color: color,
        ),
      ),
      TuiSpinnerStyle.glyph => AnimatedBuilder(
        animation: ctl!,
        builder: (context, _) {
          final i = (ctl.value * frames.length).floor() % frames.length;
          return Text(
            frames[i],
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: widget.size,
              height: 1,
              color: color,
            ),
          );
        },
      ),
    };

    if (widget.label == null) {
      return Semantics(label: 'Loading', child: mark);
    }

    return Semantics(
      label: widget.label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              widget.label!,
              style: Theme.of(context).textTheme.bodyMedium!
                  .copyWith(color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Label + bar (+ optional percent) — transfer rows, save/query progress.
class TuiProgress extends StatelessWidget {
  const TuiProgress({
    super.key,
    this.label,
    this.value,
    this.showPercent = true,
    this.error = false,
    this.errorText,
    this.tone = TuiProgressTone.accent,
    this.barHeight = 2,
  });

  final String? label;

  /// `null` = indeterminate bar.
  final double? value;
  final bool showPercent;
  final bool error;
  final String? errorText;
  final TuiProgressTone tone;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final effectiveTone = error ? TuiProgressTone.danger : tone;
    final pct = value == null ? null : (value! * 100).floor();

    final title = error
        ? (errorText ?? label ?? 'Failed')
        : label == null
        ? null
        : (showPercent && pct != null ? '$label  $pct%' : label);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: error ? (p.isLight ? p.deep : p.red) : p.muted,
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (error)
          TuiProgressBar(value: 1, height: barHeight, tone: effectiveTone)
        else
          TuiProgressBar(value: value, height: barHeight, tone: effectiveTone),
      ],
    );
  }
}

/// Full-bleed status strip — home “CONNECTING…” and similar screen-level waits.
class TuiProgressBanner extends StatelessWidget {
  const TuiProgressBanner({super.key, required this.label, this.busy = true});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final ink = p.isLight ? p.bg : p.bg;
    return Container(
      color: p.accent,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          if (busy) ...[_BannerSpinner(color: ink), const SizedBox(width: 10)],
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall!
                  .copyWith(color: ink, letterSpacing: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerSpinner extends StatefulWidget {
  const _BannerSpinner({required this.color});

  final Color color;

  @override
  State<_BannerSpinner> createState() => _BannerSpinnerState();
}

class _BannerSpinnerState extends State<_BannerSpinner>
    with SingleTickerProviderStateMixin {
  static const _frames = TuiSpinner.frames;

  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final i = (_ctl.value * _frames.length).floor() % _frames.length;
        return Text(
          _frames[i],
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 12,
            height: 1,
            color: widget.color,
          ),
        );
      },
    );
  }
}
