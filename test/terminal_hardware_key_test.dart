import 'dart:ui' as ui;

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
    // The key bar's keyboard button, which is the one thing that asks for the
    // soft keyboard outright — a tap no longer does. It also clears the
    // app-wide "a hardware keyboard is typing" flag another test may have set.
    input.showKeyboard();
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

  testWidgets('a tap does not raise the soft keyboard again', (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(input.hasInputConnection, isFalse);

    // The terminal is tapped, to focus a pane or to let go of a selection.
    // This used to reopen the connection, handing Android both its paths back
    // for the very next key — which is the double the user still saw, once per
    // tap. Focus, and nothing more.
    input.requestKeyboard();
    await tester.pump();
    expect(input.hasInputConnection, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    input.updateEditingValue(_inserted('b'));

    expect(sent, ['a', 'b']);
  });

  testWidgets('the keyboard button brings the soft keyboard back, and it types',
      (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(input.hasInputConnection, isFalse);

    // The tablet out of its keyboard case: the key bar's keyboard button, the
    // one ask that outranks the hardware keyboard.
    input.showKeyboard();
    await tester.pump();
    expect(input.hasInputConnection, isTrue);
    input.updateEditingValue(_inserted('b'));

    expect(sent, ['a', 'b']);
  });

  testWidgets('a hardware key after the keyboard button shuts it again',
      (tester) async {
    await pumpPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    input.showKeyboard();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(input.hasInputConnection, isFalse);
    input.updateEditingValue(_inserted('t'));

    expect(sent, ['a', '\x14']);
  });

  /// A key the soft keyboard sends as an event rather than an edit, the way
  /// Android delivers it: the key data first, then the raw message carrying
  /// what only Android knows — Gboard's KEYCODE_DEL through
  /// `InputConnection.sendKeyEvent` has FLAG_SOFT_KEYBOARD and
  /// FLAG_KEEP_TOUCH_MODE set and comes from the virtual keyboard, device -1.
  /// With [soft] false it is the same key from a real keyboard instead.
  Future<void> androidKey(LogicalKeyboardKey key, {bool soft = true}) async {
    for (final down in [true, false]) {
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(ui.KeyData(
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: PhysicalKeyboardKey.backspace.usbHidUsage,
        logical: key.keyId,
        timeStamp: Duration.zero,
        character: null,
        synthesized: false,
      ));
      final raw = KeyEventSimulator.getKeyData(key,
          platform: 'android', isDown: down)
        ..['flags'] = soft ? 0x6 : 0x8
        ..['deviceId'] = soft ? -1 : 3;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(SystemChannels.keyEvent.name,
              SystemChannels.keyEvent.codec.encodeMessage(raw), (_) {});
    }
  }

  testWidgets('a Backspace the soft keyboard sends as a key keeps it open',
      (tester) async {
    await pumpPane(tester);

    // Gboard, with nothing it believes it can delete before the caret, sends
    // Backspace as a key. Counted as a hardware keyboard, it shut the soft
    // keyboard mid-sentence.
    await androidKey(LogicalKeyboardKey.backspace);
    await androidKey(LogicalKeyboardKey.backspace);

    expect(input.hasInputConnection, isTrue);
    expect(sent, ['\x7f', '\x7f']);
  });

  testWidgets('the same Backspace from a real Android keyboard still shuts it',
      (tester) async {
    await pumpPane(tester);

    // FLAG_FROM_SYSTEM, from a keyboard device of its own.
    await androidKey(LogicalKeyboardKey.backspace, soft: false);

    expect(input.hasInputConnection, isFalse);
    expect(sent, ['\x7f']);
  });

  testWidgets('after a soft Backspace, one tap raises the keyboard',
      (tester) async {
    await pumpPane(tester);
    await androidKey(LogicalKeyboardKey.backspace);

    // The user dismisses the keyboard, then taps the terminal to type again.
    tester.testTextInput.hide();
    tester.testTextInput.log.clear();
    input.requestKeyboard();
    await tester.pump();

    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );
  });

  testWidgets('under the kitty protocol a key goes once, its release only '
      'when asked for', (tester) async {
    final session = LiveSession(
      host: const HostProfile(
          id: 'h', label: 'box', host: '10.0.2.2', username: 'me'),
    );
    addTearDown(session.dispose);
    final terminal = session.terminal;
    final out = <String>[];
    terminal.onOutput = out.add;

    void tap(TerminalKey key, {bool ctrl = false, bool shift = false}) {
      terminal.keyInput(key, ctrl: ctrl, shift: shift);
      terminal.keyInput(key,
          ctrl: ctrl, shift: shift, type: TerminalKeyEventType.release);
    }

    // Claude Code's own push: kitty flags 1 and 4, without flag 2, so a release
    // has no event type to go out with and went as the press again. In its
    // session list one Ctrl+T pinned a session and unpinned it as the key came
    // up, and Shift+Enter made two new lines.
    terminal.write('\x1b[>5u');
    tap(TerminalKey.keyT, ctrl: true);
    tap(TerminalKey.enter, shift: true);
    expect(out, ['\x1b[116;5u', '\x1b[13;2u']);

    // Flag 2 asks for releases, and they come marked as such.
    out.clear();
    terminal.write('\x1b[>7u');
    tap(TerminalKey.keyT, ctrl: true);
    expect(out, ['\x1b[116;5u', '\x1b[116;5:3u']);
  });
}
