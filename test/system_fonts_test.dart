import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/system_fonts.dart';

/// `fc-list : family spacing` on this project's WSL (fontconfig 2.13.1), as
/// it printed it: a line a face, in no order, some families twice.
const _fcList = r'''
DejaVu Sans Mono:spacing=100
Ubuntu,Ubuntu Light
IBM 3270 Semi\-Condensed:spacing=100
CPMono_v07,CPMono_v07 Black:spacing=100
DejaVu Sans,DejaVu Sans Condensed
Fira Mono for Powerline
Noto Sans Mono
IPAGothic,IPAゴシック:spacing=90
CPMono_v07,CPMono_v07 Plain:spacing=100
Liberation Mono:spacing=100
Unifont:spacing=90
WenQuanYi Zen Hei Mono,文泉驛等寬正黑,文泉驿等宽正黑
Fira Mono for Powerline:spacing=100
DejaVu Sans
Ubuntu
''';

void main() {
  test('reads fc-list: one row a family by its first name, monospaced '
      'first by Pango\'s rule, and a name\'s escapes undone', () {
    expect(parseFcList(_fcList), [
      (family: 'CPMono_v07', mono: true),
      (family: 'DejaVu Sans Mono', mono: true),
      // One face says so and another does not: the family is.
      (family: 'Fira Mono for Powerline', mono: true),
      (family: 'IBM 3270 Semi-Condensed', mono: true),
      // Dual width, a CJK mono font's.
      (family: 'IPAGothic', mono: true),
      (family: 'Liberation Mono', mono: true),
      (family: 'Unifont', mono: true),
      (family: 'DejaVu Sans', mono: false),
      // Named mono, but fontconfig does not say so, and only what it says
      // is taken.
      (family: 'Noto Sans Mono', mono: false),
      (family: 'Ubuntu', mono: false),
      (family: 'WenQuanYi Zen Hei Mono', mono: false),
    ]);
    expect(parseFcList(''), isEmpty);
  });

  test('leaves out what GDI names a weight of a family it lists too', () {
    expect(
      withoutGdiStyleNames({
        'Cascadia Mono': true,
        'Cascadia Mono SemiBold': true,
        'Cascadia Mono ExtraLight': true,
        'Segoe UI': false,
        'Segoe UI Semibold': false,
        'Arial': false,
        'Arial Black': false,
        'Bahnschrift SemiBold SemiCondensed': false,
        'Bahnschrift': false,
        // Its family is not there, so it is the one to pick.
        'Roboto Mono Light': true,
      }),
      {
        'Cascadia Mono': true,
        'Segoe UI': false,
        'Arial': false,
        'Bahnschrift': false,
        'Roboto Mono Light': true,
      },
    );
  });

  test('a hidden or vertical family is never listed', () {
    expect(
      sortedFonts({
        '.AppleSystemUIFont': false,
        '@MS Gothic': true,
        'Menlo': true,
      }),
      [(family: 'Menlo', mono: true)],
    );
  });
}
