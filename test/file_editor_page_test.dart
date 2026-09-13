import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/toast.dart';

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

CodeLineEditingController _editor(WidgetTester tester) =>
    tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

void main() {
  // The editor reads its text size and wrap setting when it opens.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows what the file holds', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    expect(
      _editor(tester).text,
      'first line\nsecond line\n',
    );
    // Undo stops at the file as it came, not at the empty page before it.
    expect(_editor(tester).canUndo, isFalse);
  });

  testWidgets('keeps a CRLF file CRLF', (tester) async {
    final browser = FakeFileBrowser()
      ..contents['/home/me/notes.txt'] = 'one\r\ntwo\r\n';
    await _pumpEditor(tester, browser);

    // Its line endings alone are not an edit.
    expect(_canSave(tester), isFalse);

    _editor(tester).text = 'one\ntwo\nthree\n';
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(browser.contents['/home/me/notes.txt'], 'one\r\ntwo\r\nthree\r\n');
    expect(_canSave(tester), isFalse);
  });

  testWidgets('remembers word wrap and text size', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);
    CodeEditor editor() => tester.widget<CodeEditor>(find.byType(CodeEditor));
    Future<void> pick(String item) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    expect(editor().wordWrap, isTrue);
    expect(editor().style!.fontSize, 13);

    await pick('Word wrap');
    await pick('Larger text');
    expect(editor().wordWrap, isFalse);
    expect(editor().style!.fontSize, 14);

    // Opened again, it comes back the way it was left.
    await tester.pumpWidget(const SizedBox());
    await _pumpEditor(tester, browser);
    expect(editor().wordWrap, isFalse);
    expect(editor().style!.fontSize, 14);
  });

  testWidgets('cannot save until something changed', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    expect(_canSave(tester), isFalse);

    _editor(tester).text = 'edited\n';
    await tester.pumpAndSettle();
    expect(_canSave(tester), isTrue);

    // Typed back to what it was: there is nothing to send, so the button goes
    // quiet again rather than offering a write that changes nothing.
    _editor(tester).text = 'first line\nsecond line\n';
    await tester.pumpAndSettle();
    expect(_canSave(tester), isFalse);
  });

  testWidgets('saving writes through and settles', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    _editor(tester).text = 'rewritten\n';
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    // Not settled, which would wait out the toast: its overlay, the toast,
    // and its slide in.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(browser.contents['/home/me/notes.txt'], 'rewritten\n');
    expect(
      find.descendant(
        of: find.byType(ToastCard),
        matching: find.text('Saved notes.txt'),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(_canSave(tester), isFalse);

    // The save moved the file on; the next one must start from there rather
    // than mistaking its own earlier save for somebody else's.
    _editor(tester).text = 'again\n';
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    expect(browser.contents['/home/me/notes.txt'], 'again\n');
    expect(find.text('Changed on the host'), findsNothing);
  });

  testWidgets('will not save over a version someone else saved',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    _editor(tester).text = 'mine\n';
    await tester.pumpAndSettle();
    browser.externalEdit('/home/me/notes.txt', 'theirs\n');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Changed on the host'), findsOneWidget);
    expect(browser.contents['/home/me/notes.txt'], 'theirs\n');

    await tester.tap(find.text('Overwrite'));
    await tester.pumpAndSettle();
    expect(browser.contents['/home/me/notes.txt'], 'mine\n');
    expect(_canSave(tester), isFalse);
  });

  testWidgets('a conflict can take the host version instead', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    _editor(tester).text = 'mine\n';
    await tester.pumpAndSettle();
    browser.externalEdit('/home/me/notes.txt', 'theirs\n');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();

    expect(
      _editor(tester).text,
      'theirs\n',
    );
    expect(_canSave(tester), isFalse);
  });

  testWidgets('reloading asks before dropping an edit', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);
    String text() =>
        _editor(tester).text;

    _editor(tester).text = 'half typed';
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(text(), 'half typed');

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(text(), 'first line\nsecond line\n');
  });

  group('find', () {
    // re_editor searches in an isolate, whose answer only comes back in real
    // time rather than on the test's fake clock.
    Future<void> untilShown(WidgetTester tester, String text) async {
      for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('finds, steps between matches and replaces them all',
        (tester) async {
      await _pumpEditor(tester, FakeFileBrowser());

      await tester.tap(find.byTooltip('Find'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Find'), 'line');
      await untilShown(tester, '1/2');
      expect(find.text('1/2'), findsOneWidget);

      await tester.tap(find.byTooltip('Next match'));
      await untilShown(tester, '2/2');
      expect(find.text('2/2'), findsOneWidget);
      expect(_editor(tester).selection.extentIndex, 1);

      await tester.tap(find.byTooltip('Replace…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Replace with'),
        'row',
      );
      await tester.tap(find.text('Replace all'));
      await tester.pumpAndSettle();
      expect(_editor(tester).text, 'first row\nsecond row\n');
    });

    testWidgets('says so when there is nothing to find', (tester) async {
      await _pumpEditor(tester, FakeFileBrowser());

      await tester.tap(find.byTooltip('Find'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Find'), 'nope');
      await untilShown(tester, 'No results');
      expect(find.text('No results'), findsOneWidget);

      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Find'), findsNothing);
    });
  });

  testWidgets('goes to a line', (tester) async {
    await _pumpEditor(tester, FakeFileBrowser());

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to line…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '2',
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(_editor(tester).selection.extentIndex, 1);
  });

  testWidgets('opens at the line asked for, and moves when asked again',
      (tester) async {
    final browser = FakeFileBrowser();
    Widget editor(int line) => MaterialApp(
          home: FileEditorPage(
            browser: browser,
            path: '/home/me/notes.txt',
            line: line,
          ),
        );

    await tester.pumpWidget(editor(2));
    await tester.pumpAndSettle();
    expect(_editor(tester).selection.extentIndex, 1);

    await tester.pumpWidget(editor(1));
    await tester.pumpAndSettle();
    expect(_editor(tester).selection.extentIndex, 0);
  });

  group('hardware keyboard', () {
    // The test's platform is Android, where re_editor binds no keys of its
    // own beyond Backspace and Enter: exactly the tablet's case.
    Future<CodeLineEditingController> focused(
      WidgetTester tester, [
      FakeFileBrowser? browser,
    ]) async {
      await _pumpEditor(tester, browser ?? FakeFileBrowser());
      await tester.tap(find.byType(CodeEditor));
      // Past the double-tap window the tap opened, so no timer outlives it.
      await tester.pump(const Duration(seconds: 1));
      final editor = _editor(tester)
        ..selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      await tester.pump();
      return editor;
    }

    (int, int) caret(CodeLineEditingController editor) =>
        (editor.selection.extentIndex, editor.selection.extentOffset);

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      LogicalKeyboardKey? holding,
    }) async {
      if (holding != null) await tester.sendKeyDownEvent(holding);
      await tester.sendKeyEvent(key);
      if (holding != null) await tester.sendKeyUpEvent(holding);
      // A frame first, for a toast the key raised: the package takes it in on
      // the frame after, and a second's jump before that would run out its
      // countdown with nothing on screen to close, leaving it up for good.
      await tester.pump();
      // A moved caret restarts its blink on a timer; let it run out.
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('arrows, Home and End move the cursor', (tester) async {
      final editor = await focused(tester);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(caret(editor), (0, 1));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(caret(editor).$1, 1);
      await press(tester, LogicalKeyboardKey.end);
      expect(caret(editor), (1, 'second line'.length));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(caret(editor), (1, 'second line'.length - 1));
      await press(tester, LogicalKeyboardKey.home);
      expect(caret(editor), (1, 0));
      await press(tester, LogicalKeyboardKey.arrowUp);
      // Still the editor's keys: focus did not wander off to another widget.
      expect(caret(editor).$1, 0);
    });

    testWidgets('Shift selects, and Ctrl goes by word', (tester) async {
      final editor = await focused(tester);

      await press(
        tester,
        LogicalKeyboardKey.arrowRight,
        holding: LogicalKeyboardKey.controlLeft,
      );
      expect(caret(editor), (0, 'first'.length));

      await press(
        tester,
        LogicalKeyboardKey.end,
        holding: LogicalKeyboardKey.shiftLeft,
      );
      expect(editor.selectedText, ' line');
    });

    testWidgets('Ctrl+Z undoes and Ctrl+S saves', (tester) async {
      final browser = FakeFileBrowser();
      final editor = await focused(tester, browser);

      editor.text = 'edited\n';
      await tester.pumpAndSettle();
      await press(
        tester,
        LogicalKeyboardKey.keyS,
        holding: LogicalKeyboardKey.controlLeft,
      );
      await tester.pumpAndSettle();
      expect(browser.contents['/home/me/notes.txt'], 'edited\n');

      await press(
        tester,
        LogicalKeyboardKey.keyZ,
        holding: LogicalKeyboardKey.controlLeft,
      );
      expect(editor.text, 'first line\nsecond line\n');
    });
  });

  group('key bar', () {
    // Wide enough for every key at once, so none has to be scrolled to.
    setUp(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views
          .single;
      view.physicalSize = const Size(3200, 800);
      view.devicePixelRatio = 1;
    });
    tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.views
        .single
        .reset());

    Future<void> press(WidgetTester tester, String key) async {
      await tester.tap(find.text(key));
      await tester.pumpAndSettle();
    }

    (int, int) caret(WidgetTester tester) => (
          _editor(tester).selection.extentIndex,
          _editor(tester).selection.extentOffset,
        );

    testWidgets('moves the cursor and types where it is', (tester) async {
      await _pumpEditor(tester, FakeFileBrowser());
      final editor = _editor(tester);
      bool canUndo() => tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
              .onPressed !=
          null;
      expect(canUndo(), isFalse);

      editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      await tester.pumpAndSettle();

      await press(tester, '→');
      expect(caret(tester), (0, 1));
      await press(tester, '↓');
      expect(caret(tester).$1, 1);
      await press(tester, 'END');
      expect(caret(tester), (1, 'second line'.length));

      await press(tester, '{');
      await press(tester, 'TAB');
      expect(editor.text, 'first line\nsecond line{  \n');
      expect(canUndo(), isTrue);

      final typed = editor.text;
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(editor.text, isNot(typed));
      await tester.tap(find.byTooltip('Redo'));
      await tester.pumpAndSettle();
      expect(editor.text, typed);
    });

    testWidgets('Tab types a real tab in a Makefile', (tester) async {
      final browser = FakeFileBrowser()..contents['/srv/Makefile'] = 'all:\n';
      await _pumpEditor(tester, browser, path: '/srv/Makefile');
      _editor(tester).selection =
          const CodeLineSelection.collapsed(index: 1, offset: 0);
      await tester.pumpAndSettle();

      await press(tester, 'TAB');
      expect(_editor(tester).text, 'all:\n\t');
    });

    testWidgets('is not there without a file to act on', (tester) async {
      final browser = FakeFileBrowser()
        ..failReadWith = const FileBrowserException(
          'This looks like a binary file.',
          fault: FileBrowserFault.notText,
        );
      await _pumpEditor(tester, browser);
      expect(find.byType(EditorKeyBar), findsNothing);
    });
  });

  group('sudo', () {
    const denied = FileBrowserException(
      'Could not open: permission denied.',
      fault: FileBrowserFault.permissionDenied,
    );
    final passwordField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    String text(WidgetTester tester) =>
        _editor(tester).text;

    // The page's spinner keeps turning behind the password dialog, so nothing
    // settles while it is up: pump just long enough for it to open.
    Future<void> untilPrompted(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('opens a file the login may not read', (tester) async {
      final browser = SudoFakeFileBrowser()..failReadWith = denied;
      await _pumpEditor(tester, browser);

      await tester.tap(find.text('Open with sudo'));
      await untilPrompted(tester);
      expect(find.text('sudo password'), findsOneWidget);
      await tester.enterText(passwordField, 'hunter2');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(text(tester), 'first line\nsecond line\n');
      expect(find.textContaining('as root'), findsOneWidget);

      // The save goes the same way, on the password already given.
      _editor(tester).text = 'root edit\n';
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
      await tester.pumpAndSettle();
      expect(browser.contents['/home/me/notes.txt'], 'root edit\n');
      expect(browser.sudoWrites, ['/home/me/notes.txt']);
      // Tried without one first, for a sudo that might not have asked.
      expect(browser.passwordsTried, [null, 'hunter2', 'hunter2']);
    });

    testWidgets('asks for no password where sudo does not', (tester) async {
      final browser = SudoFakeFileBrowser()
        ..failReadWith = denied
        ..sudoPassword = null;
      await _pumpEditor(tester, browser);

      await tester.tap(find.text('Open with sudo'));
      await tester.pumpAndSettle();

      expect(find.text('sudo password'), findsNothing);
      expect(text(tester), 'first line\nsecond line\n');
    });

    testWidgets('a wrong password is turned down and asked for again',
        (tester) async {
      final browser = SudoFakeFileBrowser()..failReadWith = denied;
      await _pumpEditor(tester, browser);

      await tester.tap(find.text('Open with sudo'));
      await untilPrompted(tester);
      await tester.enterText(passwordField, 'wrong');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('sudo did not accept that password.'), findsOneWidget);

      await tester.tap(find.text('Open with sudo'));
      await untilPrompted(tester);
      await tester.enterText(passwordField, 'hunter2');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(text(tester), 'first line\nsecond line\n');
    });

    testWidgets('a save the login is refused can go through sudo',
        (tester) async {
      final browser = SudoFakeFileBrowser()
        ..failWriteWith = const FileBrowserException(
          'Could not save: permission denied.',
          fault: FileBrowserFault.permissionDenied,
        );
      await _pumpEditor(tester, browser);

      _editor(tester).text = 'edited\n';
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
      // Not settled, which would wait out the toast the offer is on.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(browser.contents['/home/me/notes.txt'], 'first line\nsecond line\n');

      await tester.tap(
        find.descendant(
          of: find.byType(ToastCard),
          matching: find.text('Save with sudo'),
        ),
      );
      await untilPrompted(tester);
      await tester.enterText(passwordField, 'hunter2');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(browser.contents['/home/me/notes.txt'], 'edited\n');
      expect(_canSave(tester), isFalse);
      expect(find.textContaining('as root'), findsOneWidget);
    });

    testWidgets('offers nothing where the transport has no sudo',
        (tester) async {
      final browser = FakeFileBrowser()..failReadWith = denied;
      await _pumpEditor(tester, browser);

      expect(find.text('Could not open: permission denied.'), findsOneWidget);
      expect(find.text('Open with sudo'), findsNothing);
    });
  });

  testWidgets('offers back an edit the app never got to save',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final browser = FakeFileBrowser();
    Widget editor() => MaterialApp(
          home: FileEditorPage(
            browser: browser,
            path: '/home/me/notes.txt',
            draftKey: 'box:/home/me/notes.txt',
          ),
        );
    String text() =>
        _editor(tester).text;

    await tester.pumpWidget(editor());
    await tester.pumpAndSettle();
    _editor(tester).text = 'draft\n';
    await tester.pump(const Duration(seconds: 3));

    // The app goes away with the edit unsaved, and comes back to the file.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(editor());
    await tester.pumpAndSettle();

    const banner = 'There are unsaved edits to this file from last time.';
    expect(find.text(banner), findsOneWidget);
    expect(text(), 'first line\nsecond line\n');

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text(banner), findsNothing);
    expect(text(), 'draft\n');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    expect(browser.contents['/home/me/notes.txt'], 'draft\n');

    // Saved, so there is nothing left to offer next time.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(editor());
    await tester.pumpAndSettle();
    expect(find.text(banner), findsNothing);
  });

  testWidgets('guards an unsaved edit against a stray back', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);

    _editor(tester).text = 'half typed';
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // There is no undo on the far end, so leaving has to be deliberate.
    expect(find.text('Discard changes?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(CodeEditor), findsOneWidget);
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
    expect(find.byType(CodeEditor), findsNothing);
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
    expect(find.byType(CodeEditor), findsNothing);
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

    _editor(tester).text = 'half typed';
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
