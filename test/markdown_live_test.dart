import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/markdown_live.dart';
import 'package:sshbox/src/ui/markdown_rich_editor.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';

import 'markdown_corpus.dart';

final _look = MdLiveLook(
  base: const TextStyle(fontSize: 16, height: 1.6),
  code: const TextStyle(fontFamily: 'mono'),
  palette: TermulPalette.paper,
  width: 600,
);

Widget _swapWidget(MdSwap swap, String source) => const SizedBox();
Widget _sectionWidget(MdRange section) => const SizedBox();

/// Per character of the text: 'h' hidden, 'w' a widget, '.' drawn.
String _draw(TextSpan span) {
  final out = StringBuffer();
  for (final child in span.children!) {
    if (child is WidgetSpan) {
      out.write('w');
    } else if (child is TextSpan) {
      final hidden = identical(child.style, _look.hidden);
      out.write((hidden ? 'h' : '.') * child.text!.length);
    }
  }
  return out.toString();
}

/// What a reader sees with the caret at [ends]: hidden text left out, a
/// widget as ■.
String _shown(String text, List<int> ends, {bool sections = false}) {
  final live = MdLive.parse(text);
  final draw = _draw(
    liveSpan(
      live,
      _look,
      ends,
      TextRange.empty,
      _swapWidget,
      sectionBuilder: sections ? _sectionWidget : null,
    ),
  );
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (draw[i] == 'w') out.write('■');
    if (draw[i] == '.') out.write(text[i]);
  }
  return out.toString();
}

void main() {
  group('fidelity', () {
    for (final MapEntry(key: name, value: text) in markdownCorpus.entries) {
      test('$name: lines and sections cover the text exactly', () {
        final live = MdLive.parse(text);
        expect(live.text, same(text));
        var at = 0;
        for (final line in live.lines) {
          expect(line.start, at, reason: 'line at $at');
          expect(line.end, greaterThanOrEqualTo(line.start));
          expect(text.substring(line.start, line.end), isNot(contains('\n')));
          at = line.end + 1;
        }
        expect(at, text.length + 1);
        at = 0;
        for (final s in live.sections) {
          expect(s.start, at);
          at = s.end;
        }
        expect(at, text.length);
        for (final h in live.hides) {
          expect(h.range.start, greaterThanOrEqualTo(h.reveal.start));
          expect(h.range.end, lessThanOrEqualTo(h.reveal.end));
          expect(h.reveal.end, lessThanOrEqualTo(text.length));
        }
        for (final s in live.swaps) {
          expect(s.range.end, lessThanOrEqualTo(text.length));
          expect(s.range.start, greaterThanOrEqualTo(s.reveal.start));
          expect(s.range.end, lessThanOrEqualTo(s.reveal.end));
        }
      });

      test('$name: what is drawn is exactly as long as the source, the caret '
          'anywhere', () {
        final live = MdLive.parse(text);
        final step = text.length > 20000 ? 997 : 1;
        for (var p = 0; p <= text.length; p += step) {
          for (final sections in [false, true]) {
            final span = liveSpan(
              live,
              _look,
              [p],
              TextRange.empty,
              _swapWidget,
              sectionBuilder: sections ? _sectionWidget : null,
            );
            final plain = span.toPlainText(includePlaceholders: true);
            expect(plain.length, text.length, reason: 'caret at $p');
            // Everything but a widget's own character is the source itself.
            for (var i = 0; i < text.length; i++) {
              if (plain[i] != '￼') {
                expect(plain[i], text[i], reason: 'char $i, caret at $p');
              }
            }
          }
        }
      });

      test('$name: the caret never sits between two hidden characters', () {
        final live = MdLive.parse(text);
        final step = text.length > 20000 ? 499 : 1;
        for (var p = 1; p < text.length; p += step) {
          final draw = _draw(
            liveSpan(
              live,
              _look,
              [p],
              TextRange.empty,
              _swapWidget,
              sectionBuilder: _sectionWidget,
            ),
          );
          expect(
            draw[p - 1] == 'h' && draw[p] == 'h',
            isFalse,
            reason:
                'caret at $p: '
                '${text.substring((p - 8).clamp(0, p), p)}|'
                '${text.substring(p, (p + 8).clamp(p, text.length))}',
          );
        }
      });

      test('$name: nothing typed is converted but Enter and Backspace', () {
        final step = text.length > 20000 ? 1499 : 7;
        for (var p = 0; p <= text.length; p += step) {
          expect(markdownShortcut(text, p, p, 'z'), isNull);
          expect(markdownShortcut(text, p, p, '#'), isNull);
          expect(markdownShortcut(text, p, p, ' '), isNull);
        }
      });
    }
  });

  group('live preview', () {
    test('emphasis, code and links hide their markers away from the caret', () {
      const t = 'A **bold** and _it_ and `code` and [link](https://x.y) end.';
      expect(_shown(t, []), 'A bold and it and code and link end.');
      // The caret in a span shows that span's markers, and only those.
      expect(_shown(t, [5]), 'A **bold** and it and code and link end.');
      expect(
        _shown(t, [t.indexOf('link')]),
        'A bold and it and code and [link](https://x.y) end.',
      );
      // At a span's edge, as the arrow keys come to it.
      expect(_shown(t, [t.indexOf(' and _')]), contains('**bold**'));
    });

    test('a heading hides its hashes unless the caret is on its line', () {
      const t = '# Title ##\n\nBody';
      expect(_shown(t, []), 'Title\n\nBody');
      expect(_shown(t, [3]), '# Title ##\n\nBody');
      expect(_shown(t, [t.length]), 'Title\n\nBody');
    });

    test('bullets and quotes are drawn, tasks are boxes', () {
      expect(_shown('- one\n- two', []), '■ one\n■ two');
      expect(_shown('- [ ] task', []), '■ task');
      expect(_shown('> said', []), '■ said');
      // A task's box shows as written when the caret is in it.
      expect(_shown('- [ ] task', [3]), '- [ ] task');
    });

    test('a table and a fence draw rendered, and as source with the caret in '
        'them', () {
      const t = 'Before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter';
      expect(_shown(t, []), 'Before\n\n■\nAfter');
      expect(_shown(t, [t.indexOf('| 1')]), t);
      const f = 'x\n\n```dart\nmain() {}\n```\n\ny';
      expect(_shown(f, []), 'x\n\n■\ny');
      expect(_shown(f, [f.indexOf('main')]), f);
    });

    test('an underscore inside a word is not emphasis', () {
      expect(_shown('snake_case_names stay', []), 'snake_case_names stay');
    });

    test('nested emphasis and an escape', () {
      expect(_shown('**bold *nested* bold**', []), 'bold nested bold');
      expect(_shown(r'an \* star', []), 'an * star');
      expect(_shown(r'an \* star', [4]), r'an \* star');
    });

    test('a reference link and a footnote', () {
      const t = 'See [guide][g] and [^1].\n\n[g]: https://e.x\n';
      final live = MdLive.parse(t);
      expect(live.linkAt(t.indexOf('guide'))!.href, 'https://e.x');
      expect(_shown(t, []), startsWith('See guide and ^1.'));
    });

    test('sections cut only where a blank line ends a block', () {
      final t = List.generate(40, (i) => 'Para $i line\nsecond').join('\n\n');
      final live = MdLive.parse(t);
      expect(live.sections.length, greaterThan(3));
      for (final s in live.sections.skip(1)) {
        expect(t[s.start - 1], '\n');
        expect(t[s.start], '\n', reason: 'starts with its blank line');
      }
      // A fence with blank lines in it is never cut.
      final fence = '```\n${List.filled(30, 'x\n\n').join()}```\n';
      expect(MdLive.parse(fence).sections, hasLength(1));
    });

    test('with no caret anywhere, sections are drawn apart', () {
      final t = List.generate(40, (i) => 'Para $i').join('\n\n');
      final shown = _shown(t, [], sections: true);
      expect(shown.replaceAll('■', ''), isEmpty);
      // The caret's own section is text; the rest stay drawn apart.
      final at = t.indexOf('Para 20');
      final near = _shown(t, [at], sections: true);
      expect(near, contains('Para 20'));
      expect(near, isNot(contains('Para 0')));
    });

    test('composing text is underlined and keeps the length', () {
      const t = '**bold**かな';
      final live = MdLive.parse(t);
      final span = liveSpan(
        live,
        _look,
        [t.length],
        const TextRange(start: 8, end: 10),
        _swapWidget,
      );
      expect(span.toPlainText().length, t.length);
      final composing = span.children!.whereType<TextSpan>().where(
        (s) => s.style?.decoration == TextDecoration.underline,
      );
      expect(composing.map((s) => s.text).join(), 'かな');
    });
  });

  group('shortcuts', () {
    TextEditingValue? enter(String t, [int? at]) {
      final p = at ?? t.length;
      return markdownShortcut(t, p, p, '\n');
    }

    test('Enter in a list item goes on with the list', () {
      expect(enter('- one')!.text, '- one\n- ');
      expect(enter('  * one')!.text, '  * one\n  * ');
      expect(enter('1. one')!.text, '1. one\n2. ');
      expect(enter('9) one')!.text, '9) one\n10) ');
      expect(enter('- [x] done')!.text, '- [x] done\n- [ ] ');
      expect(enter('> - quoted')!.text, '> - quoted\n> - ');
      expect(enter('- one')!.selection.baseOffset, '- one\n- '.length);
    });

    test('Enter on an empty item ends the list', () {
      final v = enter('- one\n- ')!;
      expect(v.text, '- one\n');
      expect(v.selection.baseOffset, 6);
    });

    test('Enter in a quote goes on quoting, and an empty one ends it', () {
      expect(enter('> said')!.text, '> said\n> ');
      expect(enter('> said\n> ')!.text, '> said\n');
    });

    test('Enter after a fence opened closes it, the caret inside', () {
      final v = enter('```dart')!;
      expect(v.text, '```dart\n\n```');
      expect(v.selection.baseOffset, 8);
      // A fence already closed is left alone.
      expect(enter('```\nx\n```', 3), isNull);
    });

    test('Backspace at an item\'s text takes its marker', () {
      final v = markdownShortcut('a\n- one', 3, 4, '')!;
      expect(v.text, 'a\none');
      expect(v.selection.baseOffset, 2);
      // Anywhere else it is a backspace.
      expect(markdownShortcut('a\n- one', 4, 5, ''), isNull);
    });

    test('Shift+Enter and Enter in a paragraph are typed as they are', () {
      expect(markdownShortcut('- one', 5, 5, '\n', shift: true), isNull);
      expect(enter('plain'), isNull);
      expect(enter('# Heading'), isNull);
    });
  });

  group('formatting', () {
    TextEditingValue value(String t, int a, [int? b]) => TextEditingValue(
      text: t,
      selection: TextSelection(baseOffset: a, extentOffset: b ?? a),
    );

    test('bold goes round the selection and comes off again', () {
      const t = 'one two three';
      final on = toggleInline(
        value(t, 4, 7),
        MdLive.parse(t),
        '**',
        MdMark.bold,
      )!;
      expect(on.text, 'one **two** three');
      expect(on.selection, const TextSelection(baseOffset: 6, extentOffset: 9));
      final off = toggleInline(on, MdLive.parse(on.text), '**', MdMark.bold)!;
      expect(off.text, t);
    });

    test('a selection over two blocks is marked line by line', () {
      const t = 'one two\n\nthree four';
      final on = toggleInline(
        value(t, 4, 15),
        MdLive.parse(t),
        '_',
        MdMark.italic,
      )!;
      expect(on.text, 'one _two_\n\n_three_ four');
    });

    test('with no selection the markers go in, the caret between', () {
      final on = toggleInline(
        value('ab', 1),
        MdLive.parse('ab'),
        '`',
        MdMark.code,
      )!;
      expect(on.text, 'a``b');
      expect(on.selection.baseOffset, 2);
    });

    test('a heading and a quote toggle by their prefix alone', () {
      const t = 'Title\n\nbody';
      final h = toggleHeading(value(t, 2), MdLive.parse(t), 2);
      expect(h.text, '## Title\n\nbody');
      final h1 = toggleHeading(value(h.text, 4), MdLive.parse(h.text), 1);
      expect(h1.text, '# Title\n\nbody');
      final off = toggleHeading(value(h1.text, 3), MdLive.parse(h1.text), 1);
      expect(off.text, t);
      final q = toggleQuote(value(t, 0, t.length), MdLive.parse(t));
      expect(q.text, '> Title\n> \n> body');
      final all = q.copyWith(
        selection: TextSelection(baseOffset: 0, extentOffset: q.text.length),
      );
      expect(toggleQuote(all, MdLive.parse(q.text)).text, 'Title\n\nbody');
    });
  });
}
