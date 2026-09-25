// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_input.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

class TuiInput extends StatefulWidget {
  const TuiInput({
    super.key,
    this.controller,
    this.prompt = '❯',
    this.hint = '',
    this.onSubmitted,
    this.autofocus = false,
    this.focusNode,
    this.keyboardType,
    this.textInputAction = TextInputAction.send,

    /// When true, blocks the OS soft keyboard (use with [TuiTerminalKeyboard]).
    this.useCustomKeyboard = false,
    this.onTap,
  });

  final TextEditingController? controller;
  final String prompt;
  final String hint;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final bool useCustomKeyboard;
  final VoidCallback? onTap;

  @override
  State<TuiInput> createState() => _TuiInputState();
}

class _TuiInputState extends State<TuiInput> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  bool _ownedController = false;
  bool _ownedFocus = false;

  @override
  void initState() {
    super.initState();
    _ownedController = widget.controller == null;
    _ownedFocus = widget.focusNode == null;
    _controller = widget.controller ?? TextEditingController();
    _focus = widget.focusNode ?? FocusNode();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    if (_ownedFocus) _focus.dispose();
    if (_ownedController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final focused = _focus.hasFocus;

    return Semantics(
      textField: true,
      label: widget.hint.isNotEmpty ? widget.hint : 'command input',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: p.sidebar,
          border: Border.all(color: focused ? p.accent : p.border),
        ),
        child: Row(
          children: [
            TuiText(widget.prompt, tone: TuiTextTone.accent, bold: true),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                // Hide OS keyboard when driving a custom terminal keyboard.
                keyboardType: widget.useCustomKeyboard
                    ? TextInputType.none
                    : (widget.keyboardType ?? TextInputType.text),
                textInputAction: widget.textInputAction,
                showCursor: true,
                enableInteractiveSelection: true,
                cursorColor: p.accent,
                cursorWidth: 8,
                cursorHeight: 14,
                style: TextStyle(
                  color: p.text,
                  fontSize: 13,
                  fontFamily: TermulFonts.mono,
                  height: 1.3,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: p.dim, fontSize: 13),
                  contentPadding: EdgeInsets.zero,
                ),
                onTap: () {
                  _focus.requestFocus();
                  widget.onTap?.call();
                },
                onSubmitted: widget.onSubmitted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
