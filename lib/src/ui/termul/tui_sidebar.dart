// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_sidebar.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_badge.dart';
import 'tui_text.dart';

class TuiWorkspace {
  const TuiWorkspace({
    required this.name,
    required this.branch,
    required this.agents,
  });

  final String name;
  final String branch;
  final List<TuiAgentRow> agents;
}

class TuiAgentRow {
  const TuiAgentRow({
    required this.name,
    required this.state,
    required this.runtime,
  });

  final String name;
  final TuiAgentState state;
  final String runtime;
}

class TuiSidebar extends StatelessWidget {
  const TuiSidebar({
    super.key,
    required this.workspaces,
    required this.selectedWorkspace,
    required this.selectedAgent,
    required this.onSelectWorkspace,
    required this.onSelectAgent,
    this.width = 240,
  });

  final List<TuiWorkspace> workspaces;
  final int selectedWorkspace;
  final int selectedAgent;
  final ValueChanged<int> onSelectWorkspace;
  final ValueChanged<int> onSelectAgent;
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                TuiText(
                  'termul',
                  tone: TuiTextTone.accent,
                  bold: true,
                  size: 14,
                ),
                const Spacer(),
                TuiBadge(label: 'TUI', tone: TuiTextTone.cyan),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TuiText('spaces', tone: TuiTextTone.dim, size: 11),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              itemCount: workspaces.length,
              itemBuilder: (context, wi) {
                final ws = workspaces[wi];
                final selected = wi == selectedWorkspace;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Row(
                      selected: selected && selectedAgent < 0,
                      onTap: () => onSelectWorkspace(wi),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TuiText(
                            ws.name,
                            bold: true,
                            size: 12,
                            tone: selected
                                ? TuiTextTone.accent
                                : TuiTextTone.normal,
                          ),
                          TuiText(ws.branch, tone: TuiTextTone.dim, size: 10),
                        ],
                      ),
                    ),
                    ...List.generate(ws.agents.length, (ai) {
                      final agent = ws.agents[ai];
                      final isSel = selected && ai == selectedAgent;
                      return _Row(
                        selected: isSel,
                        indent: 10,
                        onTap: () {
                          onSelectWorkspace(wi);
                          onSelectAgent(ai);
                        },
                        child: Row(
                          children: [
                            TuiStatusDot(state: agent.state),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TuiText(agent.name, size: 12, bold: isSel),
                                  TuiText(
                                    '${agent.state.label} · ${agent.runtime}',
                                    tone: TuiTextTone.dim,
                                    size: 10,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.child,
    required this.onTap,
    this.selected = false,
    this.indent = 0,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;
  final double indent;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final bg = widget.selected
        ? p.selection
        : (_hover ? p.surface.withValues(alpha: 0.45) : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: EdgeInsets.fromLTRB(8 + widget.indent, 6, 8, 6),
            decoration: BoxDecoration(color: bg),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
