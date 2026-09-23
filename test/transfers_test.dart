import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/transfers.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:sshbox/src/ui/transfers_page.dart';

import 'fake_file_browser.dart';
import 'fake_file_picker.dart';

const _download = TransferDirection.download;
const _upload = TransferDirection.upload;

/// A row of the files drawer's tree.
Finder _row(String name) =>
    find.descendant(of: find.byType(ListView), matching: find.text(name));

Future<void> _pumpBrowser(WidgetTester tester, FakeFileBrowser browser) async {
  await tester.pumpWidget(
    MaterialApp(home: FileBrowserPage(browser: browser, title: 'box')),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the transfer list', () {
    test('lists each newest first, and follows it to its end', () async {
      final list = Transfers();
      final gate = Completer<void>();
      final first = list.run(
        name: 'a.bin',
        host: 'box',
        direction: _download,
        work: (transfer) async {
          transfer.report(10, 100);
          await gate.future;
          transfer.report(100, 100);
          return 'ok';
        },
      );
      await list.run(
        name: 'b.bin',
        host: 'box',
        direction: _upload,
        work: (_) async {},
      );

      expect([for (final t in list.items) t.name], ['b.bin', 'a.bin']);
      final a = list.items.last;
      expect((a.state, a.done, a.total, a.fraction), (
        TransferState.running,
        10,
        100,
        0.1,
      ));
      expect(list.anyRunning, isTrue);

      gate.complete();
      expect(await first, 'ok');
      expect((a.state, a.done), (TransferState.done, 100));
      expect(list.anyRunning, isFalse);
    });

    test('tells its progress a few times a second, and each change of state '
        'at once', () async {
      final list = Transfers();
      var told = 0;
      list.addListener(() => told++);
      final gate = Completer<void>();
      final run = list.run(
        name: 'a',
        host: 'box',
        direction: _download,
        work: (transfer) async {
          for (var sent = 1; sent <= 1000; sent++) {
            transfer.report(sent, 1000);
          }
          await gate.future;
        },
      );

      // Started, then one of the thousand; the numbers are current anyway.
      expect(told, 2);
      expect(list.items.single.done, 1000);
      gate.complete();
      await run;
      expect(told, 3);
    });

    test('a failure says why; Cancel ends it cancelled, even when what it '
        'cut short fails', () async {
      final list = Transfers();
      await expectLater(
        list.run(
          name: 'a',
          host: 'box',
          direction: _download,
          work: (_) async => throw const FileBrowserException(
            'Could not download a: permission denied.',
          ),
        ),
        throwsA(isA<FileBrowserException>()),
      );
      final failed = list.items.single;
      expect(failed.state, TransferState.failed);
      expect(failed.error, 'Could not download a: permission denied.');

      final cut = expectLater(
        list.run(
          name: 'b',
          host: 'box',
          direction: _upload,
          work: (transfer) async {
            await transfer.cancelled;
            throw const FileBrowserException(
              'The connection to the host was lost.',
            );
          },
        ),
        throwsA(isA<FileBrowserException>()),
      );
      final b = list.items.first;
      list.cancel(b);
      expect(b.cancelling, isTrue);
      await cut;
      expect((b.state, b.error), (TransferState.cancelled, null));

      // Stopped by the work itself, as a dismissed save dialog is.
      await expectLater(
        list.run(
          name: 'c',
          host: 'box',
          direction: _download,
          work: (_) async => throw FileBrowserException.cancelled,
        ),
        throwsA(same(FileBrowserException.cancelled)),
      );
      expect(list.items.first.state, TransferState.cancelled);

      // One that has ended stays as it ended.
      list.cancel(failed);
      expect(failed.state, TransferState.failed);
    });

    test('Clear finished keeps what is still running', () async {
      final list = Transfers();
      await list.run(
        name: 'done',
        host: 'box',
        direction: _download,
        work: (_) async {},
      );
      final gate = Completer<void>();
      final running = list.run(
        name: 'running',
        host: 'box',
        direction: _upload,
        work: (_) => gate.future,
      );

      list.clearFinished();
      expect([for (final t in list.items) t.name], ['running']);
      gate.complete();
      await running;
    });

    test('each row says which way, where, how far and how it went', () async {
      final list = Transfers();
      final gate = Completer<void>();
      final run = list.run(
        name: 'big.aab',
        host: 'box',
        direction: _download,
        work: (transfer) async {
          transfer.report(1024 * 1024, 70 * 1024 * 1024);
          await gate.future;
          transfer.report(70 * 1024 * 1024, 70 * 1024 * 1024);
        },
      );
      final transfer = list.items.single;
      expect(
        status(transfer),
        startsWith('Downloading from box · 1.0 MB of 70.0 MB · '),
      );
      list.cancel(transfer);
      expect(status(transfer), 'Cancelling…');
      // All in by the time the cancel was looked at: what came of it counts.
      gate.complete();
      await run;
      expect(status(transfer), startsWith('Downloaded from box · 70.0 MB · '));

      await expectLater(
        list.run(
          name: 'up.txt',
          host: 'box',
          direction: _upload,
          work: (_) async => throw const FileBrowserException(
            'Could not upload up.txt: permission denied.',
          ),
        ),
        throwsA(anything),
      );
      expect(
        status(list.items.first),
        'Upload to box failed: Could not upload up.txt: permission denied.',
      );
      await expectLater(
        list.run(
          name: 'up.txt',
          host: '',
          direction: _upload,
          work: (_) async => throw FileBrowserException.cancelled,
        ),
        throwsA(anything),
      );
      expect(status(list.items.first), 'Upload cancelled');
    });
  });

  group('Cancel', () {
    setUp(transfers.clearFinished);

    testWidgets('stops a download, leaves no copy on the phone, and says '
        'nothing', (tester) async {
      final picker = useFakePicker();
      final browser = FakeFileBrowser()..hold = Completer<void>();
      await _pumpBrowser(tester, browser);

      await tester.longPress(_row('notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.pump();

      final transfer = transfers.items.first;
      expect((transfer.name, transfer.host, transfer.direction), (
        'notes.txt',
        'box',
        _download,
      ));
      expect(transfer.state, TransferState.running);
      expect(find.textContaining('Downloading notes.txt'), findsOneWidget);
      final copy = File(browser.downloads.single.to);
      expect(copy.existsSync(), isTrue);

      transfers.cancel(transfer);
      await tester.pumpAndSettle();

      expect(transfer.state, TransferState.cancelled);
      expect(picker.saved, isNull);
      expect(copy.parent.existsSync(), isFalse);
      expect(find.byType(TuiToastCard), findsNothing);
      expect(find.textContaining('Downloading'), findsNothing);
    });

    testWidgets('stops one upload of several, and the rest still go', (
      tester,
    ) async {
      useFakePicker().next = [_PhoneFile('photo.jpg'), _PhoneFile('song.mp3')];
      final hold = Completer<void>();
      final browser = FakeFileBrowser()..hold = hold;
      await _pumpBrowser(tester, browser);

      await tester.longPress(_row('dev'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Upload here…'));
      await tester.pump();
      await tester.pump();

      final photo = transfers.items.first;
      expect((photo.name, photo.host, photo.direction), (
        'photo.jpg',
        'box',
        _upload,
      ));
      expect(find.textContaining('Uploading photo.jpg (1 of 2)'), findsOneWidget);

      transfers.cancel(photo);
      await tester.pump();
      await tester.pump();
      final song = transfers.items.first;
      expect(song.name, 'song.mp3');
      hold.complete();
      await tester.pumpAndSettle();

      expect(photo.state, TransferState.cancelled);
      expect(song.state, TransferState.done);
      expect(browser.uploads, [
        (from: '/phone/song.mp3', to: '/home/me/dev/song.mp3', replace: false),
      ]);
    });
  });

  group('the Transfers tab', () {
    setUp(transfers.clearFinished);

    testWidgets('cancels a running one, opens a finished download, and '
        'clears what has ended', (tester) async {
      final picker = useFakePicker();
      final hold = Completer<void>();
      final running = expectLater(
        transfers.run(
          name: 'big.aab',
          host: 'box',
          direction: _download,
          work: (transfer) async {
            transfer.report(5, 10);
            await Future.any([hold.future, transfer.cancelled]);
            if (!hold.isCompleted) throw FileBrowserException.cancelled;
          },
        ),
        throwsA(same(FileBrowserException.cancelled)),
      );
      await transfers.run(
        name: 'notes.txt',
        host: 'box',
        direction: _download,
        work: (transfer) async =>
            transfer.saved = 'content://downloads/notes.txt',
      );
      await tester.pumpWidget(const MaterialApp(home: TransfersPage()));

      expect(find.text('big.aab'), findsOneWidget);
      expect(find.textContaining('Downloading from box'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      await running;
      expect(find.text('Download from box cancelled'), findsOneWidget);
      expect(find.byTooltip('Cancel'), findsNothing);

      await tester.tap(find.text('OPEN'));
      await tester.pump();
      expect(picker.opened, ['content://downloads/notes.txt']);

      await tester.tap(find.text('CLEAR FINISHED'));
      await tester.pump();
      expect(find.text('No transfers yet'), findsOneWidget);
    });

    test('joins the strip, shows, and closes onto its neighbour', () async {
      final manager = SessionManager();
      final shell = manager.open(
        const HostProfile(id: 'h', label: 'box', host: 'x', username: 'me'),
      );
      addTearDown(() => manager.close(shell.id));

      // A transfer starting: on the strip, the shell still in front.
      manager.showTransfers();
      expect((manager.transfersTab, manager.transfersActive), (true, false));
      expect(manager.activeId, shell.id);

      manager.showTransfers(select: true);
      expect((manager.transfersTab, manager.transfersActive), (true, true));
      expect(manager.activeId, isNull);

      // Another tab shown leaves it on the strip.
      manager.select(shell.id);
      expect((manager.transfersTab, manager.transfersActive), (true, false));

      manager
        ..showTransfers(select: true)
        ..closeTransfers();
      expect(manager.transfersTab, isFalse);
      expect(manager.activeId, shell.id);

      // With a database open, it is the neighbour.
      manager
        ..openDb(
          const DbConnection(
            id: 'db1',
            kind: DbKind.redis,
            hostId: 'h',
            port: 6379,
          ),
          'Redis on box',
        )
        ..showTransfers(select: true)
        ..closeTransfers();
      expect(manager.activeDb, manager.dbTabs.single);
    });

    testWidgets('comes to the strip with a new transfer without being shown, '
        'and closing it leaves the transfer running', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final sessions = SessionManager();
      await tester.pumpWidget(
        MaterialApp(
          home: TabsShell(
            repository: HostRepository(secrets),
            secrets: secrets,
            sessions: sessions,
            onOpenHost: (_) async {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Transfers'), findsNothing);

      final hold = Completer<void>();
      final running = transfers.run(
        name: 'big.aab',
        host: 'box',
        direction: _download,
        work: (transfer) async {
          transfer.report(5, 10);
          await hold.future;
        },
      );
      await tester.pump();
      expect(find.text('Transfers'), findsOneWidget);
      // Home is still what shows.
      expect(sessions.transfersActive, isFalse);
      expect(find.text('big.aab'), findsNothing);

      await tester.tap(find.text('Transfers'));
      await tester.pump();
      expect(sessions.transfersActive, isTrue);
      expect(find.text('big.aab'), findsOneWidget);

      await tester.tap(find.byTooltip('Close Transfers'));
      await tester.pump();
      expect(sessions.transfersTab, isFalse);
      expect(transfers.items.first.state, TransferState.running);

      hold.complete();
      await running;
      expect(transfers.items.first.state, TransferState.done);
    });

    testWidgets('Home opens it with nothing transferred, and a second tap '
        'goes back to the one tab', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final sessions = SessionManager();
      await tester.pumpWidget(
        MaterialApp(
          home: TabsShell(
            repository: HostRepository(secrets),
            secrets: secrets,
            sessions: sessions,
            onOpenHost: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(transfers.items, isEmpty);
      expect(sessions.transfersTab, isFalse);

      // Nothing has ever been transferred: the tab still opens, and says so.
      await tester.tap(find.byTooltip('Transfers'));
      await tester.pumpAndSettle();
      expect((sessions.transfersTab, sessions.transfersActive), (true, true));
      expect(find.text('No transfers yet'), findsOneWidget);
      expect(find.byTooltip('Close Transfers'), findsOneWidget);

      // Asked for again from Home: the same tab, not a second one.
      sessions.select(null);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transfers'));
      await tester.pumpAndSettle();
      expect(sessions.transfersActive, isTrue);
      expect(find.byTooltip('Close Transfers'), findsOneWidget);
    });

    testWidgets('sits on the strip after the others, and opens and closes', (
      tester,
    ) async {
      var selected = 0;
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TabStrip(
                  tabs: const [],
                  activeIndex: 0,
                  onSelect: (_, {kind = TabKind.terminal, path, web}) {},
                  onClose: (_) {},
                  onReconnect: (_) {},
                  onDuplicate: (_) {},
                  showTransfers: true,
                  onSelectTransfers: () => selected++,
                  onCloseTransfers: () => closed++,
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Transfers'));
      expect(selected, 1);
      await tester.tap(find.byTooltip('Close Transfers'));
      expect(closed, 1);
    });
  });
}

/// A file on the phone, as the picker hands one over: a copy with a path.
final class _PhoneFile extends PlatformFile {
  _PhoneFile(this.name);

  @override
  final String name;

  @override
  Uri get uri => Uri.file('/phone/$name');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => 0;

  @override
  Future<int> length() async => 0;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}
