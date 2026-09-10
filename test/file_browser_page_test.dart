import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';
import 'package:sshbox/src/ui/terminal_link.dart';

import 'fake_file_browser.dart';

/// The pages, driven by a filesystem that is not SFTP.
///
/// That is the claim `FileBrowser` exists to make, so proving it here is not
/// incidental: a second implementation already exists, the UI cannot tell the
/// difference, and none of this needs a server to run.
Future<void> _pumpBrowser(WidgetTester tester, FakeFileBrowser browser) async {
  await tester.pumpWidget(
    MaterialApp(home: FileBrowserPage(browser: browser, title: 'box')),
  );
  await tester.pumpAndSettle();
}

Finder _row(String name) => find.widgetWithText(ListTile, name);

/// Opens [name]'s row menu and picks [action] from it.
Future<void> _rowAction(WidgetTester tester, String name, String action) async {
  await tester.tap(find.descendant(
    of: _row(name),
    matching: find.byTooltip('Actions'),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists a directory with folders before files', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    expect(_row('dev'), findsOneWidget);
    expect(_row('notes.txt'), findsOneWidget);

    // The interface promises this ordering so every transport agrees on it.
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    final names = [for (final tile in tiles) (tile.title! as Text).data];
    expect(names.indexOf('dev'), lessThan(names.indexOf('notes.txt')));
  });

  testWidgets('hides dotfiles until asked for them', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    expect(_row('.bashrc'), findsNothing);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show dotfiles'));
    await tester.pumpAndSettle();

    expect(_row('.bashrc'), findsOneWidget);
  });

  testWidgets('opens a folder in place and closes it again', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();

    // A tree, not a listing: the folder's contents join the rows around it
    // rather than replacing them.
    expect(_row('main.dart'), findsOneWidget);
    expect(_row('notes.txt'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget);

    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();

    expect(_row('main.dart'), findsNothing);
  });

  testWidgets('set as root hangs the tree from a folder, and back undoes it',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await _rowAction(tester, 'dev', 'Set as root');

    expect(_row('main.dart'), findsOneWidget);
    expect(_row('notes.txt'), findsNothing);

    // Back retraces the re-rooting rather than climbing, which is what makes
    // the way out match the way in.
    final page = tester.state<NavigatorState>(find.byType(Navigator));
    await page.maybePop();
    await tester.pumpAndSettle();

    expect(_row('notes.txt'), findsOneWidget);
    expect(_row('main.dart'), findsNothing);
  });

  testWidgets('a crumb above the root climbs back out', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);
    await _rowAction(tester, 'dev', 'Set as root');

    await tester.tap(find.text('me'));
    await tester.pumpAndSettle();

    expect(_row('notes.txt'), findsOneWidget);
  });

  testWidgets('starts at the root it is given, taking ~ from home',
      (tester) async {
    // A host's saved root is typed by hand, and `~/dev` is how people type it
    // — SFTP would take that as a folder literally named `~`.
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: FakeFileBrowser(),
        title: 'box',
        initialRoot: '~/dev',
      ),
    ));
    await tester.pumpAndSettle();

    expect(_row('main.dart'), findsOneWidget);
    expect(_row('notes.txt'), findsNothing);
  });

  testWidgets('keeps folders open across a rebuild', (tester) async {
    Set<String>? reported;
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: FakeFileBrowser(),
        title: 'box',
        onExpandedChanged: (expanded) => reported = expanded,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();
    expect(reported, {'/home/me/dev'});

    // What a drawer does every time it is closed and opened again.
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        key: UniqueKey(),
        browser: FakeFileBrowser(),
        title: 'box',
        initialExpanded: reported!,
      ),
    ));
    await tester.pumpAndSettle();

    expect(_row('main.dart'), findsOneWidget);
  });

  testWidgets('a folder that cannot be listed closes and says why',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    browser.failListWith = const FileBrowserException(
      'Could not list /home/me/dev: permission denied.',
      fault: FileBrowserFault.permissionDenied,
    );
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not list /home/me/dev: permission denied.'),
      findsOneWidget,
    );
    // The rest of the tree was fine, so it stays rather than turning into the
    // whole-page error.
    expect(_row('notes.txt'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('creates inside the folder whose menu it came from',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await _rowAction(tester, 'dev', 'New folder here');
    await tester.enterText(find.byType(TextFormField), 'lib');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(browser.madeDirectories, ['/home/me/dev/lib']);
    // Opened on the way, so what was just made is in sight.
    expect(_row('lib'), findsOneWidget);
  });

  testWidgets('a broken symlink is not a folder to walk into', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(_row('dangling'));
    await tester.pumpAndSettle();

    // Still in the same directory: nothing traversed, no editor opened onto a
    // file that is not there.
    expect(_row('notes.txt'), findsOneWidget);
    expect(find.text('dangling is a link that points nowhere.'), findsOneWidget);
  });

  testWidgets('filters the listing by name', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not');
    await tester.pumpAndSettle();

    expect(_row('notes.txt'), findsOneWidget);
    expect(_row('dev'), findsNothing);
  });

  testWidgets('the filter keeps the folders a match is inside',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'main');
    await tester.pumpAndSettle();

    expect(_row('main.dart'), findsOneWidget);
    expect(_row('dev'), findsOneWidget, reason: 'the way down to the match');
    expect(_row('notes.txt'), findsNothing);
  });

  testWidgets('shows the adapter message when a listing fails', (tester) async {
    final browser = FakeFileBrowser()
      ..failListWith = const FileBrowserException(
        'Could not list /root: permission denied.',
        fault: FileBrowserFault.permissionDenied,
      );
    await _pumpBrowser(tester, browser);

    // Verbatim: normalising errors in the adapter is only worth anything if
    // the page shows what it was handed instead of inventing its own wording.
    expect(
      find.text('Could not list /root: permission denied.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('deleting asks first, then goes through', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.descendant(
      of: _row('notes.txt'),
      matching: find.byTooltip('Actions'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete notes.txt?'), findsOneWidget);
    expect(browser.deleted, isEmpty, reason: 'not until it is confirmed');

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(browser.deleted, ['/home/me/notes.txt']);
    expect(_row('notes.txt'), findsNothing);
  });

  testWidgets('a folder is deleted recursively, a file is not', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.descendant(
      of: _row('dev'),
      matching: find.byTooltip('Actions'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(browser.recursiveDeletes, ['/home/me/dev']);
  });

  testWidgets('renaming keeps the file in its own directory', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.descendant(
      of: _row('notes.txt'),
      matching: find.byTooltip('Actions'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'renamed.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(browser.renames, [('/home/me/notes.txt', '/home/me/renamed.txt')]);
  });

  testWidgets('a name with a slash in it is refused', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.descendant(
      of: _row('notes.txt'),
      matching: find.byTooltip('Actions'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'sub/dir.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    // A slash here would quietly move the file somewhere else, which is never
    // what a rename box is understood to mean.
    expect(find.text('A name cannot contain "/"'), findsOneWidget);
    expect(browser.renames, isEmpty);
  });

  testWidgets('hides search when the transport cannot do it', (tester) async {
    // The plain fake is not FileSearchCapable, so the button must not appear.
    await _pumpBrowser(tester, FakeFileBrowser());
    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search file contents'), findsNothing);
  });

  testWidgets('offers search when the transport can do it', (tester) async {
    // Same page, same fake data, one extra interface implemented — this is the
    // probe that keeps the capability honest rather than decorative.
    await _pumpBrowser(tester, SearchingFakeFileBrowser());
    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search file contents'), findsOneWidget);
  });

  testWidgets('closes the browser it was handed', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);
    expect(browser.closed, isFalse);

    // Nothing else owns it, so a page that forgets this leaks an SFTP channel
    // per visit.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(browser.closed, isTrue);
  });

  testWidgets('hands a file over instead of navigating when embedded',
      (tester) async {
    final browser = FakeFileBrowser();
    String? handed;
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: browser,
        title: 'box',
        ownsBrowser: false,
        onClose: () {},
        onFileSelected: (path) => handed = path,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(_row('notes.txt'));
    await tester.pumpAndSettle();

    expect(handed, '/home/me/notes.txt');
    // On a tablet the editor belongs to the pane beside the terminal, so this
    // page must hand the path over rather than push a screen over everything.
    expect(find.byType(FileEditorPage), findsNothing);
  });

  testWidgets('leaves a browser it does not own open', (tester) async {
    final browser = FakeFileBrowser();
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(browser: browser, title: 'box', ownsBrowser: false),
    ));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    // A drawer is torn down every time it closes. Closing the SFTP channel
    // with it would turn every reopen into a reconnect.
    expect(browser.closed, isFalse);
  });

  testWidgets('offers close rather than back when it is not a route',
      (tester) async {
    final browser = FakeFileBrowser();
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: browser,
        title: 'box',
        ownsBrowser: false,
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();

    // Inside a drawer there is no route of our own; an implied back button
    // would pop the terminal underneath instead.
    expect(find.byTooltip('Close files'), findsOneWidget);
  });

  testWidgets('drops the name filter when the root changes', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dev');
    await tester.pumpAndSettle();
    expect(_row('dev'), findsOneWidget);

    await _rowAction(tester, 'dev', 'Set as root');

    // The filter was about the tree it was typed against. Kept, it would
    // hide everything in here and read as an empty folder.
    expect(_row('main.dart'), findsOneWidget);
  });

  testWidgets('takes the shell along only when told to', (tester) async {
    final visited = <String>[];
    final link = TerminalLink(
      typePath: (_) {},
      changeDirectory: visited.add,
    );

    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: FakeFileBrowser(),
        title: 'box',
        terminal: link,
      ),
    ));
    await tester.pumpAndSettle();

    await _rowAction(tester, 'dev', 'Set as root');
    // Off by default: moving the tree must not type into a live shell.
    expect(visited, isEmpty);

    await tester.tap(find.text('me'));
    await tester.pumpAndSettle();
    link.follow = true;
    await _rowAction(tester, 'dev', 'Set as root');

    expect(visited, ['/home/me/dev']);
  });

  testWidgets('opens the folder on screen in the terminal, then gets out of '
      'the way', (tester) async {
    final visited = <String>[];
    var closed = false;

    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: FakeFileBrowser(),
        title: 'box',
        onClose: () => closed = true,
        terminal: TerminalLink(typePath: (_) {}, changeDirectory: visited.add),
      ),
    ));
    await tester.pumpAndSettle();

    await _rowAction(tester, 'dev', 'Set as root');
    await tester.tap(find.byTooltip('Open in terminal'));
    await tester.pumpAndSettle();

    expect(visited, ['/home/me/dev']);
    expect(closed, isTrue, reason: 'the shell it just moved should be seen');
  });

  testWidgets('saving the root to the host config asks first', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: FakeFileBrowser(),
        title: 'box',
        onSaveRoot: (root) async => saved.add(root),
      ),
    ));
    await tester.pumpAndSettle();
    await _rowAction(tester, 'dev', 'Set as root');

    Future<void> pickSave() async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save root to host config'));
      await tester.pumpAndSettle();
    }

    // It changes where every later connection opens, so backing out of the
    // question has to leave the config alone.
    await pickSave();
    expect(find.text('Update SSH config?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);

    await pickSave();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(saved, ['/home/me/dev']);
  });

  testWidgets('offers no config to save to without a host behind it',
      (tester) async {
    await _pumpBrowser(tester, FakeFileBrowser());
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    expect(find.text('Save root to host config'), findsNothing);
  });
}
