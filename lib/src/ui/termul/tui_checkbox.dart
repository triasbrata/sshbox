// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_checkbox.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// Sharp square checkbox — SQL filter rows, multi-select lists.
///
/// Prefer [TuiSwitch] for settings toggles. Use [tristate] when a parent row
/// represents a mixed selection (`value == null` → indeterminate).
class TuiCheckbox extends StatelessWidget {
  const TuiCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.tristate = false,
    this.dense = false,
  }) : assert(tristate || value != null);

  /// `true` / `false`, or `null` when [tristate] and selection is mixed.
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final String? label;

  /// Cycles unchecked → checked → indeterminate when true.
  final bool tristate;
  final bool dense;

  bool get _checked => value == true;
  bool get _indeterminate => tristate && value == null;

  void _tap() {
    final cb = onChanged;
    if (cb == null) return;
    if (!tristate) {
      cb(!(value ?? false));
      return;
    }
    // unchecked → checked → indeterminate → unchecked
    if (value == false) {
      cb(true);
    } else if (value == true) {
      cb(null);
    } else {
      cb(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = onChanged != null;
    final size = dense ? 16.0 : 18.0;

    final Color border;
    final Color fill;
    final Color mark;

    if (!enabled) {
      border = p.border;
      fill = p.surface;
      mark = p.dim;
    } else if (_checked || _indeterminate) {
      border = p.accent;
      fill = p.accent;
      mark = p.isLight ? p.panel : p.bg;
    } else {
      border = p.border;
      fill = p.panel;
      mark = p.text;
    }

    final box = Semantics(
      checked: _indeterminate ? null : _checked,
      mixed: _indeterminate,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? _tap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: 1),
          ),
          child: _checked
              ? Text(
                  '✓',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: dense ? 11 : 12,
                    fontWeight: FontWeight.w700,
                    color: mark,
                    height: 1,
                  ),
                )
              : _indeterminate
              ? Container(width: size - 8, height: 2, color: mark)
              : null,
        ),
      ),
    );

    if (label == null) return box;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _tap : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          box,
          SizedBox(width: dense ? 6 : 8),
          Flexible(
            child: TuiText(
              label!,
              size: dense ? 12 : 13,
              tone: enabled ? TuiTextTone.normal : TuiTextTone.dim,
            ),
          ),
        ],
      ),
    );
  }
}

/// Checkbox + trailing content (e.g. a filter condition row).
class TuiCheckboxRow extends StatelessWidget {
  const TuiCheckboxRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.child,
    this.tristate = false,
    this.dense = true,
  });

  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget child;
  final bool tristate;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TuiCheckbox(
          value: value,
          onChanged: onChanged,
          tristate: tristate,
          dense: dense,
        ),
        SizedBox(width: dense ? 8 : 10),
        Expanded(child: child),
      ],
    );
  }
}
