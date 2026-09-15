import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/terminal_text_input.dart';
import 'package:xterm2/xterm.dart';

/// The padding [TerminalTextInput] keeps either side of the caret.
const _padding = 16;

/// The buffer Android hands back when the IME has inserted [text].
TextEditingValue _inserted(String text) => TextEditingValue(
      text: '${' ' * _padding}$text${' ' * _padding}',
      selection: TextSelection.collapsed(offset: _padding + text.length),
    );

void main() {
  // The pane as TerminalPage builds it: TerminalTextInput (which owns the soft
  // keyboard's IME connection) over TerminalView (which reads hardware keys),
  // sharing one FocusNode.
  //
  // With a hardware keyboard and that connection open, one press arrived
  // twice. Android gives every key to the IME before the app sees it: an IME
  // that does not want a combination passes it on with
  // InputConnection.sendKeyEvent, which Flutter feeds back into its own
  // keyboard manager, and the platform then delivers the same press to the
  // view as well — the engine turns that second delivery into a whole second
  // press, so xterm2 sent its bytes twice (two ESC CR for Shift+Enter, two
  // 0x14 for Ctrl+T). An IME may also commit what it read into the editing
  // buffer, which came back as text on top.
  //
  // WidgetTester drives neither the platform IME nor Android's dispatch, so
  // each test opens the connection the way a tap does — the worst case — then
  // sends the hardware key and replays the IME half by hand, calling
  // updateEditingValue and performAction the way Android delivers them. What
  // the fix has to do is shut that connection, leaving the IME nothing to
  // speak through.
  late List<String> sent;
  late TerminalTextInputState input;

  Future<void> pumpPane(WidgetTester tester) async {
    final session = LiveSession(
      host: const HostProfile(
          id: 'h', label: 'box', host: '10.0.2.2', username: 'me'),
    );
    addTearDown(session.dispose);
    sent = [];
    session.terminal.onOutput = sent.add;

    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final key = GlobalKey<TerminalTextInputState>();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalTextInput(
          key: key,
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

    input = key.currentState!;
    // A tap on the terminal, which is the one thing that asks for the soft
    // keyboard outright. It also clears the app-wide "a hardware keyboard is
    // typing" flag another test may have set.
    input.requestKeyboard();
    await tester.pump();
    expect(input.hasInputConnection, isTrue);
  }

  testWidgets('hardware Ctrl+T sends its one byte, not a stray t',
      (tester) async {
    await pumpPane(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(input.hasInputConnection, isFalse);
    // Android's key map ignores the control bit, so an IME reads Ctrl+T as the
    // character 't' and would commit it here.
    input.updateEditingValue(_inserted('t'));

    expect(sent, ['\x14']);
  });

  testWidgets('hardware Shift+Enter sends ESC CR once', (tester) async {
    await pumpPane(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(input.hasInputConnection, isFalse);
    // The same press as Android's IME also delivers it: a '\n' in the buffer.
    input.updateEditingValue(_inserted('\n'));

    expect(sent, ['\x1b\r']);
  });

  testWidgets('a plain hardware letter arrives once', (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);

    expect(input.hasInputConnection, isFalse);
    input.updateEditingValue(_inserted('a'));

    expect(sent, ['a']);
  });

  testWidgets('plain hardware Enter sends CR once', (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(input.hasInputConnection, isFalse);
    // Android turns an Enter the framework left unhandled into an editor
    // action on a single-line field, which arrives here.
    input.performAction(TextInputAction.newline);

    expect(sent, ['\r']);
  });

  testWidgets('the soft keyboard still types', (tester) async {
    await pumpPane(tester);

    input.updateEditingValue(_inserted('ls -la'));
    input.performAction(TextInputAction.newline);

    expect(sent, ['ls -la', '\r']);
    expect(input.hasInputConnection, isTrue);
  });

  testWidgets('a tap brings the soft keyboard back after a hardware key',
      (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(input.hasInputConnection, isFalse);

    // The tablet out of its keyboard case: the terminal is tapped and types
    // through the IME again.
    input.requestKeyboard();
    await tester.pump();
    input.updateEditingValue(_inserted('b'));

    expect(sent, ['a', 'b']);
  });
}
