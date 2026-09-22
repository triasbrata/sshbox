// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_filter_chip.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// One option in [TuiFilterChips].
class TuiFilterOption<T> {
  const TuiFilterOption({required this.value, required this.label, this.count});

  final T value;
  final String label;

  /// Optional count shown after the label (`Tables 12`).
  final int? count;

  String get display => count == null ? label : '$label $count';
}

/// Single filter chip — active / inactive, optional count.
///
/// Sharp Termul chrome (no pill radius). Prefer [TuiFilterChips] for a row.
class TuiFilterChip extends StatefulWidget {
  const TuiFilterChip({
    super.key,
    required this.label,
    required this.selected,
    this.count,
    this.onSelected,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final int? count;
  final ValueChanged<bool>? onSelected;
  final bool enabled;

  @override
  State<TuiFilterChip> createState() => _TuiFilterChipState();
}

class _TuiFilterChipState extends State<TuiFilterChip> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final active = widget.enabled && widget.onSelected != null;
    final selected = widget.selected;

    final Color fg;
    final Color bg;
    final Color border;

    if (!active) {
      fg = p.dim;
      bg = Colors.transparent;
      border = p.border;
    } else if (selected) {
      fg = p.isLight ? p.panel : p.bg;
      bg = p.accent;
      border = p.accent;
    } else {
      fg = _hover ? p.accent : p.text;
      bg = _hover || _pressed ? p.selection : Colors.transparent;
      border = p.border;
    }

    final text = widget.count == null
        ? widget.label
        : '${widget.label} ${widget.count}';

    return Semantics(
      button: true,
      enabled: active,
      selected: selected,
      label: text,
      child: MouseRegion(
        onEnter: active ? (_) => setState(() => _hover = true) : null,
        onExit: active ? (_) => setState(() => _hover = false) : null,
        child: GestureDetector(
          onTapDown: active ? (_) => setState(() => _pressed = true) : null,
          onTapUp: active ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: active ? () => setState(() => _pressed = false) : null,
          onTap: active ? () => widget.onSelected!(!selected) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Text(
                    '✓',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 11,
                      color: fg,
                      height: 1,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: fg,
                    height: 1.2,
                  ),
                ),
                if (widget.count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${widget.count}',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 11,
                      color: selected ? fg.withValues(alpha: 0.85) : p.dim,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Multi-select filter chip row — DB object kinds, key types, etc.
///
/// Unlike [TuiSelect], any number of options may be active. Set [exclusive]
/// for single-select (Jeansh DB type filter) while keeping the same look.
class TuiFilterChips<T> extends StatelessWidget {
  const TuiFilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.exclusive = false,
    this.allowEmpty = true,
    this.enabled = true,
    this.spacing = 6,
    this.runSpacing = 6,
  });

  final List<TuiFilterOption<T>> options;

  /// Currently active values.
  final Set<T> selected;

  final ValueChanged<Set<T>>? onChanged;

  /// When true, selecting one clears the others (optional clear if [allowEmpty]).
  final bool exclusive;

  /// When false, at least one chip must stay selected.
  final bool allowEmpty;

  final bool enabled;
  final double spacing;
  final double runSpacing;

  void _toggle(T value, bool on) {
    final next = Set<T>.of(selected);
    if (exclusive) {
      if (on) {
        next
          ..clear()
          ..add(value);
      } else if (allowEmpty) {
        next.remove(value);
      }
    } else {
      if (on) {
        next.add(value);
      } else {
        if (!allowEmpty && next.length <= 1 && next.contains(value)) {
          return;
        }
        next.remove(value);
      }
    }
    onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      children: [
        for (final opt in options)
          TuiFilterChip(
            label: opt.label,
            count: opt.count,
            selected: selected.contains(opt.value),
            enabled: active,
            onSelected: active ? (on) => _toggle(opt.value, on) : null,
          ),
      ],
    );
  }
}

/// Helper label above a filter row (e.g. “Object type”).
class TuiFilterLabel extends StatelessWidget {
  const TuiFilterLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TuiText(text, tone: TuiTextTone.dim, size: 11),
    );
  }
}
