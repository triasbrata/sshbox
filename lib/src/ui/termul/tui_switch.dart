// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_switch.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// The switch is a node of its own, so its label is not run together with
// the text beside it.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// Flat rectangular toggle — settings style.
class TuiSwitch extends StatelessWidget {
  const TuiSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = onChanged != null;

    final track = Semantics(
      container: true,
      toggled: value,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 52,
          height: 28,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? p.accent : p.panel,
            border: Border.all(color: value ? p.accent : p.border),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            color: value ? p.panel : (enabled ? p.dim : p.border),
          ),
        ),
      ),
    );

    if (label == null && hint == null) return track;

    return Row(
      children: [
        if (label != null || hint != null)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label != null)
                  Text(
                    label!,
                    style: Theme.of(context).textTheme.headlineMedium!
                        .copyWith(color: p.accent, fontSize: 18),
                  ),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  TuiText(hint!, tone: TuiTextTone.dim, size: 10),
                ],
              ],
            ),
          ),
        track,
      ],
    );
  }
}
