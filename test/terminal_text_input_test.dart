import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/terminal_paste.dart';
import 'package:sshbox/src/ui/terminal_text_input.dart';
import 'package:xterm2/xterm.dart';

/// The buffer the input keeps for the IME to move a caret through: padding
/// either side of the caret, which sits in the middle.
const _padding = 16;
final _baseText = ' ' * (_padding * 2);

TextEditingValue _value(String text, int caret) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );

void main() {
  late Terminal terminal;
  late List<String> sent;
  late TerminalTextInputState input;

  /// Mounts the widget the way [TerminalPage] does — the focus node belongs to
  /// the child, and this adds no [Focus] of its own.
  Future<void> pumpInput(
    WidgetTester tester, {
    void Function(KeyboardInsertedContent content)? onContent,
  }) async {
    final key = GlobalKey<TerminalTextInputState>();
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    terminal = Terminal();
    sent = [];
    terminal.onOutput = sent.add;

    await tester.pumpWidget(
      TerminalTextInput(
        key: key,
        terminal: terminal,
        focusNode: focusNode,
        onContent: onContent,
        child: Focus(focusNode: focusNode, child: const SizedBox()),
      ),
    );

    input = key.currentState!;
    // The key bar's keyboard button: the IME connection every test below
    // speaks through, opened the one way that works whether or not a hardware
    // keyboard has typed.
    input.showKeyboard();
    await tester.pump();
  }

  group('floating cursor — a held space bar on iOS', () {
    testWidgets('walks the caret right as the finger travels', (tester) async {
      await pumpInput(tester);

      input.updateFloatingCursor(
        RawFloatingCursorPoint(state: FloatingCursorDragState.Start),
      );
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: const Offset(60, 0),
      ));

      expect(sent, ['\x1b[C', '\x1b[C', '\x1b[C']);
    });

    testWidgets('walks it back when the finger returns', (tester) async {
      await pumpInput(tester);

      input.updateFloatingCursor(
        RawFloatingCursorPoint(state: FloatingCursorDragState.Start),
      );
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: const Offset(40, 0),
      ));
      sent.clear();
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: Offset.zero,
      ));

      expect(sent, ['\x1b[D', '\x1b[D']);
    });

    testWidgets('moves up and down too', (tester) async {
      await pumpInput(tester);

      input.updateFloatingCursor(
        RawFloatingCursorPoint(state: FloatingCursorDragState.Start),
      );
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: const Offset(0, 28),
      ));

      expect(sent, ['\x1b[B']);
    });

    testWidgets('starts from scratch on the next gesture', (tester) async {
      await pumpInput(tester);

      for (final state in [
        FloatingCursorDragState.Start,
        FloatingCursorDragState.End,
      ]) {
        input.updateFloatingCursor(RawFloatingCursorPoint(state: state));
      }
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Start,
      ));
      sent.clear();
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: const Offset(20, 0),
      ));

      expect(sent, ['\x1b[C']);
    });

    testWidgets('respects the application cursor key mode', (tester) async {
      await pumpInput(tester);
      // What vim, less and tmux switch on; CSI there prints stray characters.
      terminal.write('\x1b[?1h');

      input.updateFloatingCursor(
        RawFloatingCursorPoint(state: FloatingCursorDragState.Start),
      );
      input.updateFloatingCursor(RawFloatingCursorPoint(
        state: FloatingCursorDragState.Update,
        offset: const Offset(20, 0),
      ));

      expect(sent, ['\x1bOC']);
    });
  });

  group('caret slide — a held space bar on Android', () {
    testWidgets('reads a selection walked left as left arrows',
        (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(_value(_baseText, _padding - 3));

      expect(sent, ['\x1b[D', '\x1b[D', '\x1b[D']);
    });

    testWidgets('reads a selection walked right as right arrows',
        (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(_value(_baseText, _padding + 2));

      expect(sent, ['\x1b[C', '\x1b[C']);
    });

    testWidgets('tracks the slide as a running delta, not a jump',
        (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(_value(_baseText, _padding + 1));
      input.updateEditingValue(_value(_baseText, _padding + 2));
      input.updateEditingValue(_value(_baseText, _padding + 3));

      expect(sent, ['\x1b[C', '\x1b[C', '\x1b[C']);
    });

    testWidgets('says nothing when the caret has not moved', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(_value(_baseText, _padding));

      expect(sent, isEmpty);
    });

    testWidgets('re-centres before a slide runs off the end', (tester) async {
      await pumpInput(tester);

      // Far enough left to be inside the margin, so the buffer resets and the
      // next slide is measured from the middle again.
      input.updateEditingValue(_value(_baseText, 1));
      sent.clear();
      input.updateEditingValue(_value(_baseText, _padding + 1));

      expect(sent, ['\x1b[C']);
    });
  });

  group('typing', () {
    testWidgets('sends a character the keyboard inserted', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(
        _value('${' ' * _padding}a${' ' * _padding}', _padding + 1),
      );

      expect(sent, ['a']);
    });

    testWidgets('sends a run pasted in one go', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(
        _value('${' ' * _padding}ls -la${' ' * _padding}', _padding + 6),
      );

      expect(sent, ['ls -la']);
    });

    testWidgets('a desktop IME committing a whole command sends its spaces',
        (tester) async {
      await pumpInput(tester);
      const command = 'git push origin --delete some-branch';

      input.updateEditingValue(_value(
        '${' ' * _padding}$command${' ' * _padding}',
        _padding + command.length,
      ));

      expect(sent, [command]);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('sends a space, which looks like padding but is not',
        (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(_value('$_baseText ', _padding + 1));

      expect(sent, [' ']);
    });

    testWidgets('keeps the space a run begins with', (tester) async {
      await pumpInput(tester);

      // Gboard commits a paste a word at a time, each chunk arriving with the
      // space in front of it. Read by scanning past the padding, that space
      // was skipped and the slice slid into the trailing padding: `world `.
      input.updateEditingValue(
        _value('${' ' * _padding} world${' ' * _padding}', _padding + 6),
      );

      expect(sent, [' world']);
    });

    testWidgets('keeps the space a run ends with', (tester) async {
      await pumpInput(tester);

      // The other way round, and the reason the caret decides: ` world` at the
      // caret and `world ` a space earlier leave the same buffer behind.
      input.updateEditingValue(
        _value('${' ' * _padding}world ${' ' * _padding}', _padding + 6),
      );

      expect(sent, ['world ']);
    });

    testWidgets('keeps every space of a sentence pasted word by word',
        (tester) async {
      await pumpInput(tester);

      for (final chunk in [
        'tinggal',
        ' buka',
        ' lagi',
        ' dan pane tmux-nya masih di',
        ' tempat.',
      ]) {
        input.updateEditingValue(_value(
          '${' ' * _padding}$chunk${' ' * _padding}',
          _padding + chunk.length,
        ));
      }

      expect(sent.join(), 'tinggal buka lagi dan pane tmux-nya masih di '
          'tempat.');
    });

    testWidgets('reads a run inserted where a slide left the caret',
        (tester) async {
      await pumpInput(tester);

      // A slide short of the margin does not re-centre, so the next insert
      // lands two to the right of the middle.
      input.updateEditingValue(_value(_baseText, _padding + 2));
      sent.clear();
      input.updateEditingValue(_value(
        '${' ' * (_padding + 2)} ls${' ' * (_padding - 2)}',
        _padding + 5,
      ));

      expect(sent, [' ls']);
    });

    testWidgets('sends what changed when the IME replaced part of the padding',
        (tester) async {
      await pumpInput(tester);

      // Four padding characters gone, `cukup` in their place: no offset leaves
      // the padding whole, so the run is not six characters long wherever it
      // is read from.
      input.updateEditingValue(_value(
        '${' ' * _padding}cukup${' ' * (_padding - 4)}',
        _padding + 5,
      ));

      expect(sent, ['cukup']);
    });

    testWidgets('sends backspace when the buffer shrinks', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(
        _value(_baseText.substring(1), _padding - 1),
      );

      expect(sent, ['\x7f']);
    });

    testWidgets('waits for the IME to finish composing', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(TextEditingValue(
        text: '${' ' * _padding}n${' ' * _padding}',
        selection: TextSelection.collapsed(offset: _padding + 1),
        composing: TextRange(start: _padding, end: _padding + 1),
      ));

      expect(sent, isEmpty);
    });

    testWidgets('sends the composed text once it is committed', (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(TextEditingValue(
        text: '${' ' * _padding}n${' ' * _padding}',
        selection: TextSelection.collapsed(offset: _padding + 1),
        composing: TextRange(start: _padding, end: _padding + 1),
      ));
      input.updateEditingValue(
        _value('${' ' * _padding}に${' ' * _padding}', _padding + 1),
      );

      expect(sent, ['に']);
    });

    testWidgets('sends enter for the keyboard return key', (tester) async {
      await pumpInput(tester);

      input.performAction(TextInputAction.newline);

      expect(sent, ['\r']);
    });

    testWidgets('measures the next edit from the middle again',
        (tester) async {
      await pumpInput(tester);

      input.updateEditingValue(
        _value('${' ' * _padding}a${' ' * _padding}', _padding + 1),
      );
      sent.clear();
      input.updateEditingValue(
        _value('${' ' * _padding}b${' ' * _padding}', _padding + 1),
      );

      expect(sent, ['b']);
    });
  });

  group('a picture the keyboard commits', () {
    final png = KeyboardInsertedContent(
      mimeType: 'image/png',
      uri: 'content://media/external/images/1',
      data: Uint8List.fromList([137, 80, 78, 71]),
    );

    testWidgets('goes to the page, and nothing of it down the wire',
        (tester) async {
      final taken = <KeyboardInsertedContent>[];
      await pumpInput(tester, onContent: taken.add);

      input.insertContent(png);

      expect(taken, [png]);
      expect(sent, isEmpty);
    });

    test('is written out under a name that says what it is', () async {
      final image = await insertedImage(KeyboardInsertedContent(
        mimeType: 'image/jpeg',
        uri: 'content://media/external/images/1',
        data: Uint8List.fromList([255, 216, 255]),
      ));

      expect(image!.name, 'pasted.jpg');
      expect(File(image.path).readAsBytesSync(), [255, 216, 255]);
    });

    test('is refused past the ceiling rather than sent', () async {
      await expectLater(
        insertedImage(KeyboardInsertedContent(
          mimeType: 'image/png',
          uri: 'content://media/external/images/1',
          data: Uint8List(pasteImageLimit + 1),
        )),
        throwsA(isA<PlatformException>()),
      );
    });

    test('anything that is not a picture is left alone', () async {
      final other = KeyboardInsertedContent(
        mimeType: 'text/plain',
        uri: png.uri,
        data: png.data,
      );

      expect(await insertedImage(other), isNull);
    });
  });
}
