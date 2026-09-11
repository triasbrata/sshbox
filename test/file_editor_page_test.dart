import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

    // The save moved the file on; the next one must start from there rather
    // than mistaking its own earlier save for somebody else's.
    await tester.enterText(find.byType(TextField), 'again\n');
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

    await tester.enterText(find.byType(TextField), 'mine\n');
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

    await tester.enterText(find.byType(TextField), 'mine\n');
    await tester.pumpAndSettle();
    browser.externalEdit('/home/me/notes.txt', 'theirs\n');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'theirs\n',
    );
    expect(_canSave(tester), isFalse);
  });

  testWidgets('reloading asks before dropping an edit', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpEditor(tester, browser);
    String text() =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    await tester.enterText(find.byType(TextField), 'half typed');
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
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

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
      await tester.enterText(find.byType(TextField), 'root edit\n');
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

      await tester.enterText(find.byType(TextField), 'edited\n');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
      await tester.pumpAndSettle();
      expect(browser.contents['/home/me/notes.txt'], 'first line\nsecond line\n');

      await tester.tap(find.text('Save with sudo'));
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
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    await tester.pumpWidget(editor());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft\n');
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
