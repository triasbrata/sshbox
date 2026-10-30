import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/markdown_live.dart';
import 'package:sshbox/src/ui/markdown_rich_editor.dart';
import 'package:sshbox/src/ui/save_chord.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';
import 'package:sshbox/src/ui/termul/tui_checkbox.dart';
import 'package:sshbox/src/ui/tui.dart' show jeanshTheme;

class _Host {
  _Host(this.text);

  String text;
  final changes = <(String, bool)>[];
  final opened = <MdLink>[];
  final refused = <String>[];
  String? linkAnswer;
  final controller = MarkdownRichController();
  late StateSetter setState;

  void set(String next) => setState(() => text = next);
}

Future<_Host> _pump(
  WidgetTester tester,
  String text, {
  Size size = const Size(800, 600),
}) async {
  final host = _Host(text);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: TermulTheme.of(TermulPalette.paper),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            host.setState = setState;
            return MarkdownRichEditor(
              text: host.text,
              controller: host.controller,
              onChanged: (t, {required coalesce}) {
                host.changes.add((t, coalesce));
                setState(() => host.text = t);
              },
              blockBuilder: (context, md) => Text(
                'RENDERED ${md.split('\n').first}',
                key: ValueKey('rendered ${md.hashCode}'),
              ),
              onOpenLink: host.opened.add,
              onRefused: host.refused.add,
              askLink: (_) async => host.linkAnswer,
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return host;
}

TextEditingController _controller(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller;

/// What the field draws now, as a reader sees it: hidden text left out and
/// a widget as ■.
String _shown(WidgetTester tester) {
  final c = _controller(tester);
  final span = c.buildTextSpan(
    context: tester.element(find.byType(EditableText)),
    withComposing: false,
  );
  final out = StringBuffer();
  void walk(InlineSpan s) {
    if (s is WidgetSpan) {
      out.write('■');
      return;
    }
    final t = s as TextSpan;
    final hidden = (t.style?.fontSize ?? 1) < 0.1;
    if (t.text != null && !hidden) out.write(t.text);
    t.children?.forEach(walk);
  }

  walk(span);
  return out.toString();
}

Future<void> _caret(WidgetTester tester, int offset) async {
  await tester.showKeyboard(find.byType(EditableText));
  _controller(tester).selection = TextSelection.collapsed(offset: offset);
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  final v = _controller(tester).value;
  final sel = v.selection;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    ),
  );
  await tester.pump();
}

String? _clipboard;

void _mockClipboard(WidgetTester tester) {
  _clipboard = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _clipboard = (call.arguments as Map)['text'] as String?;
      }
      if (call.method == 'Clipboard.getData') return {'text': _clipboard};
      return null;
    },
  );
}

const _doc = '''
# Notes

A **bold** first paragraph with a [link](https://e.x/a).

Second paragraph here.

- [ ] a task
- plain item

| a | b |
|---|---|
| 1 | 2 |

The end.
''';

void main() {
  testWidgets('opened, read and selected, nothing changes', (tester) async {
    _mockClipboard(tester);
    final host = await _pump(tester, _doc);
    // Only read, the page is its sections, each drawn apart.
    expect(_shown(tester), '■■');
    await _caret(tester, 0);
    // With the caret in, every marker but the heading's is hidden.
    expect(_shown(tester), startsWith('# Notes\n\nA bold first paragraph'));
    expect(_shown(tester), isNot(contains('**')));
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(_clipboard, _doc);
    expect(host.changes, isEmpty);
    expect(host.text, same(_doc));
  });

  testWidgets('Shift+Down from a list runs over a blank line into the next '
      'block', (tester) async {
    const text =
        '# Rich e2e\n\n* first item\n- second item\n\n'
        'A *plain* paragraph here. added\n\n- [x] a task\n\n'
        '| a | b |\n|---|---|\n| 1 | 2 |\n';
    // As the Linux desktop test drives it, where the selection stuck.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await _pump(tester, text);
    await _caret(tester, text.indexOf('* first'));
    final ends = <int>[];
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      ends.add(_controller(tester).selection.extentOffset);
      if (i == 1) {
        // A pause: the floating bar comes up over the selection, and the
        // presses after it go on from where they were.
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byType(MarkdownFloatingBar), findsOneWidget);
      }
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    debugDefaultTargetPlatformOverride = null;
    expect(ends, [
      text.indexOf('- second'),
      text.indexOf('\n\nA') + 1,
      text.indexOf('A *plain'),
      text.indexOf('\n\n- [x]') + 1,
    ]);
  });

  testWidgets('a selection runs across blocks and copies their source', (
    tester,
  ) async {
    _mockClipboard(tester);
    final host = await _pump(tester, _doc);
    final from = _doc.indexOf('first');
    await _caret(tester, from);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    final sel = _controller(tester).selection;
    expect(sel.start, from);
    expect(sel.end, greaterThan(_doc.indexOf('Second paragraph') + 6));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    expect(_clipboard, _doc.substring(sel.start, sel.end));
    expect(_clipboard, contains('[link](https://e.x/a).\n\nSecond'));
    // And bolded across both, each block on its own, only markers added.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    final after = host.text;
    expect(after.replaceAll('**', ''), _doc.replaceAll('**', ''));
    expect(
      after,
      contains('**first paragraph with a [link](https://e.x/a).**'),
    );
    expect(after, contains('**Second'));
  });

  testWidgets(
    'a copy across a section shaped as blanks copies its words',
    semanticsEnabled: false,
    (tester) async {
      _mockClipboard(tester);
      final text = [
        for (var k = 0; k < 6; k++) 'First para $k.',
        for (var k = 0; k < 6; k++) 'Middle words $k.',
        for (var k = 0; k < 6; k++) 'Last para $k.',
      ].join('\n\n');
      await _pump(tester, text);
      await _caret(tester, 2);
      // Select all: its ends touch the first and last sections, so the one
      // between them stays drawn apart, shaped as blanks.
      _controller(tester).selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
      await tester.pump();
      final drawn = tester.allRenderObjects
          .whereType<RenderEditable>()
          .first
          .text!
          .toPlainText(includePlaceholders: true);
      expect(drawn, isNot(contains('Middle')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      expect(_clipboard, text);
    },
  );

  testWidgets('# typed at a line start makes a heading', (tester) async {
    final host = await _pump(tester, 'Intro\n\n\n\nEnd');
    await _caret(tester, 7);
    await _type(tester, '#');
    await _type(tester, ' ');
    await _type(tester, 'Title');
    expect(host.text, 'Intro\n\n# Title\n\nEnd');
    // On its line the hashes show; elsewhere it reads as a heading.
    expect(_shown(tester), contains('# Title'));
    await _caret(tester, 0);
    expect(_shown(tester), 'Intro\n\nTitle\n\nEnd');
    final live = MdLive.parse(host.text);
    expect(MdMark.heading(live.marks[host.text.indexOf('Title')]), 1);
  });

  testWidgets('Enter in a list goes on with it', (tester) async {
    final host = await _pump(tester, '- one');
    await _caret(tester, 5);
    await _type(tester, '\n');
    expect(host.text, '- one\n- ');
    expect(_controller(tester).selection.baseOffset, 8);
  });

  testWidgets('markers show where the caret is and hide as it leaves', (
    tester,
  ) async {
    await _pump(tester, 'Some **bold** words.\n\nNext.');
    await _caret(tester, 2);
    expect(_shown(tester), 'Some bold words.\n\nNext.');
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    // At the span's edge, as the arrows come to it.
    expect(_controller(tester).selection.baseOffset, 5);
    expect(_shown(tester), 'Some **bold** words.\n\nNext.');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(_shown(tester), 'Some bold words.\n\nNext.');
  });

  testWidgets(
    'a table draws rendered, and as its source with the caret in it',
    (tester) async {
      final host = await _pump(tester, _doc);
      await _caret(tester, 0);
      expect(find.textContaining('RENDERED | a | b |'), findsOneWidget);
      await _caret(tester, _doc.indexOf('| 1 |') + 3);
      expect(find.textContaining('RENDERED | a | b |'), findsNothing);
      expect(_shown(tester), contains('| a | b |\n|---|---|\n| 1 | 2 |'));
      // Edited in place, as any other text.
      await _type(tester, '0');
      expect(host.text, _doc.replaceFirst('| 1 |', '| 10 |'));
    },
  );

  testWidgets('a task box ticks with a tap, one character changed', (
    tester,
  ) async {
    final host = await _pump(tester, _doc);
    await tester.tap(find.byType(TuiCheckbox));
    await tester.pump();
    expect(host.text, _doc.replaceFirst('- [ ] a task', '- [x] a task'));
    expect(host.changes.single.$2, isFalse);
    await tester.tap(find.byType(TuiCheckbox));
    await tester.pump();
    expect(host.text, _doc);
  });

  testWidgets('IME composing beside hidden markers keeps the text as typed', (
    tester,
  ) async {
    final host = await _pump(tester, '**bold**\n\nx');
    await _caret(tester, 8);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '**bold**か\n\nx',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 8, end: 9),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '**bold**かな\n\nx',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 8, end: 10),
      ),
    );
    await tester.pump();
    expect(
      _controller(tester).value.composing,
      const TextRange(start: 8, end: 10),
    );
    // The caret beside the span shows its markers, so nothing composes
    // inside a hidden one.
    expect(_shown(tester), startsWith('**bold**かな'));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '**bold**仮名\n\nx',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    await tester.pump();
    expect(host.text, '**bold**仮名\n\nx');
  });

  testWidgets('read back after an undo from outside', (tester) async {
    final host = await _pump(tester, 'one two');
    await _caret(tester, 3);
    await _type(tester, 'X');
    expect(host.text, 'oneX two');
    host.set('one two');
    await tester.pump();
    expect(_controller(tester).text, 'one two');
    expect(_controller(tester).selection.baseOffset, 3);
  });

  testWidgets('Ctrl+click opens a link and a plain tap does not', (
    tester,
  ) async {
    const text = 'A [link](https://e.x/a) here.';
    final host = await _pump(tester, text);
    await _caret(tester, text.length);
    Offset point(int offset) {
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final p = editable
          .getEndpointsForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + 1),
          )
          .first
          .point;
      return editable.localToGlobal(p + const Offset(3, -6));
    }

    await tester.tapAt(point(4));
    await tester.pump();
    expect(host.opened, isEmpty);
    // The caret in it shows its markup; the place is taken again.
    expect(_shown(tester), text);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.tapAt(point(4));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(host.opened.single.href, 'https://e.x/a');
    expect(host.changes, isEmpty);
  });

  testWidgets('a tap on a section drawn apart puts the caret where it landed', (
    tester,
  ) async {
    final text = List.generate(
      30,
      (i) => 'Paragraph number $i ends',
    ).join('\n\n');
    await _pump(tester, text);
    await _caret(tester, 0);
    final target = find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText().contains('Paragraph number 10 ends'),
    );
    expect(target, findsOneWidget, reason: 'drawn apart, as its own text');
    final paragraph = tester.renderObject<RenderParagraph>(target);
    final local = paragraph.text.toPlainText().indexOf('Paragraph number 10');
    final rect = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: local + 10, extentOffset: local + 11),
        )
        .first;
    await tester.tapAt(paragraph.localToGlobal(rect.toRect().center));
    await tester.pump();
    await tester.pump();
    final at = _controller(tester).selection.baseOffset;
    final want = text.indexOf('Paragraph number 10') + 10;
    expect((at - want).abs(), lessThanOrEqualTo(1), reason: 'at $at');
  });

  testWidgets('focused, the page draws no field box, fill or accent line', (
    tester,
  ) async {
    // The app's own theme, whose fields are filled and outlined.
    await tester.pumpWidget(
      MaterialApp(
        theme: jeanshTheme(TermulPalette.paper),
        home: Scaffold(
          body: MarkdownRichEditor(
            text: 'one two',
            onChanged: (t, {required coalesce}) {},
            blockBuilder: (context, md) => Text(md),
            onOpenLink: (_) {},
            onRefused: (_) {},
            askLink: (_) async => null,
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(EditableText));
    await tester.pump();
    final decorator = tester.widget<InputDecorator>(
      find.byType(InputDecorator),
    );
    expect(decorator.isFocused, isTrue);
    final d = decorator.decoration;
    expect(d.filled, isFalse);
    for (final border in [
      d.border,
      d.enabledBorder,
      d.focusedBorder,
      d.disabledBorder,
    ]) {
      expect(border, InputBorder.none);
    }
  });

  testWidgets('sections drawn apart sit one under the other with no gap', (
    tester,
  ) async {
    final text = List.generate(
      8,
      (i) => 'Paragraph $i\nwith a second line',
    ).join('\n\n');
    await _pump(tester, text);
    final sections = find.byWidgetPredicate((w) => w is RichText);
    final rects =
        sections
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
    expect(rects.length, greaterThan(2));
    // The hidden source behind a section takes no room of its own: the next
    // section starts where the last one ends.
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top - rects[i - 1].bottom, lessThan(1), reason: '$i');
    }
    // And a section drawn as text takes the room it took drawn apart: the
    // caret going into the first moves nothing below it.
    final last = rects.last.top;
    await _caret(tester, 2);
    final now = find
        .byWidgetPredicate((w) => w is RichText)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)).top);
    expect(now.reduce((a, b) => a > b ? a : b), closeTo(last, 1));
  });

  testWidgets('a wide page is a centred column, and the wheel over its side '
      'scrolls it', (tester) async {
    final text = List.generate(80, (i) => 'Line $i of the page').join('\n\n');
    await _pump(tester, text, size: const Size(1400, 600));
    final field = tester.getRect(find.byType(EditableText));
    // The text column: 720 wide, in the middle.
    expect(field.width, 720);
    expect(field.left, (1400 - 720) / 2);
    final scroll = tester
        .widget<EditableText>(find.byType(EditableText))
        .scrollController!;
    expect(scroll.offset, 0);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    // Over the left gutter, well outside the text.
    await tester.sendEventToBinding(pointer.hover(const Offset(60, 300)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pump();
    expect(scroll.offset, 300);
    // Over the text, the field's own scrolling, once: not twice.
    await tester.sendEventToBinding(pointer.hover(const Offset(700, 300)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
    expect(scroll.offset, 400);
  });

  group('desktop', () {
    testWidgets('a selection brings up the floating bar, and B bolds it', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final host = await _pump(tester, 'one two three\n\nnext');
        await _caret(tester, 4);
        expect(find.byType(MarkdownFloatingBar), findsNothing);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
        // Put up once the selection has held still.
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byType(MarkdownFloatingBar), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(MarkdownFloatingBar),
            matching: find.text('B'),
          ),
        );
        await tester.pump();
        expect(host.text, 'one **two** three\n\nnext');
        // Back to a caret, the bar goes.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        expect(find.byType(MarkdownFloatingBar), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Ctrl+B, I, E bold, italicise and code the selection', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final host = await _pump(tester, 'a b c');
        Future<void> chord(LogicalKeyboardKey key, int from, int to) async {
          _controller(tester).selection = TextSelection(
            baseOffset: from,
            extentOffset: to,
          );
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
          await tester.pump();
        }

        await tester.showKeyboard(find.byType(EditableText));
        await chord(LogicalKeyboardKey.keyB, 0, 1);
        expect(host.text, '**a** b c');
        await chord(LogicalKeyboardKey.keyI, 6, 7);
        expect(host.text, '**a** _b_ c');
        await chord(LogicalKeyboardKey.keyE, 10, 11);
        expect(host.text, '**a** _b_ `c`');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('the phone bar marks headings and quotes', (tester) async {
    final host = await _pump(tester, 'Title\n\nbody');
    await _caret(tester, 2);
    host.controller.toggleHeading(1);
    await tester.pump();
    expect(host.text, '# Title\n\nbody');
    expect(host.controller.format!.heading, 1);
    host.controller.toggleQuote();
    await tester.pump();
    expect(host.text, '> # Title\n\nbody');
    expect(host.controller.format!.quote, isTrue);
  });

  testWidgets('a link is added to a selection, edited and taken off', (
    tester,
  ) async {
    final host = await _pump(tester, 'see here now');
    await tester.showKeyboard(find.byType(EditableText));
    _controller(tester).selection = TextSelection(
      baseOffset: 4,
      extentOffset: 8,
    );
    host.linkAnswer = 'https://a.b';
    await host.controller.editLink();
    await tester.pump();
    expect(host.text, 'see [here](https://a.b) now');
    _controller(tester).selection = const TextSelection.collapsed(offset: 6);
    host.linkAnswer = 'https://c.d';
    await host.controller.editLink();
    await tester.pump();
    expect(host.text, 'see [here](https://c.d) now');
    _controller(tester).selection = const TextSelection.collapsed(offset: 6);
    host.linkAnswer = '';
    await host.controller.editLink();
    await tester.pump();
    expect(host.text, 'see here now');
    _controller(tester).selection = const TextSelection.collapsed(offset: 1);
    await host.controller.editLink();
    expect(host.refused, ['Select the text to link first.']);
  });

  testWidgets(
    'sections away from the caret are shaped as blanks, line '
    'breaks kept, unless a screen reader reads the text',
    semanticsEnabled: false,
    (tester) async {
      const text =
          '# Title\n\nFirst **para**.\n\nSecond one\nwith two lines.\n';
      await _pump(tester, text);
      String drawn() => tester.allRenderObjects
          .whereType<RenderEditable>()
          .first
          .text!
          .toPlainText(includePlaceholders: true);

      final blank = drawn();
      expect(blank.length, text.length);
      expect(blank, isNot(contains('Second')));
      expect(blank, isNot(contains('First')));
      for (var k = 0; k < text.length; k++) {
        if (text[k] == '\n') expect(blank[k], '\n', reason: 'at $k');
      }

      final reader = tester.ensureSemantics();
      await tester.pump();
      expect(drawn(), contains('Second one\nwith two lines.'));
      reader.dispose();
      await tester.pump();
      expect(drawn(), isNot(contains('Second')));
    },
  );

  testWidgets('front matter draws as keys and values, <details> as its '
      'summary and <img> as its picture; the caret shows the source, and '
      'nothing changes', (tester) async {
    const doc =
        '---\ntitle: notes\ntags:\n  - a\n  - b\nloose line\n---\n\n'
        'Text<br>more and <img src="p.png" alt="P">.\n\n'
        '<details>\n<summary>More</summary>\n\nInside.\n\n</details>\n';
    final host = await _pump(tester, doc);
    await tester.pump();
    expect(find.text('title'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('tags'), findsOneWidget);
    expect(find.text('- a\n- b\nloose line'), findsOneWidget);
    expect(find.text('▾ More'), findsOneWidget);
    expect(find.text('RENDERED ![P](<p.png>)'), findsOneWidget);
    expect(_shown(tester), isNot(contains('<br>')));

    // The caret in the front matter: its source, and the rows go.
    await tester.showKeyboard(find.byType(EditableText));
    _controller(tester).selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();
    expect(find.text('title'), findsNothing);
    expect(_shown(tester), startsWith('---\ntitle: notes\n'));
    // In the paragraph: the tags as written.
    _controller(tester).selection = TextSelection.collapsed(
      offset: doc.indexOf('<br>') + 1,
    );
    await tester.pump();
    expect(_shown(tester), contains('Text<br>more'));
    expect(host.changes, isEmpty);

    // An empty front matter and an unnamed summary draw too.
    FocusManager.instance.primaryFocus?.unfocus();
    host.set('---\n---\n\n<details open>\n\nx\n');
    await tester.pump();
    await tester.pump();
    expect(find.text('▾ Details'), findsOneWidget);
  });

  group('task boxes for a screen reader', () {
    const doc = '# Tasks\n\n- [ ] open one\n- [x] done one\n\nA paragraph.\n';

    testWidgets('each box is a checkbox node with its state and its text, '
        'and a tap on the node ticks it, one character', (tester) async {
      final host = await _pump(tester, doc);
      await tester.pump();
      final open = find.bySemanticsLabel('open one');
      final done = find.bySemanticsLabel('done one');
      expect(
        tester.getSemantics(open),
        isSemantics(
          hasCheckedState: true,
          isChecked: false,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(done),
        isSemantics(hasCheckedState: true, isChecked: true),
      );
      // Read as a page, with no caret: the boxes are in sections drawn
      // apart. A tap through the screen reader ticks the right one.
      tester.semantics.tap(find.semantics.byLabel('open one'));
      await tester.pump();
      expect(host.text, doc.replaceFirst('- [ ] open', '- [x] open'));
      await tester.pump();
      expect(
        tester.getSemantics(find.bySemanticsLabel('open one')),
        isSemantics(isChecked: true),
      );

      // With the caret in the list the boxes are drawn in the field itself.
      await tester.showKeyboard(find.byType(EditableText));
      _controller(tester).selection = TextSelection.collapsed(
        offset: host.text.indexOf('done one'),
      );
      await tester.pump();
      await tester.pump();
      tester.semantics.tap(find.semantics.byLabel('done one'));
      await tester.pump();
      expect(
        host.text,
        doc.replaceAll('[x]', '[ ]').replaceFirst('- [ ] open', '- [x] open'),
      );
    });

    testWidgets('a box scrolled out of the page has no node until it is '
        'scrolled back in', (tester) async {
      final text =
          '${List.filled(60, 'A line of text.').join('\n\n')}\n\n- [ ] far task\n';
      await _pump(tester, text);
      await tester.pump();
      expect(find.bySemanticsLabel('far task'), findsNothing);
      final scroll = tester
          .widget<EditableText>(find.byType(EditableText))
          .scrollController!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('far task'), findsOneWidget);
    });

    testWidgets('with no semantics asked for, no nodes are laid over the '
        'boxes', (tester) async {
      await _pump(tester, doc);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(MarkdownRichEditor),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'open one',
          ),
        ),
        findsNothing,
      );
    }, semanticsEnabled: false);
  });

  group('Android hardware chords', () {
    const share = MethodChannel('sshbox/share');
    late List<Object?> told;

    setUp(() {
      RichChords.reset();
      SaveChord.reset();
      told = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(share, (call) async {
            if (call.method == 'richChords') told.add(call.arguments);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(share, null);
      RichChords.reset();
      SaveChord.reset();
    });

    /// MainActivity's call when it takes a chord before Gboard.
    Future<void> native(String chord) => TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          'sshbox/keys',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('rich', chord),
          ),
          (_) {},
        );

    testWidgets('claimed while Rich text holds the focus: Ctrl+B, I, E and '
        'Shift+arrows from native act on the selection', (tester) async {
      final host = await _pump(tester, 'one word here\nnext line\n');
      expect(told, isEmpty);
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      expect(told, [true]);

      final c = _controller(tester);
      c.selection = const TextSelection(baseOffset: 4, extentOffset: 8);
      await native('bold');
      await tester.pump();
      expect(host.text, 'one **word** here\nnext line\n');
      await native('bold');
      await tester.pump();
      expect(host.text, 'one word here\nnext line\n');

      c.selection = const TextSelection(baseOffset: 4, extentOffset: 8);
      await native('italic');
      await tester.pump();
      expect(host.text, 'one _word_ here\nnext line\n');
      host.set('one word here\nnext line\n');
      await tester.pump();
      c.selection = const TextSelection(baseOffset: 4, extentOffset: 8);
      await native('code');
      await tester.pump();
      expect(host.text, 'one `word` here\nnext line\n');

      host.set('one word here\nnext line\n');
      await tester.pump();
      c.selection = const TextSelection.collapsed(offset: 4);
      await native('select:right');
      await tester.pump();
      expect(c.selection, const TextSelection(baseOffset: 4, extentOffset: 5));
      await native('select:right:word');
      await tester.pump();
      expect(c.selection, const TextSelection(baseOffset: 4, extentOffset: 8));
      await native('select:left');
      await tester.pump();
      expect(c.selection, const TextSelection(baseOffset: 4, extentOffset: 7));
      await native('select:left:word');
      await tester.pump();
      expect(c.selection.extentOffset, 4);
      await native('select:down');
      await tester.pump();
      // Down a line: the selection now ends on the next line.
      expect(c.selection.baseOffset, 4);
      expect(c.selection.extentOffset, greaterThan('one word here\n'.length));
      await native('select:up');
      await tester.pump();
      expect(c.selection.extentOffset, lessThan('one word here\n'.length));
      // Nothing the editor does not know: no change.
      final before = c.value;
      await native('select:sideways');
      await native('nonsense');
      await tester.pump();
      expect(c.value, before);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a link chord asks for the address', (tester) async {
      final host = await _pump(tester, 'one word here');
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      host.linkAnswer = 'https://e.x';
      _controller(tester).selection = TextSelection(
        baseOffset: 4,
        extentOffset: 8,
      );
      await native('link');
      await tester.pumpAndSettle();
      expect(host.text, 'one [word](https://e.x) here');
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('let go when the focus leaves and when it closes; a chord '
        'then changes nothing', (tester) async {
      final host = await _pump(tester, 'one word here');
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      _controller(tester).selection = TextSelection(
        baseOffset: 4,
        extentOffset: 8,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(told, [true, false]);
      await native('bold');
      await tester.pump();
      expect(host.text, 'one word here');

      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      expect(told, [true, false, true]);
      await tester.pumpWidget(const SizedBox());
      expect(told, [true, false, true, false]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('nothing is claimed on a desktop', (tester) async {
      await _pump(tester, 'one word here');
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      expect(told, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}
