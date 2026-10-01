import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/markdown_input.dart';

const _dim = Color(0xFF777777);
const _accent = Color(0xFF00AAFF);
const _panel = Color(0xFF222222);

MarkdownEditingController _controller() => MarkdownEditingController(
  mono: 'Mono',
  dim: _dim,
  accent: _accent,
  panel: _panel,
);

/// What the field draws.
RenderEditable _editable(WidgetTester tester) =>
    tester.renderObject<RenderEditable>(
      find.descendant(
        of: find.byType(EditableText),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_Editable',
        ),
      ),
    );

/// The box's spans as (text, style), the field's own style merged in.
Future<List<(String, TextStyle?)>> _spans(
  WidgetTester tester,
  MarkdownEditingController c,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TextField(controller: c, maxLines: null)),
    ),
  );
  final root = _editable(tester).text!;
  final out = <(String, TextStyle?)>[];
  root.visitChildren((span) {
    if (span is TextSpan && span.text != null) {
      out.add((span.text!, span.style));
    }
    return true;
  });
  return out;
}

void main() {
  testWidgets('bold is drawn bold, its markers dimmed, and the text is what '
      'was typed', (tester) async {
    final c = _controller()..text = 'say **bold** now';
    final spans = await _spans(tester, c);

    expect(spans.map((s) => s.$1).join(), 'say **bold** now');
    final bold = spans.singleWhere((s) => s.$1 == 'bold');
    expect(bold.$2!.fontWeight, FontWeight.bold);
    final markers = spans.where((s) => s.$1 == '**').toList();
    expect(markers, hasLength(2));
    for (final m in markers) {
      expect(m.$2!.color, _dim);
    }
    expect(
      spans.firstWhere((s) => s.$1.startsWith('say')).$2?.fontWeight,
      isNot(FontWeight.bold),
    );
  });

  testWidgets('code, strike, italic, links, quotes, lists, headings and '
      'fences each get their look, and nothing is dropped', (tester) async {
    const typed =
        '# Title\n'
        '> quoted\n'
        '- item with `code` and ~~gone~~ and *lean* and _also_\n'
        'see [docs](https://example.com)\n'
        '```dart\n'
        'final x = 1;\n'
        '```\n'
        'after';
    final c = _controller()..text = typed;
    final spans = await _spans(tester, c);
    TextStyle? of(String text) => spans.firstWhere((s) => s.$1 == text).$2;

    expect(spans.map((s) => s.$1).join(), typed);
    expect(of('# ')!.color, _dim);
    expect(of('Title')!.fontWeight, FontWeight.bold);
    expect(of('quoted')!.fontStyle, FontStyle.italic);
    expect(of('- ')!.color, _accent);
    expect(of('code')!.fontFamily, 'Mono');
    expect(of('code')!.backgroundColor, _panel);
    expect(of('gone')!.decoration, TextDecoration.lineThrough);
    expect(of('lean')!.fontStyle, FontStyle.italic);
    expect(of('also')!.fontStyle, FontStyle.italic);
    expect(of('docs')!.color, _accent);
    expect(of('docs')!.decoration, TextDecoration.underline);
    expect(of('final x = 1;')!.fontFamily, 'Mono');
    expect(of('```dart')!.color, _dim);
    expect(of('after')?.fontFamily, isNot('Mono'));
  });

  testWidgets('stray stars and underscores are left as they are', (
    tester,
  ) async {
    final c = _controller()..text = '2 * 3 * 4 and snake_case_name';
    final spans = await _spans(tester, c);
    expect(spans.map((s) => s.$1).join(), '2 * 3 * 4 and snake_case_name');
    expect(spans.every((s) => s.$2?.fontStyle != FontStyle.italic), isTrue);
  });

  testWidgets('an IME composing region keeps its underline, over the '
      'Markdown style under it', (tester) async {
    final c = _controller();
    await _spans(tester, c);
    // Flutter draws a composing region only in a focused field.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    c.value = const TextEditingValue(
      text: 'a **bold** b',
      selection: TextSelection.collapsed(offset: 8),
      composing: TextRange(start: 5, end: 8),
    );
    final spans = await _spans(tester, c);

    expect(spans.map((s) => s.$1).join(), 'a **bold** b');
    final composing = spans.singleWhere(
      (s) => s.$2?.decoration == TextDecoration.underline,
    );
    expect(composing.$1, 'old');
    expect(composing.$2!.fontWeight, FontWeight.bold);
  });

  testWidgets('typing leaves the caret where it was typed, and the text as '
      'it was typed', (tester) async {
    final c = _controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: c)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'a **b** c');
    // The caret in the middle, then a character typed there.
    c.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a **xb** c',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();

    expect(c.text, 'a **xb** c');
    expect(c.selection, const TextSelection.collapsed(offset: 5));
    final editable = _editable(tester);
    expect(editable.selection, const TextSelection.collapsed(offset: 5));
    expect(editable.text!.toPlainText(), 'a **xb** c');
  });

  testWidgets('past 20 KB the box is plain text', (tester) async {
    final c = _controller()
      ..text = '**x** ${'y' * MarkdownEditingController.plainPast}';
    final spans = await _spans(tester, c);
    expect(spans.every((s) => s.$2?.fontWeight != FontWeight.bold), isTrue);
  });

  test('a long line of openers with no closers is drawn plain, and fast', () {
    // Each opener's lazy scan ran to the line's end: seconds a keystroke.
    for (final opener in ['**a ', '*a ', '_a ', '~~a ', '[a ']) {
      final line = opener * (19 * 1024 ~/ opener.length);
      final watch = Stopwatch()..start();
      final runs = markdownRuns('**ok** $line', _controller());
      watch.stop();
      expect(runs, hasLength(1), reason: opener);
      expect(runs.single.$3, isNull, reason: opener);
      // Generous for CI: it was 1.2–2.4 s, and is now a few milliseconds.
      expect(watch.elapsedMilliseconds, lessThan(200), reason: opener);
    }
    // Short lines beside it are still styled.
    final runs = markdownRuns('**ok**\n${'*a ' * 1000}', _controller());
    expect(runs.any((r) => r.$3?.fontWeight == FontWeight.bold), isTrue);
  });

  test('an [Image #N] of a picture the message carries is a chip, and any '
      'other is text', () {
    final c = _controller()..pictures = {1};
    const text = '[Image #1] and [Image #2]';
    final runs = markdownRuns(text, c);
    String of((int, int, TextStyle?) run) => text.substring(run.$1, run.$2);
    final chip = runs.singleWhere((run) => of(run) == '[Image #1]');
    expect(chip.$3?.color, _accent);
    expect(chip.$3?.backgroundColor, isNotNull);
    // The other is no picture's: it reads as typed, unstyled.
    final other = runs.where((run) => of(run).contains('[Image #2]'));
    expect(other.map((run) => run.$3?.backgroundColor), everyElement(isNull));
    // Every character is still there.
    expect(runs.map(of).join(), text);
  });

  testWidgets('an [Image #N] whose number no int holds is drawn as text, '
      'never thrown on', (tester) async {
    final c = _controller()..pictures = {1};
    c.text = '[Image #99999999999999999999] and [Image #1]';
    final spans = await _spans(tester, c);
    expect(tester.takeException(), isNull);
    expect(spans.map((span) => span.$1).join(), c.text);
    final long = spans.where((span) => span.$1.contains('9999'));
    expect(long.map((span) => span.$2?.backgroundColor), everyElement(isNull));
  });
}
