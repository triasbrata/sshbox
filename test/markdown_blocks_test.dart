import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/markdown_blocks.dart';

/// Documents of the kinds people keep on a host: a README, a CLAUDE.md, and
/// the corners of Markdown that are easiest to get wrong.
final _corpus = <String, String>{
  'readme': '''
# Jeansh

Terminal buddy in your **pocket**. Built with _Flutter_ and `dartssh2`.

[![CI](https://img.shields.io/badge.svg)](https://example.com/ci)

## Install

* Download the build for your desktop.
* Unpack it, then run `./jeansh`.
* Read the [docs](https://example.com/docs "The docs").

1. One
2. Two
3) Three

```sh
flutter build apk --release
```

| Platform | Status |
|----------|:------:|
| Android  | ✅     |

<details>
<summary>More</summary>

Hidden *text*.

</details>

See [the guide][guide] and the footnote[^1].

[guide]: https://example.com/guide
[^1]: A footnote.

---

Line one
line two after a hard break.
Trailing paragraph with an escaped \\* star and a \\_ line.
''',
  'claude': '''
---
title: notes
tags: [a, b]
---

# How sessions work

Several sessions work this repo at the same time. These rules keep them
from colliding, and make sure *nothing* counts as done until the user
has tried it.

## Who runs the app

- One **coordinator** session holds the only `flutter run`.
  It answers the user itself.
- Every other session is a worker.
  - Workers never run `flutter install`.
  - [ ] a task
  - [x] a done task

> A quote
> over two lines.

    indented code
    more

Setext heading
==============

Another
-------

<!-- a comment
spanning lines -->

Closing paragraph with a [link](<https://example.com/a b>) and `` code ` span ``.
''',
  'edges': '''
Intra_word_underscores and snake_case_names stay text.

***bold italic*** and **bold *nested* bold** and *a **b** c*.

A line with &amp; an entity.

A raw <span>tag</span> inline.

A bare https://example.com link.

~~struck~~ text.

  Indented paragraph.

#Not a heading
# Heading with closing ##
###### Six

+ plus item
-
- after empty

```mermaid
flowchart LR
  A --> B
```

~~~
tilde fence
~~~

```
unclosed fence
''',
  'crlf-free tail without newline': 'Last line with no newline',
  'empty': '',
  'only blanks': '\n\n\n',
};

String _readRepo(String path) => File(path).readAsStringSync();

void main() {
  final corpus = {
    ..._corpus,
    'repo README.md': _readRepo('README.md'),
    'repo CLAUDE.md': _readRepo('CLAUDE.md'),
  };

  group('round trip', () {
    for (final MapEntry(key: name, value: text) in corpus.entries) {
      test('$name splits back to the same bytes', () {
        final doc = MdDoc.parse(text);
        expect(doc.text, text);
        expect(MdDoc.consistent(doc.blocks), isTrue);
      });

      test('$name: one edit changes only that block', () {
        final doc = MdDoc.parse(text);
        var edited = 0;
        var offset = 0;
        for (var i = 0; i < doc.blocks.length; i++) {
          final block = doc.blocks[i];
          final start = offset;
          offset += block.raw.length;
          final m = block.inline;
          if (m == null) continue;
          // A word typed where a reader would put one: at the first gap
          // between words past the middle, or at the end.
          final gap = m.text.indexOf(' ', m.text.length ~/ 2);
          final at = gap < 0 ? m.text.length : gap;
          final word = m.text.isEmpty ? 'zz' : ' zz';
          // An empty `-` gains the space its marker needs before text.
          final marker =
              m.text.isEmpty &&
                  block.prefix.isNotEmpty &&
                  !block.prefix.endsWith(' ')
              ? 1
              : 0;
          final change = doc.edit(
            i,
            MdEdit(
              m.text.replaceRange(at, at, word),
              [
                ...m.styles.sublist(0, at),
                for (var k = 0; k < word.length; k++)
                  at > 0 ? m.styles[at - 1] : MdStyle.plain,
                ...m.styles.sublist(at),
              ],
              a: at,
              b: at,
              ins: word,
            ),
            caret: at + word.length,
          );
          expect(change, isNotNull, reason: 'block $i of $name: ${block.raw}');
          final after = change!.doc.text;
          final end = start + block.raw.length;
          final grown = after.length - text.length;
          expect(after.substring(0, start), text.substring(0, start));
          expect(after.substring(end + grown), text.substring(end));
          // Typing goes in where it was typed: those bytes, nothing else.
          expect(
            grown,
            word.length + marker,
            reason: after.substring(start, end + grown),
          );
          edited++;
        }
        if (text.contains('#')) expect(edited, greaterThan(0));
      });
    }
  });

  group('what can be edited', () {
    MdBlock only(String text) {
      final blocks = MdDoc.parse(text).blocks;
      return blocks.firstWhere((b) => b.kind != MdBlockKind.gap);
    }

    test('paragraphs, headings and plain list items', () {
      expect(only('Plain *text*.\n').kind, MdBlockKind.paragraph);
      expect(only('## Title ##\n').kind, MdBlockKind.heading);
      expect(only('## Title ##\n').inline!.text, 'Title');
      expect(only('* item\n').kind, MdBlockKind.listItem);
      expect(only('* item\n').prefix, '* ');
      expect(only('12) item\n').prefix, '12) ');
    });

    test('everything else is drawn but not edited, and says what it is', () {
      expect(only('| a | b |\n|---|---|\n| 1 | 2 |\n').why, MdOpaque.table);
      expect(only('<div>\nx\n</div>\n').why, MdOpaque.html);
      expect(only('---\na: 1\n---\n').why, MdOpaque.frontMatter);
      expect(only('```\ncode\n```\n').why, MdOpaque.fence);
      expect(only('> quote\n').why, MdOpaque.quote);
      expect(only('Title\n===\n').why, MdOpaque.setext);
      expect(only('***\n').why, MdOpaque.rule);
      expect(only('[a]: https://x\n').why, MdOpaque.reference);
      expect(only('[^1]: note\n').why, MdOpaque.footnote);
      expect(only('- [ ] todo\n').why, MdOpaque.task);
      expect(MdDoc.parse('- a\n  - b\n').blocks.last.why, MdOpaque.nestedList);
      for (final inline in [
        'See [ref][r].\n',
        'A ![pic](a.png).\n',
        'Hard  \nbreak.\n',
        '~~gone~~\n',
        'x &amp; y\n',
        'a <b>tag</b>\n',
        'https://bare.example.com\n',
      ]) {
        expect(only(inline).why, MdOpaque.inline, reason: inline);
      }
    });

    test('the source is mapped through escapes, code and links', () {
      final m = only(
        r'A \* and `co de` and [the *docs*](u "t").'
        '\n',
      ).inline!;
      expect(m.text, 'A * and co de and the docs.');
      final link = m.styles[m.text.indexOf('docs')].link!;
      expect(link.href, 'u');
      expect(link.raw, '(u "t")');
      expect(m.styles[m.text.indexOf('docs')].italic, isTrue);
      expect(m.styles[m.text.indexOf('co')].code, isTrue);
      expect(m.to[2] - m.from[2], 2);
    });

    test('a soft break shows as a new line, its indent hidden', () {
      final m = only('- one\n  two\n').inline!;
      expect(m.text, 'one\ntwo');
    });
  });

  group('editing', () {
    MdChange type(String text, int block, int at, String ins) {
      final doc = MdDoc.parse(text);
      final m = doc.blocks[block].inline!;
      final style = at > 0 ? m.styles[at - 1] : m.styles.first;
      return doc.edit(
        block,
        MdEdit(
          m.text.replaceRange(at, at, ins),
          [
            ...m.styles.sublist(0, at),
            for (var k = 0; k < ins.length; k++) style,
            ...m.styles.sublist(at),
          ],
          a: at,
          b: at,
          ins: ins,
        ),
        caret: at + ins.length,
      )!;
    }

    test('typed markup is escaped as little as will do', () {
      expect(
        type('Hello\n', 0, 5, ' *world*').doc.text,
        r'Hello \*world\*'
        '\n',
      );
      expect(type('Hello\n', 0, 5, ' & co').doc.text, 'Hello & co\n');
      expect(
        type('Hello\n', 0, 0, '# ').doc.text,
        r'\# Hello'
        '\n',
      );
    });

    test('a list keeps its marker and a soft break its indent', () {
      final change = type('* one\n* two\n', 1, 3, '\nmore');
      expect(change.doc.text, '* one\n* two\n  more\n');
    });

    test('typing inside bold stays bold, after it too', () {
      expect(type('**bold** x\n', 0, 4, 'er').doc.text, '**bolder** x\n');
    });

    test('bold toggled on a word uses the delimiters the block uses', () {
      final doc = MdDoc.parse('__one__ two\n');
      final m = doc.blocks[0].inline!;
      final styles = List.of(m.styles);
      for (var i = 4; i < 7; i++) {
        styles[i] = const MdStyle(bold: true);
      }
      final change = doc.edit(0, MdEdit(m.text, styles), caret: 7)!;
      expect(change.doc.text, '__one__ __two__\n');
    });

    test('bold toggled in a block that has none uses the document’s', () {
      final doc = MdDoc.parse('__one__\n\nplain two\n');
      final m = doc.blocks[2].inline!;
      final styles = List.of(m.styles);
      for (var i = 0; i < 5; i++) {
        styles[i] = const MdStyle(bold: true);
      }
      final change = doc.edit(2, MdEdit(m.text, styles), caret: 0)!;
      expect(change.doc.text, '__one__\n\n__plain__ two\n');
    });

    test('a deletion across a delimiter is written afresh, only there', () {
      final doc = MdDoc.parse('Keep *this*.\n\nx **bold** y\n\n- after\n');
      final m = doc.blocks[2].inline!;
      final change = doc.edit(
        2,
        MdEdit(
          'x  y',
          [...m.styles.sublist(0, 2), ...m.styles.sublist(6)],
          a: 2,
          b: 6,
        ),
        caret: 2,
      )!;
      expect(change.doc.text, 'Keep *this*.\n\nx  y\n\n- after\n');
    });

    test('what Markdown cannot hold is refused, not written wrong', () {
      final doc = MdDoc.parse('# Title\n');
      final m = doc.blocks[0].inline!;
      expect(
        doc.edit(
          0,
          MdEdit('Ti\ntle', [...m.styles, m.styles[0]], a: 2, b: 2, ins: '\n'),
          caret: 3,
        ),
        isNull,
      );
      final p = MdDoc.parse('para\n');
      final pm = p.blocks[0].inline!;
      expect(
        p.edit(
          0,
          MdEdit(' para', [MdStyle.plain, ...pm.styles], a: 0, b: 0, ins: ' '),
          caret: 1,
        ),
        isNull,
      );
    });

    test('a link’s target is kept as written when its text changes', () {
      final change = type('[docs](<a b> "T")\n', 0, 4, '!');
      expect(change.doc.text, '[docs!](<a b> "T")\n');
    });
  });

  group('blocks', () {
    test(
      'Enter splits a paragraph into two, and a list item into two items',
      () {
        final doc = MdDoc.parse('one two\n\n1. first item\n');
        final split = doc.split(0, 3)!;
        expect(split.doc.text, 'one\n\ntwo\n\n1. first item\n');
        expect(split.block, 2);
        final item = split.doc.split(4, 5)!;
        expect(item.doc.text, 'one\n\ntwo\n\n1. first\n2. item\n');
        final end = MdDoc.parse('- a\n').split(0, 1)!;
        expect(end.doc.text, '- a\n-\n');
        expect(end.doc.blocks[1].editable, isTrue);
      },
    );

    test('Enter at the end of a paragraph makes an empty one to type into', () {
      final doc = MdDoc.parse('one\n');
      final split = doc.split(0, 3)!;
      expect(split.doc.text, 'one\n\n');
      final typed = split.doc.edit(
        split.block,
        const MdEdit('two', [MdStyle.plain, MdStyle.plain, MdStyle.plain]),
        caret: 3,
      )!;
      expect(typed.doc.text, 'one\n\ntwo\n');
    });

    test('Backspace at the start joins onto the block before', () {
      final doc = MdDoc.parse('one *a*\n\ntwo\n\n| t |\n|---|\n\nthree\n');
      final merged = doc.mergeBack(2)!;
      expect(merged.doc.text, 'one *a*two\n\n| t |\n|---|\n\nthree\n');
      expect(merged.block, 0);
      expect(merged.caret, 5);
      // A table between is not jumped over.
      expect(merged.doc.mergeBack(merged.doc.blocks.length - 1), isNull);
    });

    test('Backspace in an empty block after a table removes it alone', () {
      final doc = MdDoc.parse('| t |\n|---|\n\none\n');
      final m = doc.blocks[2].inline!;
      final emptied = doc.edit(
        2,
        MdEdit('', const [], a: 0, b: m.text.length),
        caret: 0,
      )!;
      expect(emptied.doc.blocks[2].raw, '');
      final gone = emptied.doc.mergeBack(2)!;
      expect(gone.doc.text, '| t |\n|---|\n');
      expect(gone.block, -1);
    });

    test('joining marks that run into each other writes the block afresh', () {
      final doc = MdDoc.parse('*one*\n\n*two*\n\n#\n\nthree\n');
      final merged = doc.mergeBack(2)!;
      expect(merged.doc.blocks.first.inline!.text, 'onetwo');
      expect(merged.doc.text, startsWith('*onetwo*\n'));
      // Into an empty heading, the text is written after its marker.
      final into = merged.doc.mergeBack(merged.doc.blocks.length - 1)!;
      expect(into.doc.text, '*onetwo*\n\n# three\n');
    });
  });

  group('corners', () {
    MdBlock first(String text) =>
        MdDoc.parse(text).blocks.firstWhere((b) => b.kind != MdBlockKind.gap);

    test('an HTML block cuts a paragraph short only when CommonMark says', () {
      expect(MdDoc.parse('para\n<div>\n').blocks.last.why, MdOpaque.html);
      expect(MdDoc.parse('para\n<!-- c -->\n').blocks.last.why, MdOpaque.html);
      expect(
        MdDoc.parse('para\n<script>\n</script>\n').blocks.last.why,
        MdOpaque.html,
      );
      // An inline tag at a line's start is the paragraph going on.
      expect(
        MdDoc.parse('para\n<span>x</span>\n').blocks.single.why,
        MdOpaque.inline,
      );
      for (final html in [
        '<pre>\ncode\n\nmore\n</pre>\n',
        '<?php x ?>\n',
        '<![CDATA[ x ]]>\n',
        '<!DOCTYPE html>\n',
      ]) {
        final blocks = MdDoc.parse(html).blocks;
        expect(blocks.single.why, MdOpaque.html, reason: html);
      }
    });

    test('a heading that is all hashes is not edited', () {
      expect(first('# ###\n').why, MdOpaque.setext);
    });

    test('spaces before a soft break show, and can be typed after', () {
      final m = first('one  \t\ntwo\n').inline;
      // Two spaces and a tab: no hard break, which needs spaces alone.
      expect(m!.text, 'one  \t\ntwo');
      final soft = first('one \ntwo\n').inline!;
      expect(soft.text, 'one \ntwo');
    });

    test('a code span is read past a longer run of backticks inside it', () {
      final m = first('a ``x ``` y`` b\n').inline!;
      expect(m.text, 'a x ``` y b');
    });

    test('a link target with escapes and nested brackets is kept', () {
      final m = first(
        r'[a](u\)v "t (x)")'
        '\n',
      ).inline!;
      expect(m.styles.first.link!.raw, r'(u\)v "t (x)")');
      expect(first('[a](u\n').why, MdOpaque.inline);
    });

    test('marks compare and print as what they are', () {
      const bold = MdStyle(bold: true, link: MdLink('u'));
      // Built at run time, so equal by value and not by being one constant.
      final again = MdStyle(bold: true, link: MdLink('u', raw: '(u)'));
      expect({bold, again}, hasLength(1));
      expect(again.hashCode, bold.hashCode);
      expect(bold.toString(), 'BL(u)');
      expect(first('x\n').toString(), contains('paragraph'));
    });

    test('a block written afresh escapes what would read as markup', () {
      MdDoc doc(String text) => MdDoc.parse(text);
      MdChange? edit(String text, String to, List<MdStyle> styles) =>
          doc(text).edit(0, MdEdit(to, styles), caret: 0);
      MdChange restyle(String text, String to, List<MdStyle> styles) =>
          edit(text, to, styles)!;

      const plain = MdStyle.plain;
      const italic = MdStyle(italic: true);
      const code = MdStyle(code: true);
      List<MdStyle> all(int n, MdStyle s) => List.filled(n, s);

      // A number and a hash at a line's start, and an entity.
      expect(
        restyle('x\n', '1. a\n# b &amp;', all(14, plain)).doc.text,
        '1\\. a\n\\# b \\&amp;\n',
      );
      // Spaces at a mark's edge go outside it; a paragraph cannot start
      // with one at all.
      expect(edit('x\n', ' a', all(2, italic)), isNull);
      expect(
        restyle('x y\n', 'x y', [italic, italic, plain]).doc.text,
        '*x* y\n',
      );
      expect(
        restyle('x y\n', 'x y z', [
          plain,
          italic,
          italic,
          italic,
          plain,
        ]).doc.text,
        'x *y* z\n',
      );
      // Code holding backticks and spaces.
      expect(restyle('x\n', '`a`', all(3, code)).doc.text, '`` `a` ``\n');
      expect(restyle('x\n', ' a ', all(3, code)).doc.text, '`  a  `\n');
      // A list item's soft break keeps the item's indent.
      final item = MdDoc.parse('- a\n');
      final im = item.blocks[0].inline!;
      expect(
        item
            .edit(0, MdEdit('a\nb', [...im.styles, italic, italic]), caret: 3)!
            .doc
            .text,
        '- a\n  *b*\n',
      );
    });
  });
}
