import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_code_editor.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(body: SizedBox(width: 480, height: 420, child: child)),
      ),
    );
  }

  test('tuiMarkdownBlocksFrom parses headings, code, list, image', () {
    final blocks = tuiMarkdownBlocksFrom('''
# Title

```dart
print(1);
```

- a
- b

![alt](pic.png)
''');
    expect(blocks.whereType<TuiMdHeading>(), hasLength(1));
    expect(blocks.whereType<TuiMdCodeBlock>().first.language, 'dart');
    expect(blocks.whereType<TuiMdList>().first.items, ['a', 'b']);
    expect(blocks.whereType<TuiMdImage>().first.src, 'pic.png');
  });

  testWidgets('source shows gutters and dirty subtitle', (tester) async {
    await pumpHost(
      tester,
      const TuiCodeEditor(
        path: 'a.md',
        dirty: true,
        lines: [
          TuiCodeLine(number: 1, text: '# hi'),
          TuiCodeLine(number: 2, text: 'body'),
        ],
      ),
    );
    expect(find.text('a.md'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('# hi'), findsOneWidget);
  });

  testWidgets('preview mode renders markdown blocks', (tester) async {
    await pumpHost(
      tester,
      TuiCodeEditor(
        path: 'a.md',
        showModeToggle: true,
        mode: TuiCodeViewMode.preview,
        onModeChanged: (_) {},
        previewChild: TuiMarkdownPreview(
          blocks: tuiMarkdownBlocksFrom('# Hello\n\npara'),
        ),
      ),
    );
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('para'), findsOneWidget);
    expect(find.text('SOURCE'), findsOneWidget);
    expect(find.text('PREVIEW'), findsOneWidget);
  });

  testWidgets('binary and loading states', (tester) async {
    await pumpHost(tester, const TuiCodeEditor(path: 'x.bin', binary: true));
    expect(find.textContaining('binary'), findsOneWidget);

    await pumpHost(tester, const TuiCodeEditor(path: 'x', loading: true));
    expect(find.text('loading…'), findsOneWidget);
  });

  testWidgets('find bar shows match label and replace row', (tester) async {
    final findCtrl = TextEditingController(text: 'foo');
    final replaceCtrl = TextEditingController();
    addTearDown(findCtrl.dispose);
    addTearDown(replaceCtrl.dispose);

    await pumpHost(
      tester,
      TuiCodeEditor(
        path: 'a.dart',
        lines: const [TuiCodeLine(number: 1, text: 'foo')],
        findBar: TuiFindBar(
          findController: findCtrl,
          replaceController: replaceCtrl,
          replaceMode: true,
          matchLabel: '1/1',
          onClose: () {},
        ),
      ),
    );
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('Replace with'), findsOneWidget);
  });

  testWidgets('code block copy button', (tester) async {
    var copied = false;
    await pumpHost(
      tester,
      TuiMarkdownPreview(
        blocks: [
          TuiMdCodeBlock(
            code: 'x = 1',
            language: 'py',
            onCopy: () => copied = true,
          ),
        ],
      ),
    );
    await tester.tap(find.text('copy'));
    expect(copied, isTrue);
  });
}
