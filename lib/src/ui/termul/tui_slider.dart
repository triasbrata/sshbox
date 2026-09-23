// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_slider.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// Continuous (or stepped) value control — terminal font size, editor zoom.
///
/// Sharp rectangular track and square thumb. Prefer [TuiStepper] when the
/// value only moves by discrete ±steps (e.g. editor “larger / smaller text”).
class TuiSlider extends StatelessWidget {
  const TuiSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.valueLabel,
    this.onChangeEnd,
  }) : assert(min < max),
       assert(value >= min && value <= max),
       assert(divisions == null || divisions > 0);

  final double value;
  final double min;
  final double max;

  /// When set, snaps to evenly spaced stops between [min] and [max].
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Optional caption above the track (settings-style).
  final String? label;

  /// Trailing readout (e.g. `14px`). Defaults to rounded [value] when null
  /// and [label] is set.
  final String? valueLabel;

  String get _display {
    if (valueLabel != null) return valueLabel!;
    if (value == value.roundToDouble()) return '${value.round()}';
    return value.toStringAsFixed(1);
  }

  double _snap(double raw) {
    final clamped = raw.clamp(min, max);
    final d = divisions;
    if (d == null) return clamped;
    final step = (max - min) / d;
    return (min + ((clamped - min) / step).round() * step).clamp(min, max);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;

    final track = _TuiSliderTrack(
      value: value,
      min: min,
      max: max,
      enabled: enabled,
      onChanged: onChanged == null ? null : (v) => onChanged!(_snap(v)),
      onChangeEnd: onChangeEnd == null ? null : (v) => onChangeEnd!(_snap(v)),
    );

    if (label == null && valueLabel == null) return track;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (label != null)
              Expanded(
                child: TuiText(
                  label!,
                  size: 13,
                  tone: enabled ? TuiTextTone.normal : TuiTextTone.dim,
                ),
              )
            else
              const Spacer(),
            TuiText(
              _display,
              size: 13,
              tone: enabled ? TuiTextTone.accent : TuiTextTone.dim,
            ),
          ],
        ),
        const SizedBox(height: 8),
        track,
      ],
    );
  }
}

class _TuiSliderTrack extends StatefulWidget {
  const _TuiSliderTrack({
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_TuiSliderTrack> createState() => _TuiSliderTrackState();
}

class _TuiSliderTrackState extends State<_TuiSliderTrack> {
  static const _thumb = 14.0;
  static const _trackH = 4.0;
  double? _lastDx;

  double _fraction(double v) =>
      ((v - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

  double _valueAt(double dx, double width) {
    final usable = (width - _thumb).clamp(1.0, double.infinity);
    final t = ((dx - _thumb / 2) / usable).clamp(0.0, 1.0);
    return widget.min + t * (widget.max - widget.min);
  }

  void _emit(double dx, double width, {required bool end}) {
    if (!widget.enabled) return;
    _lastDx = dx;
    final v = _valueAt(dx, width);
    widget.onChanged?.call(v);
    if (end) widget.onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final fill = widget.enabled ? p.accent : p.dim;
    final track = p.border;
    final thumbFill = widget.enabled ? (p.isLight ? p.panel : p.bg) : p.surface;
    final thumbBorder = widget.enabled ? p.accent : p.border;

    return Semantics(
      slider: true,
      enabled: widget.enabled,
      value: widget.value.toStringAsFixed(2),
      increasedValue: (widget.value + 1)
          .clamp(widget.min, widget.max)
          .toString(),
      decreasedValue: (widget.value - 1)
          .clamp(widget.min, widget.max)
          .toString(),
      onIncrease: widget.enabled
          ? () {
              final cb = widget.onChanged;
              if (cb == null) return;
              cb(
                (widget.value + (widget.max - widget.min) / 20).clamp(
                  widget.min,
                  widget.max,
                ),
              );
            }
          : null,
      onDecrease: widget.enabled
          ? () {
              final cb = widget.onChanged;
              if (cb == null) return;
              cb(
                (widget.value - (widget.max - widget.min) / 20).clamp(
                  widget.min,
                  widget.max,
                ),
              );
            }
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final t = _fraction(widget.value);
          final usable = (width - _thumb).clamp(0.0, double.infinity);
          final thumbLeft = t * usable;

          return SizedBox(
            height: 28,
            width: double.infinity,
            child: GestureDetector(
              key: const Key('tui-slider-track'),
              behavior: HitTestBehavior.opaque,
              onTapDown: widget.enabled
                  ? (d) => _emit(d.localPosition.dx, width, end: true)
                  : null,
              onHorizontalDragUpdate: widget.enabled
                  ? (d) => _emit(d.localPosition.dx, width, end: false)
                  : null,
              onHorizontalDragEnd: widget.enabled
                  ? (_) => _emit(
                      _lastDx ?? thumbLeft + _thumb / 2,
                      width,
                      end: true,
                    )
                  : null,
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.centerLeft,
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _thumb / 2,
                      ),
                      child: Container(
                        height: _trackH,
                        color: track,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: t,
                          child: ColoredBox(color: fill),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: thumbLeft,
                    top: (28 - _thumb) / 2,
                    child: Container(
                      width: _thumb,
                      height: _thumb,
                      decoration: BoxDecoration(
                        color: thumbFill,
                        border: Border.all(color: thumbBorder, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Compact `[−]  value  [+]` control for discrete numeric steps.
///
/// Use for editor / tab text size where ±1 is enough. Pair with [TuiSlider]
/// when the same setting needs continuous scrubbing (terminal font size).
class TuiStepper extends StatelessWidget {
  const TuiStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.label,
    this.valueLabel,
  }) : assert(min < max),
       assert(step > 0),
       assert(value >= min && value <= max);

  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double>? onChanged;
  final String? label;
  final String? valueLabel;

  String get _display {
    if (valueLabel != null) return valueLabel!;
    if (value == value.roundToDouble()) return '${value.round()}';
    return value.toStringAsFixed(1);
  }

  void _bump(double delta) {
    final cb = onChanged;
    if (cb == null) return;
    cb((value + delta).clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final canDec = enabled && value > min;
    final canInc = enabled && value < max;

    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(
          glyph: '−',
          enabled: canDec,
          semanticLabel: 'Decrease',
          onPressed: canDec ? () => _bump(-step) : null,
        ),
        Container(
          constraints: const BoxConstraints(minWidth: 44),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: TuiText(
            _display,
            size: 13,
            tone: enabled ? TuiTextTone.accent : TuiTextTone.dim,
          ),
        ),
        _StepButton(
          glyph: '+',
          enabled: canInc,
          semanticLabel: 'Increase',
          onPressed: canInc ? () => _bump(step) : null,
        ),
      ],
    );

    if (label == null) {
      return Semantics(label: 'Stepper', value: _display, child: controls);
    }

    return Semantics(
      label: label,
      value: _display,
      child: Row(
        children: [
          Expanded(
            child: TuiText(
              label!,
              size: 13,
              tone: enabled ? TuiTextTone.normal : TuiTextTone.dim,
            ),
          ),
          controls,
        ],
      ),
    );
  }
}

class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.glyph,
    required this.enabled,
    required this.semanticLabel,
    required this.onPressed,
  });

  final String glyph;
  final bool enabled;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  var _hover = false;
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final bg = !widget.enabled
        ? p.surface
        : _pressed
        ? p.selection
        : _hover
        ? p.panel
        : p.bg;
    final border = widget.enabled ? p.border : p.border.withValues(alpha: 0.6);
    final fg = widget.enabled ? p.text : p.dim;

    return Semantics(
      container: true,
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: widget.enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onTapUp: widget.enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          onTapCancel: widget.enabled
              ? () => setState(() => _pressed = false)
              : null,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
            ),
            child: Text(
              widget.glyph,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: fg,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
