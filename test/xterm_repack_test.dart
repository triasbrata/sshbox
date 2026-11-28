import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

int _packed(Terminal terminal) =>
    terminal.buffer.lines.toList().where((l) => l.isPacked).length;

/// Scrollback is packed as it is written, newest first, and stops at the first
/// line already packed. Reading a packed line unpacks it. What reading old
/// history does to the memory the scrollback holds afterwards (#347): lines
/// older than any line still packed are never reached again by a pass that
/// stops there.
void main() {
  Terminal filled() {
    final terminal = Terminal(maxLines: 10000);
    terminal.resize(80, 24);
    for (var i = 0; i < 400; i++) {
      terminal.write('line $i of the history\r\n');
    }
    return terminal;
  }

  test('a filled scrollback is packed (the baseline)', () {
    final terminal = filled();
    final lines = terminal.buffer.lines.length;
    // Everything above the viewport.
    expect(
      _packed(terminal),
      greaterThanOrEqualTo(lines - terminal.viewHeight - 2),
    );
  });

  test(
    'old lines read by the user, then more output: they are packed again',
    () {
      final terminal = filled();
      final before = _packed(terminal);
      expect(before, greaterThan(300));

      // The user scrolls up through the first hundred lines, as the view paints
      // and a copy reads them.
      for (var i = 0; i < 100; i++) {
        terminal.buffer.lines[i].getText();
      }
      final afterRead = _packed(terminal);
      expect(afterRead, lessThan(before), reason: 'reading did not unpack');

      // More output, a line at a time as a program writes it.
      for (var i = 0; i < 10; i++) {
        terminal.write('more $i\r\n');
      }
      final unpackedOld = [
        for (var i = 0; i < 100; i++)
          if (!terminal.buffer.lines[i].isPacked) i,
      ];
      expect(
        unpackedOld,
        isEmpty,
        reason:
            '${unpackedOld.length} of the 100 old lines read earlier stay '
            'unpacked after more output (packed $afterRead of '
            '${terminal.buffer.lines.length} after the read, '
            '${_packed(terminal)} now)',
      );
    },
  );
}
