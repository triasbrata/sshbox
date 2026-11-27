import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Everything a line holds that anything can read, as plain values.
List<Object?> _snapshot(BufferLine line) => [
  line.length,
  line.isWrapped,
  for (var i = 0; i < line.length; i++) ...[
    line.getForeground(i),
    line.getBackground(i),
    line.getAttributes(i),
    line.getContent(i),
    line.getCombiningCharacters(i),
    line.getUnderlineColor(i),
  ],
  line.getText(),
  line.getTrimmedLength(line.length),
];

BufferLine _randomLine(Random random, int width) {
  final line = BufferLine(width, isWrapped: random.nextBool());
  final style = CursorStyle();
  final written = random.nextInt(width + 1);
  var i = 0;
  while (i < written) {
    style
      ..foreground = random.nextInt(4) == 0 ? random.nextInt(1 << 25) : 0
      ..background = random.nextInt(6) == 0 ? random.nextInt(1 << 25) : 0
      ..attrs = random.nextInt(8) == 0 ? random.nextInt(1 << 9) : 0
      ..underlineColor = random.nextInt(20) == 0 ? random.nextInt(1 << 24) : 0;
    switch (random.nextInt(8)) {
      case 0 when i + 1 < width:
        line.setCell(i, 0x4e2d, 2, style);
        line.setCell(i + 1, 0, 0, style);
        i += 2;
      case 1:
        line.setCell(i, 0x00e9, 1, style);
        line.addCombiningCharacter(i, 0x0301);
        i++;
      case 2:
        line.setCell(i, 0x1f600, 2, style);
        i += 2;
      case 3:
        // A gap the cursor moved over.
        i += 1 + random.nextInt(4);
      default:
        line.setCell(i, 0x20 + random.nextInt(0x5f), 1, style);
        i++;
    }
  }
  return line;
}

void main() {
  group('a packed line is the line it was', () {
    test('2000 random lines round trip through pack and unpack', () {
      final random = Random(347);
      for (var n = 0; n < 2000; n++) {
        final width = 1 + random.nextInt(300);
        final line = _randomLine(random, width);
        final before = _snapshot(line);
        line.pack();
        expect(line.isPacked, isTrue);
        expect(_snapshot(line), before, reason: 'line $n, width $width');
        // Reading unpacked it; a second round goes the same way.
        expect(line.isPacked, isFalse);
        line.pack();
        expect(line.isPacked, isTrue);
        expect(_snapshot(line), before);
      }
    });

    test('a packed line can be changed, and keeps what it was given', () {
      final line = BufferLine(20);
      final style = CursorStyle()..foreground = 7;
      line.setAsciiCells(0, 'hello world', 0, 11, style);
      line.pack();
      line.setCell(0, 0x48, 1, style); // 'H'
      expect(line.getText(), 'Hello world');
      line.pack();
      line.removeCells(0, 6);
      expect(line.getText(), 'world');
      line.pack();
      final copy = BufferLine(20)..copyFrom(line, 0, 2, 5);
      expect(copy.getText(), 'world');
    });

    test('an empty and a one-cell line pack', () {
      for (final width in [0, 1]) {
        final line = BufferLine(width)..pack();
        expect(line.isPacked, isTrue);
        expect(line.length, width);
        expect(line.getText(), '');
      }
    });
  });

  group('scrollback in a terminal', () {
    const sample = [
      'plain output line that goes on for a while',
      '\x1b[31mred\x1b[0m and \x1b[1;44mbold on blue\x1b[0m trailing',
      '中文 wide and é́ combined, 😀 too',
      '\x1b[38;2;10;200;30mtrue colour\x1b[0m\x1b[4:3m curly',
      '',
      'tab\there and a gap\x1b[5Cafter cursor forward',
    ];

    String feed(int lines, int seed, int cols) {
      final random = Random(seed);
      final out = StringBuffer();
      for (var i = 0; i < lines; i++) {
        out.write(sample[random.nextInt(sample.length)]);
        if (random.nextInt(5) == 0) out.write('x' * random.nextInt(cols * 2));
        out.write('\r\n');
      }
      return out.toString();
    }

    List<List<Object?>> all(Terminal terminal) => [
      for (var i = 0; i < terminal.buffer.lines.length; i++)
        _snapshot(terminal.buffer.lines[i]),
    ];

    Terminal make(int cols, {required bool packed}) {
      Buffer.compactionEnabled = packed;
      return Terminal(maxLines: 10000)..resize(cols, 24);
    }

    tearDown(() => Buffer.compactionEnabled = true);

    for (final cols in [80, 120, 250]) {
      test('$cols columns: every line, then a reflow, is as without packing', () {
        final text = feed(2500, cols, cols);
        final plain = make(cols, packed: false);
        final packed = make(cols, packed: true);
        // In chunks, as a connection delivers it.
        for (var at = 0; at < text.length; at += 997) {
          final chunk = text.substring(at, min(at + 997, text.length));
          Buffer.compactionEnabled = false;
          plain.write(chunk);
          Buffer.compactionEnabled = true;
          packed.write(chunk);
        }
        Buffer.compactionEnabled = true;
        final lines = packed.buffer.lines;
        final packedCount = [
          for (var i = 0; i < lines.length; i++) lines[i].isPacked,
        ].where((it) => it).length;
        expect(packedCount, greaterThan(lines.length - 40));
        expect(all(packed), all(plain));

        // Reading all of it unpacked at most the recently used 256.
        final stillUnpacked = [
          for (var i = 0; i < lines.length; i++) lines[i].isPacked,
        ].where((it) => !it).length;
        expect(stillUnpacked, lessThanOrEqualTo(256 + 24));

        // A resize reflows every line.
        Buffer.compactionEnabled = false;
        plain.resize(cols ~/ 2 + 7, 30);
        Buffer.compactionEnabled = true;
        packed.resize(cols ~/ 2 + 7, 30);
        expect(all(packed), all(plain));
        plain.resize(cols + 11, 24);
        packed.resize(cols + 11, 24);
        expect(all(packed), all(plain));
      });
    }

    test('a selection copies the same text packed or not', () {
      final text = feed(800, 3, 100);
      final plain = make(100, packed: false)..write(text);
      final packed = make(100, packed: true)..write(text);
      final from = CellOffset(3, 20);
      final to = CellOffset(40, 500);
      String copy(Terminal t) => t.buffer.getText(
        BufferRangeLine(from, to),
      );
      expect(copy(packed), copy(plain));
    });

    test('bytes a full scrollback holds, packed against not', () {
      // ignore: avoid_print
      print('cols  unpacked  packed   (10000 lines, typical output)');
      for (final cols in [80, 120, 250]) {
        final text = feed(10200, 11, cols);
        final plain = make(cols, packed: false);
        final packed = make(cols, packed: true);
        Buffer.compactionEnabled = false;
        plain.write(text);
        Buffer.compactionEnabled = true;
        packed.write(text);
        int bytes(Terminal t) => [
          for (var i = 0; i < t.buffer.lines.length; i++)
            t.buffer.lines[i].heldBytes,
        ].fold(0, (a, b) => a + b);
        // Measured without reading, since reading unpacks.
        final before = bytes(plain);
        final after = bytes(packed);
        // ignore: avoid_print
        print(
          '$cols   ${(before / 1048576).toStringAsFixed(1)} MB   '
          '${(after / 1048576).toStringAsFixed(2)} MB   '
          '(${(before / after).toStringAsFixed(0)}x)',
        );
        expect(after, lessThan(before ~/ 8));
      }
    });
  });
}
