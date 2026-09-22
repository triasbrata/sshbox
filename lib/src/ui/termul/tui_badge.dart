// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_badge.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

enum TuiAgentState { working, blocked, done, idle, unknown }

extension TuiAgentStateX on TuiAgentState {
  String get glyph => switch (this) {
    TuiAgentState.working => '●',
    TuiAgentState.blocked => '◉',
    TuiAgentState.done => '●',
    TuiAgentState.idle => '○',
    TuiAgentState.unknown => '·',
  };

  String get label => name;

  TuiTextTone get tone => switch (this) {
    TuiAgentState.working => TuiTextTone.green,
    TuiAgentState.blocked => TuiTextTone.yellow,
    TuiAgentState.done => TuiTextTone.blue,
    TuiAgentState.idle => TuiTextTone.dim,
    TuiAgentState.unknown => TuiTextTone.muted,
  };
}

/// Agent/runtime status glyph with optional text label.
class TuiStatusDot extends StatelessWidget {
  const TuiStatusDot({super.key, required this.state, this.showLabel = false});

  final TuiAgentState state;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: showLabel ? '${state.label} agent' : '${state.label} status',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TuiText(state.glyph, tone: state.tone, size: 12, bold: true),
          if (showLabel) ...[
            const SizedBox(width: 6),
            TuiText(state.label, tone: state.tone, size: 11),
          ],
        ],
      ),
    );
  }
}

/// Small outlined tag for model names, keys, or meta labels.
class TuiBadge extends StatelessWidget {
  const TuiBadge({
    super.key,
    required this.label,
    this.tone = TuiTextTone.muted,
  });

  final String label;
  final TuiTextTone tone;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(color: p.border),
        ),
        child: TuiText(label, tone: tone, size: 10, bold: true),
      ),
    );
  }
}

/// Numeric counter chip — unread counts, tab badges.
class TuiCountBadge extends StatelessWidget {
  const TuiCountBadge({super.key, required this.count, this.max = 99});

  final int count;
  final int max;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    if (count <= 0) return const SizedBox.shrink();
    final text = count > max ? '$max+' : '$count';
    return Semantics(
      label: '$count items',
      child: Container(
        constraints: const BoxConstraints(minWidth: 18),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: p.accent,
          border: Border.all(color: p.accent),
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: p.isLight ? p.panel : p.bg,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
