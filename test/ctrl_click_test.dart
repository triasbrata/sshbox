import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/ctrl_click.dart';
import 'package:xterm2/xterm.dart';

/// What a Ctrl+tap can find in terminal text. Pure string work, so each
/// shape of path gets a line of its own rather than a session to print it in.
void main() {
  /// Each link in [text] as `kind target line`, then the text it covers.
  List<String> links(String text) => [
    for (final link in findLinks(text))
      '${link.kind.name} ${link.target} ${link.line} '
          '${text.substring(link.start, link.end)}',
  ];

  test('a URL, without the sentence it ends', () {
    expect(links('docs at https://dart.dev/tools. Then'), [
      'url https://dart.dev/tools null https://dart.dev/tools',
    ]);
  });

  test('absolute and home paths', () {
    expect(links('ls /etc/hosts ~/dev'), [
      'path /etc/hosts null /etc/hosts',
      'path ~/dev null ~/dev',
    ]);
  });

  test('a relative path keeps its line and column apart, and leaves grep '
      'text behind', () {
    expect(links('lib/src/ui/magic_key.dart:12:3 lib/a.dart:3:import'), [
      'path lib/src/ui/magic_key.dart 12 lib/src/ui/magic_key.dart:12:3',
      'path lib/a.dart 3 lib/a.dart:3',
    ]);
  });

  test('quotes, brackets and trailing punctuation come off', () {
    expect(links('("./run.sh"), [../up/]; see lib/x.dart.'), [
      'path ./run.sh null ./run.sh',
      'path ../up/ null ../up/',
      'path lib/x.dart null lib/x.dart',
    ]);
  });

  test('a bare name is only a maybe; numbers and comment slashes are not '
      'names', () {
    expect(links('README.md, v1.2.3 or 3.14 //'), [
      'name README.md null README.md',
    ]);
  });

  test('a path the terminal wrapped is found whole, from either row', () {
    final terminal = Terminal()..resize(20, 5);
    // "open lib/src/ui/term" | "inal_page.dart now"
    terminal.write('open lib/src/ui/terminal_page.dart now');

    for (final cell in const [CellOffset(6, 0), CellOffset(3, 1)]) {
      expect(
        linkAt(terminal.buffer, cell)?.target,
        'lib/src/ui/terminal_page.dart',
      );
    }
    expect(linkAt(terminal.buffer, const CellOffset(1, 0)), isNull);
  });

  test('a file: hyperlink is a path on the host, whatever host it names; '
      'anything else is a URL for openUrl to rule on', () {
    String open(String address) {
      final link = hyperlinkTarget(address);
      return '${link.kind.name} ${link.target}';
    }

    expect(open('file:///home/me/notes.txt'), 'path /home/me/notes.txt');
    // How `ls --hyperlink` writes one, with the host's name in it.
    expect(
      open('file://box/home/me/my%20notes.txt'),
      'path /home/me/my notes.txt',
    );
    expect(open('https://dart.dev'), 'url https://dart.dev');
    expect(open('intent:#Intent;end'), 'url intent:#Intent;end');
    expect(open('COR-6025'), 'url COR-6025');
  });

  group('selectedText, what a copy out of the terminal takes', () {
    /// A terminal [width] columns wide with [text] written into it.
    Buffer drawn(String text, {int width = 80}) {
      final terminal = Terminal()..resize(width, 5);
      terminal.write(text);
      return terminal.buffer;
    }

    /// Rows [from] to [to], whole, as a selection dragged across them.
    BufferRange rows(int from, [int? to]) =>
        BufferRangeLine(CellOffset(0, from), CellOffset(80, to ?? from));

    test('keeps the gaps a program stepped over with the cursor, as spaces', () {
      // How a renderer like Claude Code's draws a line: a word, the cursor one
      // cell on, the next word, never a space written.
      final buffer = drawn(
        'git\x1b[1Cpush\x1b[1Corigin\x1b[1C--delete\x1b[1Csome-branch',
      );

      // xterm2's own reading, which every copy used to take.
      expect(buffer.getText(rows(0), true), 'gitpushorigin--deletesome-branch');
      expect(
        selectedText(buffer, rows(0)),
        'git push origin --delete some-branch',
      );
    });

    test('a wider jump is as many spaces as cells, but a tab stays a tab', () {
      expect(selectedText(drawn('a\x1b[3Cb'), rows(0)), 'a   b');
      final tabbed = drawn('a\tb\x1b[2Cc');
      expect(selectedText(tabbed, rows(0)), 'a\tb  c');
    });

    test('a line of ordinary spaces copies as it always did', () {
      final buffer = drawn('git push  origin   --delete some-branch   ');
      expect(
        selectedText(buffer, rows(0)),
        'git push  origin   --delete some-branch',
      );
      expect(selectedText(buffer, rows(0)), buffer.getText(rows(0), true));
    });

    test('blank cells after the last written one are never padded out', () {
      final buffer = drawn('one\x1b[5C\r\n\r\ntwo\x1b[1Cthree');
      expect(selectedText(buffer, rows(0, 2)), 'one\n\ntwo three');
      expect(
        selectedText(
          buffer,
          BufferRangeLine(const CellOffset(1, 0), const CellOffset(6, 0)),
        ),
        'ne',
      );
    });

    test('wide characters keep their width, a jump between them a space', () {
      final buffer = drawn('日本\x1b[1C語 ok');
      expect(selectedText(buffer, rows(0)), '日本 語 ok');
      // A selection starting on the right half of 本 still takes all of it.
      expect(
        selectedText(
          buffer,
          BufferRangeLine(const CellOffset(3, 0), const CellOffset(7, 0)),
        ),
        '本 語',
      );
    });

    test('a line that wrapped joins back up with nothing between its rows', () {
      // "abcdefgh j" | "kl mn", the second row carrying on from the first.
      final buffer = drawn('abcdefgh\x1b[1Cjkl\x1b[1Cmn', width: 10);
      expect(selectedText(buffer, rows(0, 1)), 'abcdefgh jkl mn');
      final plain = drawn('abcdefghijkl mn', width: 10);
      expect(selectedText(plain, rows(0, 1)), 'abcdefghijkl mn');
      expect(selectedText(plain, rows(0, 1)), plain.getText(rows(0, 1), true));

      // A wide character that did not fit in the last column goes to the next
      // row, leaving that column blank: no space for it.
      final wide = drawn('abcd日x', width: 5);
      expect(selectedText(wide, rows(0, 1)), 'abcd日x');
      expect(selectedText(wide, rows(0, 1)), wide.getText(rows(0, 1), true));
    });

    test('a block selection is its rows, one to a line', () {
      final buffer = drawn('ab\x1b[1Ccd\r\nef\x1b[1Cgh');
      expect(
        selectedText(
          buffer,
          BufferRangeBlock(const CellOffset(1, 0), const CellOffset(4, 1)),
        ),
        'b c\nf g',
      );
    });
  });
}
