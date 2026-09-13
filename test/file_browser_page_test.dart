import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';
import 'package:sshbox/src/ui/terminal_link.dart';
import 'package:toastification/toastification.dart';

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

/// A row of the tree — inside the list, so a filter box holding the same
/// text is not mistaken for one.
Finder _row(String name) =>
    find.descendant(of: find.byType(ListView), matching: find.text(name));

/// Long-presses [name]'s row, the phone's right click, and picks [action]
/// from the menu that opens.
Future<void> _rowAction(WidgetTester tester, String name, String action) async {
  await tester.longPress(_row(name));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

/// Picks [path] from the menu behind the root's name.
Future<void> _climbTo(WidgetTester tester, String path) async {
  await tester.tap(find.byTooltip('Change root'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(path));
  await tester.pumpAndSettle();
}

/// Holds [folder]'s listing back while [held] is set, the way SFTP takes its
/// time over a folder left open.
class _SlowFolderBrowser extends FakeFileBrowser {
  _SlowFolderBrowser(this.folder);

  final String folder;
  Completer<void>? held;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (path == folder) await held?.future;
    return super.list(path);
  }
}

void main() {
  testWidgets('lists a directory with folders before files', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    expect(_row('dev'), findsOneWidget);
    expect(_row('notes.txt'), findsOneWidget);

    // The interface promises this ordering so every transport agrees on it.
    expect(
      tester.getTopLeft(_row('dev')).dy,
      lessThan(tester.getTopLeft(_row('notes.txt')).dy),
    );
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
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    // Nested one level in: indented, with a guide line down from its folder.
    expect(
      tester.getTopLeft(_row('main.dart')).dx,
      greaterThan(tester.getTopLeft(_row('notes.txt')).dx),
    );
    expect(find.byType(VerticalDivider), findsOneWidget);
    // Each file carries its type's icon, the way VS Code's theme marks it.
    expect(find.byIcon(Icons.flutter_dash), findsOneWidget);
    expect(find.byIcon(Icons.notes), findsOneWidget);

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

  testWidgets("the root's name lists the folders to climb back out to",
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);
    await _rowAction(tester, 'dev', 'Set as root');
    expect(find.text('DEV'), findsOneWidget);

    await _climbTo(tester, '/home/me');

    expect(find.text('ME'), findsOneWidget);
    expect(_row('notes.txt'), findsOneWidget);
  });

  testWidgets('a right click opens the same menu as a long press',
      (tester) async {
    await _pumpBrowser(tester, FakeFileBrowser());

    await tester.tap(_row('dev'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Set as root'), findsOneWidget);
    // A right click is not a tap: the folder stays shut.
    expect(_row('main.dart'), findsNothing);
  });

  testWidgets("the root's header makes things in the root", (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'src');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(browser.madeDirectories, ['/home/me/src']);
  });

  testWidgets('collapse all folds every open folder', (tester) async {
    await _pumpBrowser(tester, FakeFileBrowser());
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();
    expect(_row('main.dart'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse all'));
    await tester.pumpAndSettle();

    expect(_row('main.dart'), findsNothing);
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

  testWidgets('comes back scrolled where it was once the tree has loaded, '
      'and a new root starts at the top', (tester) async {
    final browser = _SlowFolderBrowser('/home/me/dev');
    for (var i = 0; i < 60; i++) {
      await browser.writeText('/home/me/dev/file$i.txt', '');
    }
    var offset = 0.0;
    // What the drawer does on every open: a new page, handed what the last
    // one reported.
    Future<void> openDrawer() => tester.pumpWidget(MaterialApp(
          home: FileBrowserPage(
            key: UniqueKey(),
            browser: browser,
            title: 'box',
            ownsBrowser: false,
            initialExpanded: const {'/home/me/dev'},
            initialScrollOffset: offset,
            onScrollChanged: (value) => offset = value,
          ),
        ));
    double scrolledTo() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

    await openDrawer();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final left = offset;
    expect(left, greaterThan(0));

    // Only the root's three rows are in while dev's listing is on its way,
    // far too few to scroll anywhere: jumped to now, the offset would be lost.
    browser.held = Completer();
    await openDrawer();
    await tester.pump();
    await tester.pump();
    expect(scrolledTo(), 0);

    browser.held!.complete();
    await tester.pumpAndSettle();
    expect(scrolledTo(), left);

    await _climbTo(tester, '/home');
    expect(offset, 0, reason: 'the next visit opens the new root at its top');
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
    // Not settled, which would wait out the toast: its overlay, the toast,
    // and its slide in.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.descendant(
        of: find.byType(BuiltInToastBuilder),
        matching: find.text('Could not list /home/me/dev: permission denied.'),
      ),
      findsOneWidget,
    );
    // The rest of the tree was fine, so it stays rather than turning into the
    // whole-page error.
    expect(_row('notes.txt'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('creates inside the folder whose menu it came from',
      (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await _rowAction(tester, 'dev', 'New folder…');
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
    // Not settled, which would wait out the toast: its overlay, the toast,
    // and its slide in.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Still in the same directory: nothing traversed, no editor opened onto a
    // file that is not there.
    expect(_row('notes.txt'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BuiltInToastBuilder),
        matching: find.text('dangling is a link that points nowhere.'),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
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

    await _rowAction(tester, 'notes.txt', 'Delete');

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

    await _rowAction(tester, 'dev', 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(browser.recursiveDeletes, ['/home/me/dev']);
  });

  testWidgets('renaming keeps the file in its own directory', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await _rowAction(tester, 'notes.txt', 'Rename…');

    await tester.enterText(find.byType(TextFormField), 'renamed.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(browser.renames, [('/home/me/notes.txt', '/home/me/renamed.txt')]);
  });

  testWidgets('a name with a slash in it is refused', (tester) async {
    final browser = FakeFileBrowser();
    await _pumpBrowser(tester, browser);

    await _rowAction(tester, 'notes.txt', 'Rename…');

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

  testWidgets('hands a search result over with the line it was found on',
      (tester) async {
    (String, int?)? handed;
    await tester.pumpWidget(MaterialApp(
      home: FileBrowserPage(
        browser: SearchingFakeFileBrowser(),
        title: 'box',
        ownsBrowser: false,
        onClose: () {},
        onFileSelected: (path, {line}) => handed = (path, line),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Filter by name'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search file contents'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Text to find'),
      'second',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('notes.txt:2'));
    await tester.pumpAndSettle();

    expect(handed, ('/home/me/notes.txt', 2));
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
        onFileSelected: (path, {line}) => handed = path,
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

    await _climbTo(tester, '/home/me');
    link.follow = true;
    await _rowAction(tester, 'dev', 'Set as root');

    expect(visited, ['/home/me/dev']);
  });

  testWidgets('following, every folder tapped takes the shell there',
      (tester) async {
    final visited = <String>[];
    final link = TerminalLink(typePath: (_) {}, changeDirectory: visited.add);
    // Built afresh each time, the way the drawer is on every open.
    Future<void> openDrawer() async {
      await tester.pumpWidget(MaterialApp(
        home: FileBrowserPage(
          key: UniqueKey(),
          browser: FakeFileBrowser(),
          title: 'box',
          terminal: link,
          onFileSelected: (_, {line}) {},
        ),
      ));
      await tester.pumpAndSettle();
    }

    await openDrawer();
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();
    expect(visited, isEmpty, reason: 'off, a tap only opens the folder');

    link.follow = true;
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();
    expect(visited, ['/home/me/dev'], reason: 'shutting it counts too');

    // Opened again, it asks again: whether the shell is already there is for
    // the terminal to find out, not the tree to guess.
    await tester.tap(_row('dev'));
    await tester.pumpAndSettle();
    await tester.tap(_row('main.dart'));
    await tester.pumpAndSettle();
    expect(
      visited,
      ['/home/me/dev', '/home/me/dev'],
      reason: 'and a file is no place to cd',
    );

    // Loading the root again is not the user going there, and following it
    // would pull the shell back out of dev.
    await openDrawer();
    expect(visited, hasLength(2));
  });

  testWidgets('opens a folder in the terminal from its menu, then gets out '
      'of the way', (tester) async {
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

    // One way in, from the folder's own menu: the header does not repeat it.
    expect(find.byTooltip('Open in terminal'), findsNothing);
    await _rowAction(tester, 'dev', 'Open in terminal');

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
