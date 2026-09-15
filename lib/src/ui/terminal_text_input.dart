import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import 'key_bar.dart' show CursorPad;

/// Owns the on-screen keyboard for the terminal.
///
/// xterm2 has a text input of its own, but it drops the two things a phone
/// keyboard uses to move the caret. Holding the space bar turns the keyboard
/// into a trackpad: iOS reports that as a floating cursor, which xterm2's
/// client ignores outright, and Android slides the selection, which it reads
/// as an insert of nothing. Running [TerminalView] with `hardwareKeyboardOnly`
/// hands the soft keyboard to this instead and leaves everything else of
/// xterm2's — hardware keys, shortcuts, selection gestures — untouched.
///
/// The connection is the soft keyboard's alone: the first hardware key shuts
/// it, and only an explicit ask — [requestKeyboard], a tap on the terminal —
/// opens it again. Held open under a hardware keyboard it is what makes one
/// press arrive twice; see [_onHardwareKey].
class TerminalTextInput extends StatefulWidget {
  const TerminalTextInput({
    super.key,
    required this.terminal,
    required this.focusNode,
    required this.child,
    this.onInput,
    this.inputType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
  });

  final Terminal terminal;

  /// Shared with the [TerminalView] below, which is what actually holds focus.
  /// This widget deliberately adds no [Focus] of its own — two of them fighting
  /// over one node is how hardware keys go missing.
  final FocusNode focusNode;

  final Widget child;

  /// Called after anything the user typed reaches the terminal, so the view
  /// can follow it down. xterm2 does this for its own input, and running with
  /// `hardwareKeyboardOnly` opts out of that along with everything else.
  final VoidCallback? onInput;

  final TextInputType inputType;

  final Brightness keyboardAppearance;

  @override
  State<TerminalTextInput> createState() => TerminalTextInputState();
}

class TerminalTextInputState extends State<TerminalTextInput>
    with TextInputClient {
  /// Spaces held either side of the caret purely so the IME has somewhere to
  /// move it. Android reports a space-bar slide by walking the selection
  /// through the buffer, so with an empty one there is nothing to report.
  static const _padding = 16;

  /// Re-centre before a slide runs into the end of the buffer.
  static const _margin = 4;

  static final _baseText = ' ' * (_padding * 2);

  static final _base = TextEditingValue(
    text: _baseText,
    selection: const TextSelection.collapsed(offset: _padding),
  );

  static const _arrows = <String, TerminalKey>{
    'A': TerminalKey.arrowUp,
    'B': TerminalKey.arrowDown,
    'C': TerminalKey.arrowRight,
    'D': TerminalKey.arrowLeft,
  };

  /// Set by the first hardware key seen anywhere in the app, and cleared by an
  /// explicit ask for the keyboard. App-wide on purpose: a keyboard plugged
  /// into the tablet types into every tab, so a new one must not raise the
  /// soft keyboard either.
  static var _hardwareKeyboard = false;

  final _pad = CursorPad();

  TextInputConnection? _connection;

  var _editingState = _base;

  /// Where the IME last put the caret, so a slide can be read as a delta.
  var _caret = _padding;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    widget.focusNode.removeListener(_onFocusChange);
    _closeConnection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  bool get hasInputConnection => _connection?.attached == true;

  /// Brings the keyboard back after it has been dismissed. The view below
  /// already holds focus at that point, so focus alone will not do it.
  ///
  /// An ask this plain — a tap on the terminal — outranks the hardware
  /// keyboard, so a tablet taken out of its keyboard case types again; the
  /// next hardware key shuts the connection right back.
  void requestKeyboard() {
    _hardwareKeyboard = false;
    if (widget.focusNode.hasFocus) {
      _openConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  /// Focus raises the keyboard only when it was asked for, the way a text
  /// field decides: a tap, a new shell, a tmux pane taking over. A tab shown
  /// again takes the keyboard token straight back, and gets focus alone,
  /// which is all a hardware keyboard needs: xterm2 reads its keys itself.
  void _onFocusChange() {
    if (!widget.focusNode.hasFocus) {
      _closeConnection();
    } else if (widget.focusNode.consumeKeyboardToken() && !_hardwareKeyboard) {
      _openConnection();
    }
  }

  /// A hardware keyboard is typing, so the soft keyboard's connection has no
  /// business being open — and holding it open is what makes one press arrive
  /// twice.
  ///
  /// Android hands every key to the IME before the app sees it. An IME that
  /// does not want a combination passes it on with
  /// `InputConnection.sendKeyEvent`, which Flutter feeds straight back into
  /// its own keyboard manager, and the platform then delivers the same press
  /// to the view as well: xterm2 reads it twice and sends its bytes twice
  /// (two ESC CR for Shift+Enter, two 0x14 for Ctrl+T). The IME may also put
  /// what it read into the editing buffer, and Flutter's keyboard manager
  /// hands any key the framework leaves unhandled to the input connection,
  /// which inserts it as text. All three need a live connection.
  ///
  /// Only watches: the key still goes wherever it was going.
  bool _onHardwareKey(KeyEvent event) {
    _hardwareKeyboard = true;
    _closeConnection();
    return false;
  }

  void _openConnection() {
    if (hasInputConnection) {
      _connection!.show();
      return;
    }

    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: View.maybeOf(context)?.viewId,
        inputType: widget.inputType,
        inputAction: TextInputAction.newline,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );

    _connection!.show();
    _resetEditingState();
  }

  void _closeConnection() {
    if (hasInputConnection) _connection!.close();
    _connection = null;
  }

  void _resetEditingState() {
    _editingState = _base;
    _caret = _padding;
    _connection?.setEditingState(_base);
  }

  // TextInputClient ---------------------------------------------------------

  @override
  TextEditingValue? get currentTextEditingValue => _editingState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    // An edit that crossed the connection being closed belongs to a keystroke
    // xterm2 has already dealt with. Without a connection there is no editing
    // session to speak for, so there is nothing to send.
    if (!hasInputConnection) return;
    _editingState = value;

    // Nothing is committed until the IME finishes composing, so reading a
    // half-built character out of the buffer would send it twice.
    if (!value.composing.isCollapsed) return;

    final growth = value.text.length - _baseText.length;

    if (growth == 0) {
      _slideCaret(value);
      return;
    }

    if (growth < 0) {
      for (var i = 0; i < -growth; i++) {
        widget.terminal.keyInput(TerminalKey.backspace);
      }
    } else {
      // Every insert here is the soft keyboard's own, hardware keys having
      // shut the connection, so it goes as it came — a pasted newline
      // included.
      widget.terminal.textInput(_insertedText(value.text, growth));
    }

    widget.onInput?.call();
    _resetEditingState();
  }

  /// The run the IME added, found by walking in from the left until the buffer
  /// stops matching the padding. Reading the selection instead would be
  /// shorter, but IMEs are free to leave it unset.
  String _insertedText(String text, int growth) {
    var start = 0;
    while (start < _baseText.length && text[start] == _baseText[start]) {
      start++;
    }
    return text.substring(start, start + growth);
  }

  /// A same-length edit means the IME moved the caret rather than typing —
  /// which on Android is the space bar being used as a trackpad.
  void _slideCaret(TextEditingValue value) {
    final caret = value.selection.baseOffset;
    if (caret < 0 || caret == _caret) return;

    final steps = caret - _caret;
    _caret = caret;

    final key = steps > 0 ? TerminalKey.arrowRight : TerminalKey.arrowLeft;
    for (var i = 0; i < steps.abs(); i++) {
      widget.terminal.keyInput(key);
    }

    if (caret < _margin || caret > _baseText.length - _margin) {
      _resetEditingState();
    }
  }

  /// iOS reports a held space bar here, as a drag measured from where the
  /// finger started — which is exactly what [CursorPad] expects.
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
      case FloatingCursorDragState.End:
        _pad.reset();
      case FloatingCursorDragState.Update:
        for (final step in _pad.advance(point.offset ?? Offset.zero)) {
          final key = _arrows[step];
          if (key != null) widget.terminal.keyInput(key);
        }
    }
  }

  @override
  void performAction(TextInputAction action) {
    // Android turns a hardware Enter the framework left unhandled into this
    // too; with the connection shut it is xterm2's key alone.
    if (!hasInputConnection) return;
    if (action == TextInputAction.done || action == TextInputAction.newline) {
      widget.terminal.keyInput(TerminalKey.enter);
      widget.onInput?.call();
    }
  }

  @override
  void connectionClosed() => _connection = null;

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}
}
