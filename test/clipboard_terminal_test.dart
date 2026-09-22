import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';

String _osc52(String text, {String target = 'c', String end = '\x07'}) =>
    '\x1b]52;$target;${base64.encode(utf8.encode(text))}$end';

void main() {
  late ClipboardTerminal terminal;
  late List<String> copied;
  late List<String> sent;

  setUp(() {
    copied = [];
    sent = [];
    terminal = ClipboardTerminal()
      ..onClipboardStore = ((_, text) => copied.add(text))
      ..onOutput = sent.add;
  });

  String screen() => terminal.buffer.lines[0].getText().trimRight();

  test('an OSC 52 is copied, and the text round it is drawn as it was', () {
    terminal.write('a${_osc52('git push origin --delete x')}b');
    terminal.write(_osc52('with ST', end: '\x1b\\'));
    terminal.write(_osc52('no target', target: ''));
    terminal.write(_osc52('primary', target: 'p'));

    expect(copied, [
      'git push origin --delete x',
      'with ST',
      'no target',
      'primary',
    ]);
    expect(screen(), 'ab');
  });

  test('one split anywhere across writes is still one copy', () {
    final sequence = 'x${_osc52('über')}y';
    for (var cut = 1; cut < sequence.length; cut++) {
      copied.clear();
      terminal = ClipboardTerminal()
        ..onClipboardStore = ((_, t) => copied.add(t));
      terminal.write(sequence.substring(0, cut));
      terminal.write(sequence.substring(cut));
      expect(copied, ['über'], reason: 'cut at $cut');
      expect(screen(), 'xy', reason: 'cut at $cut');
    }
  });

  test('a long reply comes through whole, past the 8 KB xterm2 would read', () {
    final reply = List.filled(20000, 'line of a long reply\n').join();
    final sequence = _osc52(reply);
    // As a shell's output arrives: in pieces.
    for (var i = 0; i < sequence.length; i += 4096) {
      terminal.write(
        sequence.substring(i, (i + 4096).clamp(0, sequence.length)),
      );
    }
    expect(copied, [reply]);
  });

  test('past 1 MB is dropped whole, and what follows is drawn', () {
    terminal.write(_osc52('x' * (maxClipboardBytes + 1)));
    terminal.write('after');
    expect(copied, isEmpty);
    expect(screen(), 'after');

    terminal.write(_osc52('x' * maxClipboardBytes));
    expect(copied.single.length, maxClipboardBytes);
  });

  test('a query is never answered, and nothing goes back to the host', () {
    terminal.write('\x1b]52;c;?\x07');
    // The C1 form reaches xterm2's own parser, and its query too.
    terminal.write('\u009d52;c;?\x07');
    expect(sent, isEmpty);
    expect(copied, isEmpty);
    expect(terminal.onClipboardQuery!('c'), isNull);
  });

  test('what is not plain base64 of UTF-8 is dropped', () {
    for (final data in [
      'aGVsbG8_', // the URL-safe alphabet, which Dart would read
      'aGVsbG8', // no pad
      'aGVs bG8=',
      'not base64!',
      base64.encode([0xff, 0xfe]), // not UTF-8
      '', // xterm's "clear it", which clears nothing here
    ]) {
      terminal.write('\x1b]52;c;$data\x07');
    }
    // A cut buffer is not the clipboard.
    terminal.write(_osc52('cut', target: '0'));
    expect(copied, isEmpty);
    expect(screen(), isEmpty);
  });

  test("Claude Code's copy inside tmux is copied once, not twice", () {
    // Its own words: the plain OSC 52, then the same in tmux's passthrough.
    final plain = _osc52('once');
    terminal.write(
      '$plain\x1bPtmux;${plain.replaceAll('\x1b', '\x1b\x1b')}\x1b\\',
    );
    terminal.write('next');
    expect(copied, ['once']);
    expect(screen(), 'next');
  });

  test('an OSC 52 cut short by another sequence leaves that sequence be', () {
    terminal.write('\x1b]52;c;aGVs\x1b[31mred');
    expect(copied, isEmpty);
    expect(screen(), 'red');
    expect(
      terminal.buffer.lines[0].getForeground(0),
      isNot(terminal.buffer.lines[0].getForeground(5)),
    );
  });
}
