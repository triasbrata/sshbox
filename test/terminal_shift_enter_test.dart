import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/terminal_text_input.dart';
import 'package:xterm2/xterm.dart';

void main() {
  // The pane wires TerminalTextInput (the soft-keyboard IME) over TerminalView
  // (the hardware keys), sharing one FocusNode, exactly as TerminalPage builds
  // it. On a tablet with a hardware keyboard both paths are live at once, so a
  // single Shift+Enter arrives twice: xterm2 turns the key into ESC CR, and
  // Android also inserts a '\n' into the IME buffer for the same press.
  //
  // WidgetTester's key events drive only the xterm2 path, so the IME half is
  // reproduced by calling updateEditingValue the way Android delivers it.
  testWidgets('hardware Shift+Enter yields ESC CR once, not doubled',
      (tester) async {
    final session = LiveSession(
      host: const HostProfile(
          id: 'h', label: 'box', host: '10.0.2.2', username: 'me'),
    );
    addTearDown(session.dispose);
    final sent = <String>[];
    session.terminal.onOutput = sent.add;

    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalTextInput(
          terminal: session.terminal,
          focusNode: focusNode,
          child: TerminalView(
            session.terminal,
            focusNode: focusNode,
            autofocus: true,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );

    // The hardware key, as xterm2 reads it: ESC CR.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    // The same press, as Android's open IME connection also delivers it: a
    // '\n' inserted into the padded editing buffer (_padding is 16 spaces).
    const pad = 16;
    tester
        .state<TerminalTextInputState>(find.byType(TerminalTextInput))
        .updateEditingValue(TextEditingValue(
          text: '${' ' * pad}\n${' ' * pad}',
          selection: const TextSelection.collapsed(offset: pad + 1),
        ));

    expect(sent, ['\x1b\r']);
  });
}
