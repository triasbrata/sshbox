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
}
