import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';

import 'fake_file_browser.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  FakeFileBrowser browser, {
  String path = '/home/me/notes.txt',
}) async {
  await tester.pumpWidget(
    MaterialApp(home: FileEditorPage(browser: browser, path: path)),
  );
  await tester.pumpAndSettle();
}

bool _canSave(WidgetTester tester) => tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.save_outlined))
        .onPressed !=
    null;

void main() {
  testWidgets('shows what the file holds', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'first line\nsecond line\n',
    );
  });

  testWidgets('cannot save until something changed', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    expect(_canSave(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pumpAndSettle();
    expect(_canSave(tester), isTrue);

    // Typed back to what it was: there is nothing to send, so the button goes
    // quiet again rather than offering a write that changes nothing.
    await tester.enterText(find.byType(TextField), 'first line\nsecond line\n');
    await tester.pumpAndSettle();
    expect(_canSave(tester), isFalse);
  });

  testWidgets('saving writes through and settles', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    await tester.enterText(find.byType(TextField), 'rewritten\n');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(browser.contents['/home/me/notes.txt'], 'rewritten\n');
    expect(find.text('Saved notes.txt'), findsOneWidget);
    expect(_canSave(tester), isFalse);
  });

  testWidgets('guards an unsaved edit against a stray back', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    await tester.enterText(find.byType(TextField), 'half typed');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // There is no undo on the far end, so leaving has to be deliberate.
    expect(find.text('Discard changes?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('refuses a file too large to edit, and says how large',
      (tester) async {
    final browser = FakeFileBrowser()
      ..failReadWith = const FileBrowserException(
        '48 MB is too large to open here. Use the terminal for a file this '
        'size.',
        fault: FileBrowserFault.tooLarge,
      );
    await _pumpEditor(tester, browser);

    expect(find.textContaining('too large to open here'), findsOneWidget);
    // No field at all: a truncated edit saved back would destroy the rest.
    expect(find.byType(TextField), findsNothing);
    expect(_canSave(tester), isFalse);
  });

  testWidgets('refuses a binary file', (tester) async {
    final browser = FakeFileBrowser()
      ..failReadWith = const FileBrowserException(
        'This looks like a binary file.',
        fault: FileBrowserFault.notText,
      );
    await _pumpEditor(tester, browser);

    expect(find.text('This looks like a binary file.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('closes the pane instead of popping when embedded',
      (tester) async {
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: FileEditorPage(
        browser: FakeFileBrowser(),
        path: '/home/me/notes.txt',
        onClose: () => closed = true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });

  testWidgets('still guards unsaved work when embedded', (tester) async {
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: FileEditorPage(
        browser: FakeFileBrowser(),
        path: '/home/me/notes.txt',
        onClose: () => closed = true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'half typed');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // Closing a pane is as final as leaving a screen: the edits are gone
    // either way, so the question is the same.
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(closed, isFalse);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });
}
