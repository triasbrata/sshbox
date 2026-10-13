import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';

import 'fake_file_browser.dart';

/// The editor's keys on a desktop, where re_editor binds its own shortcuts.
///
/// re_editor reads the platform once per isolate, the first time it looks, so
/// these run in files of their own, every test on the one [platform]: in
/// file_editor_page_test.dart it is fixed at Android and takes the phone's
/// path whatever a test's variant says.
void desktopKeyTests(TargetPlatform platform) {
  final variant = TargetPlatformVariant.only(platform);
  final mac = platform == TargetPlatform.macOS;
  final command = mac
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  final other = mac
      ? LogicalKeyboardKey.controlLeft
      : LogicalKeyboardKey.metaLeft;

  late List<LogicalKeyboardKey> behind;

  Future<CountingBrowser> pump(
    WidgetTester tester, {
    String path = '/home/me/notes.txt',
    String? text,
  }) async {
    behind = [];
    final browser = CountingBrowser();
    if (text != null) browser.contents[path] = text;
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) behind.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: FileEditorPage(browser: browser, path: path),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return browser;
  }

  CodeLineEditingController editor(WidgetTester tester) => tester
      .widget<CodeEditor>(find.byType(CodeEditor, skipOffstage: false))
      .controller!;

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key,
    LogicalKeyboardKey holding,
  ) async {
    await tester.sendKeyDownEvent(holding);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(holding);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('the command key saves from the text, which re_editor holds, '
      'and the other key does not', (tester) async {
    final browser = await pump(tester);
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    editor(tester).text = 'edited\n';
    await tester.pumpAndSettle();

    await chord(tester, LogicalKeyboardKey.keyS, other);
    expect(browser.writes, 0);
    expect(editor(tester).text, 'edited\n');
    behind.clear();

    await chord(tester, LogicalKeyboardKey.keyS, command);
    expect(browser.writes, 1);
    expect(browser.contents['/home/me/notes.txt'], 'edited\n');
    expect(editor(tester).text, 'edited\n');
    expect(behind, isNot(contains(LogicalKeyboardKey.keyS)));
  }, variant: variant);

  testWidgets('with nothing to save the command key in the text writes '
      'nothing', (tester) async {
    final browser = await pump(tester);
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();

    await chord(tester, LogicalKeyboardKey.keyS, command);
    expect(browser.writes, 0);
    expect(editor(tester).text, 'first line\nsecond line\n');
  }, variant: variant);

  testWidgets('Source gives the text the keys and its text input', (
    tester,
  ) async {
    const readme = '/home/me/README.md';
    await pump(tester, path: readme, text: '# Title\n');
    expect(tester.testTextInput.hasAnyClients, isFalse);

    await tester.tap(find.bySemanticsLabel('source'));
    await tester.pumpAndSettle();
    // A desktop has no soft keyboard to keep down: without the text input
    // open, keys reach the page and type nothing.
    expect(tester.testTextInput.hasAnyClients, isTrue);
  }, variant: variant);

  if (!mac) {
    testWidgets('Super with a letter types nothing and goes no further', (
      tester,
    ) async {
      final browser = await pump(tester);
      await tester.tap(find.byType(CodeEditor));
      await tester.pumpAndSettle();
      // Taken by the page, so the text input never hears it; a plain key
      // still goes on.
      await chord(tester, LogicalKeyboardKey.keyS, LogicalKeyboardKey.metaLeft);
      // X11 sends Super as its own key, not counted as meta, which the test
      // keyboard cannot simulate: held straight in the keyboard's state.
      final keys = HardwareKeyboard.instance;
      keys.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.metaLeft,
          logicalKey: LogicalKeyboardKey.superKey,
          timeStamp: Duration.zero,
        ),
      );
      expect(keys.isMetaPressed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      keys.handleKeyEvent(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.metaLeft,
          logicalKey: LogicalKeyboardKey.superKey,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      expect(behind, isNot(contains(LogicalKeyboardKey.keyS)));
      expect(behind, contains(LogicalKeyboardKey.f5));
      expect(browser.writes, 0);
    }, variant: variant);
  }
}

/// A browser that counts what was written to it.
class CountingBrowser extends FakeFileBrowser {
  int writes = 0;

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) {
    writes++;
    return super.writeText(path, content, expected: expected);
  }
}
