import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/terminal_paste.dart';
import 'package:xterm2/xterm.dart';

/// A terminal as a reattached tmux pane has it: it never saw the program ask
/// for bracketed paste, so its own flag is off.
({Terminal terminal, List<String> out, List<String> raw}) _pane() {
  final out = <String>[];
  final terminal = Terminal(onOutput: out.add);
  expect(terminal.bracketedPasteMode, isFalse);
  return (terminal: terminal, out: out, raw: <String>[]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('a file path at the prompt', () {
    test('in a tmux tab is always pasted, whatever the terminal remembers', () {
      final p = _pane();
      pastePath(p.terminal, '/tmp/a b.png', tmux: true, sendRaw: p.raw.add);
      expect(p.out, ['/tmp/a b.png '], reason: 'through paste, to tmux');
      expect(p.raw, isEmpty, reason: 'never typed');
    });

    test('outside tmux it is typed when the program did not ask, pasted '
        'bracketed when it did', () {
      final plain = _pane();
      pastePath(
        plain.terminal,
        '/tmp/a.png',
        tmux: false,
        sendRaw: plain.raw.add,
      );
      expect(plain.raw, ['/tmp/a.png ']);
      expect(plain.out, isEmpty);

      final asked = _pane();
      asked.terminal.write('\x1b[?2004h');
      pastePath(
        asked.terminal,
        '/tmp/a.png',
        tmux: false,
        sendRaw: asked.raw.add,
      );
      expect(asked.out, ['\x1b[200~/tmp/a.png \x1b[201~']);
      expect(asked.raw, isEmpty);
    });
  });

  group('a shared text', () {
    const multiline = 'first\nsecond';

    Future<String?> Function() runs(String? command) =>
        () async => command;

    test('multi-line into a tmux pane running claude is pasted, not refused '
        'by a stale flag', () async {
      final p = _pane();
      expect(
        await pasteShared(p.terminal, multiline, paneCommand: runs('claude')),
        isNull,
      );
      expect(p.out, ['first\rsecond']);
    });

    for (final shell in ['bash', '-zsh', 'fish', 'dash', 'sh', null]) {
      test('multi-line into a tmux pane running ${shell ?? 'nothing tmux '
          'can name'} is refused and nothing is typed', () async {
        final p = _pane();
        final refused = await pasteShared(
          p.terminal,
          multiline,
          paneCommand: runs(shell),
        );
        expect(refused, contains('would run each line'));
        expect(p.out, isEmpty);
      });
    }

    test('a single line into a tmux pane running bash is pasted', () async {
      final p = _pane();
      expect(
        await pasteShared(p.terminal, 'https://example.com', paneCommand: runs('bash')),
        isNull,
      );
      expect(p.out, ['https://example.com']);
    });

    test('into a plain shell that never asked is still refused', () async {
      final p = _pane();
      final refused = await pasteShared(p.terminal, multiline);
      expect(refused, contains('would run each line'));
      expect(p.out, isEmpty);
    });
  });
}
