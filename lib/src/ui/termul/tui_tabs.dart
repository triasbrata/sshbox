// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_tabs.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

class TuiTabs extends StatelessWidget {
  const TuiTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            _Tab(
              label: tabs[i],
              selected: i == index,
              onTap: () => onChanged(i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: TuiText('+ split', tone: TuiTextTone.dim, size: 11),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: widget.label,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? p.panel
                  : (_hover
                        ? p.surface.withValues(alpha: 0.4)
                        : Colors.transparent),
              border: Border(
                bottom: BorderSide(
                  color: widget.selected ? p.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: TuiText(
              widget.label,
              size: 12,
              bold: widget.selected,
              tone: widget.selected ? TuiTextTone.accent : TuiTextTone.muted,
            ),
          ),
        ),
      ),
    );
  }
}
