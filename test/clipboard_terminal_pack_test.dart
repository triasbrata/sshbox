import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';

void main() {
  test('the app\'s terminal packs the lines that scrolled out of sight', () {
    final terminal = ClipboardTerminal(maxLines: 10000)..resize(100, 24);
    for (var chunk = 0; chunk < 40; chunk++) {
      terminal.write(
        [
          for (var i = 0; i < 50; i++) 'line ${chunk * 50 + i} \x1b[32mgreen\x1b[0m',
        ].join('\r\n'),
      );
      terminal.write('\r\n');
    }
    final lines = terminal.buffer.lines;
    final cold = lines.length - terminal.viewHeight;
    var packed = 0;
    for (var i = 0; i < cold; i++) {
      if (lines[i].isPacked) packed++;
    }
    expect(cold, greaterThan(1500));
    expect(packed, cold);
    // And a packed line still reads as it was written.
    expect(lines[7].getText(), 'line 7 green');
  });
}
