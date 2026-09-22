// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_terminal_keyboard.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'termul_theme.dart';

enum TermKey {
  char,
  space,
  backspace,
  enter,
  escape,
  tab,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  shift,
  ctrl,
  hide,
}

/// On-screen terminal keyboard — flat / mono chrome.
/// Suppresses the system soft keyboard; drive a [TextEditingController] instead.
class TuiTerminalKeyboard extends StatefulWidget {
  const TuiTerminalKeyboard({
    super.key,
    required this.controller,
    this.onEnter,
    this.onHide,
    this.onArrowUp,
    this.onArrowDown,
  });

  final TextEditingController controller;
  final VoidCallback? onEnter;
  final VoidCallback? onHide;

  /// Optional history hooks (defaults to cursor line-start / line-end).
  final VoidCallback? onArrowUp;
  final VoidCallback? onArrowDown;

  @override
  State<TuiTerminalKeyboard> createState() => _TuiTerminalKeyboardState();
}

class _TuiTerminalKeyboardState extends State<TuiTerminalKeyboard> {
  bool _shift = false;
  bool _ctrl = false;

  static const _row1 = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
  static const _row2 = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
  static const _row3 = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _punct = ['-', '_', '/', '.', '@', ':'];

  void _insert(String text) {
    final c = widget.controller;
    final sel = c.selection;
    final start = sel.start >= 0 ? sel.start : c.text.length;
    final end = sel.end >= 0 ? sel.end : c.text.length;
    final next = c.text.replaceRange(start, end, text);
    final caret = start + text.length;
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    HapticFeedback.selectionClick();
  }

  void _backspace() {
    final c = widget.controller;
    final sel = c.selection;
    if (!sel.isValid) return;
    if (!sel.isCollapsed) {
      _insert('');
      return;
    }
    if (sel.start == 0) return;
    final start = sel.start - 1;
    final next = c.text.replaceRange(start, sel.start, '');
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start),
    );
    HapticFeedback.selectionClick();
  }

  void _move(int delta) {
    final c = widget.controller;
    final sel = c.selection;
    final base = sel.isValid ? sel.baseOffset : c.text.length;
    final pos = (base + delta).clamp(0, c.text.length);
    c.selection = TextSelection.collapsed(offset: pos);
    HapticFeedback.selectionClick();
  }

  void _handle(TermKey kind, [String? char]) {
    switch (kind) {
      case TermKey.char:
        var s = char ?? '';
        if (_shift) s = s.toUpperCase();
        if (_ctrl && s.isNotEmpty) {
          // Insert caret notation for preview, e.g. ^C
          _insert('^${s.toUpperCase()}');
          setState(() => _ctrl = false);
          return;
        }
        _insert(s);
        if (_shift) setState(() => _shift = false);
      case TermKey.space:
        _insert(' ');
      case TermKey.backspace:
        _backspace();
      case TermKey.enter:
        widget.onEnter?.call();
        HapticFeedback.mediumImpact();
      case TermKey.escape:
        _insert('\u001b');
      case TermKey.tab:
        _insert('\t');
      case TermKey.arrowLeft:
        _move(-1);
      case TermKey.arrowRight:
        _move(1);
      case TermKey.arrowUp:
        if (widget.onArrowUp != null) {
          widget.onArrowUp!();
        } else {
          widget.controller.selection = const TextSelection.collapsed(
            offset: 0,
          );
        }
        HapticFeedback.selectionClick();
      case TermKey.arrowDown:
        if (widget.onArrowDown != null) {
          widget.onArrowDown!();
        } else {
          final len = widget.controller.text.length;
          widget.controller.selection = TextSelection.collapsed(offset: len);
        }
        HapticFeedback.selectionClick();
      case TermKey.shift:
        setState(() => _shift = !_shift);
      case TermKey.ctrl:
        setState(() => _ctrl = !_ctrl);
      case TermKey.hide:
        widget.onHide?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Material(
      color: p.sidebar,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        // Safe-area bottom is handled by the mode bar below this keyboard.
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _KeyRow(
              children: [
                for (final s in _digits)
                  _Key(label: s, onTap: () => _handle(TermKey.char, s)),
              ],
            ),
            _KeyRow(
              children: [
                for (final s in _punct)
                  _Key(label: s, onTap: () => _handle(TermKey.char, s)),
              ],
            ),
            _KeyRow(
              children: [
                for (final s in _row1)
                  _Key(
                    label: _shift ? s.toUpperCase() : s,
                    onTap: () => _handle(TermKey.char, s),
                  ),
              ],
            ),
            _KeyRow(
              children: [
                for (final s in _row2)
                  _Key(
                    label: _shift ? s.toUpperCase() : s,
                    onTap: () => _handle(TermKey.char, s),
                  ),
              ],
            ),
            _KeyRow(
              children: [
                _Key(
                  label: '⇧',
                  flex: 14,
                  active: _shift,
                  onTap: () => _handle(TermKey.shift),
                ),
                for (final s in _row3)
                  _Key(
                    label: _shift ? s.toUpperCase() : s,
                    onTap: () => _handle(TermKey.char, s),
                  ),
                _Key(
                  label: '⌫',
                  flex: 14,
                  onTap: () => _handle(TermKey.backspace),
                ),
              ],
            ),
            _KeyRow(
              children: [
                _Key(
                  label: 'CTRL',
                  flex: 12,
                  active: _ctrl,
                  onTap: () => _handle(TermKey.ctrl),
                ),
                _Key(
                  label: 'ESC',
                  flex: 10,
                  onTap: () => _handle(TermKey.escape),
                ),
                _Key(label: 'TAB', flex: 10, onTap: () => _handle(TermKey.tab)),
                _Key(
                  label: 'SPACE',
                  flex: 28,
                  onTap: () => _handle(TermKey.space),
                ),
                _Key(
                  label: '←',
                  flex: 9,
                  onTap: () => _handle(TermKey.arrowLeft),
                ),
                _Key(
                  label: '↑',
                  flex: 9,
                  onTap: () => _handle(TermKey.arrowUp),
                ),
                _Key(
                  label: '↓',
                  flex: 9,
                  onTap: () => _handle(TermKey.arrowDown),
                ),
                _Key(
                  label: '→',
                  flex: 9,
                  onTap: () => _handle(TermKey.arrowRight),
                ),
                _Key(
                  label: '⏎',
                  flex: 12,
                  accent: true,
                  onTap: () => _handle(TermKey.enter),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(children: children),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onTap,
    this.flex = 10,
    this.active = false,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final bool active;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final bg = accent
        ? p.accent
        : (active ? p.accent.withValues(alpha: 0.2) : p.panel);
    final fg = accent ? p.bg : (active ? p.accent : p.text);

    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: bg,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: label,
            child: Container(
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border.all(color: p.border)),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: label.length > 2 ? 10 : 13,
                  fontWeight: FontWeight.w500,
                  color: fg,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Expanded(flex: flex, child: child);
  }
}
