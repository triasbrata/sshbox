// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_select.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'tui_button.dart';

/// Single-choice chip row — same interaction model as theme pickers in settings.
class TuiSelect<T> extends StatelessWidget {
  const TuiSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (v, label) in options)
          TuiButton(
            label: label,
            variant: value == v
                ? TuiButtonVariant.primary
                : TuiButtonVariant.ghost,
            onPressed: active ? () => onChanged!(v) : null,
          ),
      ],
    );
  }
}
