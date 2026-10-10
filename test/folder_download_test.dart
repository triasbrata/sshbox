import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/folder_archive.dart';
import 'package:sshbox/src/files/local_file_browser.dart';
import 'package:sshbox/src/ui/termul/tui_transfer_row.dart';
import 'package:sshbox/src/files/transfers.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/folder_download.dart' show folderReport;
import 'package:sshbox/src/ui/toast.dart';

import 'fake_file_browser.dart';
import 'fake_file_picker.dart';

/// A host that can compress: [tool] is what its probe finds, and an archive
/// is the bytes in [archive], at a path of the shape the real scripts print.
class _ArchiveBrowser extends FakeFileBrowser implements FolderArchiveCapable {
  ArchiveTool? tool = const ArchiveTool(ArchiveKind.zip, '/usr/bin/zip');
  FileBrowserException? probeFails;
  FileBrowserException? archiveFails;

  /// Held until completed or cancelled, as a long compression is.
  Completer<void>? compressing;
  final List<String> archived = [];
  final List<String> removed = [];
  static const archivePath = '/tmp/jeansh-zip.abc123/jeansh.zip';

  @override
  Future<ArchiveTool?> findArchiveTool() async {
    final failure = probeFails;
    if (failure != null) throw failure;
    return tool;
  }

  @override
  Future<({String path, int size})> archiveFolder(
    String folder,
    ArchiveTool tool, {
    Future<void>? cancel,
  }) async {
    archived.add(folder);
    final held = compressing;
    if (held != null) {
      await Future.any([held.future, ?cancel]);
      if (!held.isCompleted) throw FileBrowserException.cancelled;
    }
    final failure = archiveFails;
    if (failure != null) throw failure;
    putBinary(archivePath, utf8.encode('ARCHIVE of $folder'));
    return (path: archivePath, size: 20);
  }

  @override
  Future<void> removeArchive(String archivePath) async =>
      removed.add(archivePath);
}

Future<void> _pump(WidgetTester tester, FakeFileBrowser browser) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FileBrowserPage(browser: browser, title: 'box'),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String name) =>
    find.descendant(of: find.byType(ListView), matching: find.text(name));

Future<void> _menu(WidgetTester tester, String name) async {
  await tester.longPress(_row(name));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String name, String action) async {
  await _menu(tester, name);
  await tester.tap(find.text(action));
  // Not settled: that would outlast a toast.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => transfers.clearFinished());

  group('the folder menu', () {
    testWidgets('on a phone offers zip where the host can compress, and no '
        'plain folder download', (tester) async {
      await _pump(tester, _ArchiveBrowser());
      await _menu(tester, 'dev');
      expect(find.text('Download as zip'), findsOneWidget);
      expect(find.text('Download folder'), findsNothing);
    });

    testWidgets('on a phone with a host that cannot, offers neither', (
      tester,
    ) async {
      await _pump(tester, FakeFileBrowser());
      await _menu(tester, 'dev');
      expect(find.text('Download as zip'), findsNothing);
      expect(find.text('Download folder'), findsNothing);
    });

    testWidgets('a file offers neither', (tester) async {
      await _pump(tester, _ArchiveBrowser());
      await _menu(tester, 'notes.txt');
      expect(find.text('Download as zip'), findsNothing);
      expect(find.text('Download folder'), findsNothing);
    });

    testWidgets('on a desktop offers both', (tester) async {
      await _pump(tester, _ArchiveBrowser());
      await _menu(tester, 'dev');
      expect(find.text('Download as zip'), findsOneWidget);
      expect(find.text('Download folder'), findsOneWidget);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('a desktop host that cannot compress still offers the tree', (
      tester,
    ) async {
      await _pump(tester, FakeFileBrowser());
      await _menu(tester, 'dev');
      expect(find.text('Download as zip'), findsNothing);
      expect(find.text('Download folder'), findsOneWidget);
    }, variant: TargetPlatformVariant.desktop());
  });

  group('Download as zip', () {
    testWidgets('compresses on the host, saves the archive under the '
        "folder's name and removes it from the host", (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser();
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');

      expect(browser.archived, ['/home/me/dev']);
      expect(picker.saved?.name, 'dev.zip');
      expect(picker.saved?.bytes, utf8.encode('ARCHIVE of /home/me/dev'));
      expect(browser.removed, [_ArchiveBrowser.archivePath]);
      expect(transfers.items.first.state, TransferState.done);
      expect(transfers.items.first.name, 'dev.zip');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('a .tar.gz is called that, never a zip', (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser()
        ..tool = const ArchiveTool(ArchiveKind.tarGz, '/bin/tar');
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');

      expect(picker.saved?.name, 'dev.tar.gz');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('no tool on the host: says so, offers no plain download on a '
        'phone, and starts nothing', (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser()..tool = null;
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');

      expect(find.text('No zip tool on box'), findsOneWidget);
      expect(find.bySemanticsLabel('Plain download'), findsNothing);
      expect(browser.archived, isEmpty);
      expect(transfers.items, isEmpty);
      expect(picker.saved, isNull);
      await tester.tap(find.bySemanticsLabel('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('No zip tool on box'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('no tool on a desktop offers the plain download, which '
        'goes on to the folder picker', (tester) async {
      final dialog = useFakeSaveDialog(null);
      final browser = _ArchiveBrowser()..tool = null;
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');
      expect(find.bySemanticsLabel('Plain download'), findsOneWidget);
      expect(dialog.directoryAsked, 0);

      await tester.tap(find.bySemanticsLabel('Plain download'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(dialog.directoryAsked, 1);
      expect(browser.archived, isEmpty);
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('a probe that cannot reach the host is an error, not a '
        '"no tool"', (tester) async {
      final browser = _ArchiveBrowser()
        ..probeFails = const FileBrowserException(
          'Could not look for a zip tool on the host: gone',
          fault: FileBrowserFault.disconnected,
        );
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');

      expect(
        find.descendant(
          of: find.byType(TuiToastCard),
          matching: find.textContaining('Could not look for a zip tool'),
        ),
        findsOneWidget,
      );
      expect(find.text('No zip tool on box'), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('a tool failing, disk full among it, is shown and saves '
        'nothing', (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser()
        ..archiveFails = const FileBrowserException(
          'zip failed on the host (exit 15): No space left on device',
        );
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');

      expect(
        find.descendant(
          of: find.byType(TuiToastCard),
          matching: find.textContaining('No space left on device'),
        ),
        findsOneWidget,
      );
      expect(picker.saved, isNull);
      expect(find.text('Saved dev.zip'), findsNothing);
      expect(transfers.items.first.state, TransferState.failed);
      expect(transfers.items.first.error, contains('No space left'));
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('the archive is removed from the host even when its '
        'download fails', (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser();
      await _pump(tester, browser);
      browser.failReadWith = const FileBrowserException(
        'The connection to the host was lost.',
        fault: FileBrowserFault.disconnected,
      );

      await _pick(tester, 'dev', 'Download as zip');

      expect(browser.removed, [_ArchiveBrowser.archivePath]);
      expect(picker.saved, isNull);
      expect(
        find.descendant(
          of: find.byType(TuiToastCard),
          matching: find.textContaining('connection to the host was lost'),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('Cancel while compressing stops it, saves nothing and '
        'says nothing', (tester) async {
      final picker = useFakePicker();
      final browser = _ArchiveBrowser()..compressing = Completer<void>();
      await _pump(tester, browser);

      await _pick(tester, 'dev', 'Download as zip');
      final transfer = transfers.items.first;
      expect(transfer.state, TransferState.running);
      expect(transfer.phase, 'Compressing with zip');

      transfers.cancel(transfer);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(transfer.state, TransferState.cancelled);
      expect(picker.saved, isNull);
      expect(find.byType(TuiToastCard), findsNothing);
      expect(browser.removed, isEmpty, reason: 'it never got made');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });

  group('Download folder', () {
    final desktop = TargetPlatformVariant({TargetPlatform.linux});

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 30 && transfers.anyRunning; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> run(WidgetTester tester) async {
      await _menu(tester, 'dev');
      await tester.tap(find.text('Download folder'));
      await settle(tester);
    }

    testWidgets('brings the tree into a folder of its name, whole or not '
        'at all', (tester) async {
      final dest = Directory.systemTemp.createTempSync('folder');
      addTearDown(() => dest.deleteSync(recursive: true));
      final dialog = useFakeSaveDialog(null)..directory = dest.path;
      final browser = FakeFileBrowser()
        ..putBinary('/home/me/dev/pic.bin', [1, 2, 3]);
      await _pump(tester, browser);

      await run(tester);

      expect(dialog.directoryAsked, 1);
      expect(
        File('${dest.path}/dev/main.dart').readAsStringSync(),
        'void main() {}\n',
      );
      expect(File('${dest.path}/dev/pic.bin').readAsBytesSync(), [1, 2, 3]);
      // The part folder is gone, renamed to the folder's name.
      expect(dest.listSync().map((e) => e.path.split('/').last), ['dev']);
      expect(transfers.items.first.state, TransferState.done);
      expect(transfers.items.first.note, '2 files');
      expect(find.text('Saved dev'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }, variant: desktop);

    testWidgets('a dismissed folder picker starts nothing', (tester) async {
      final dialog = useFakeSaveDialog(null);
      final browser = FakeFileBrowser();
      await _pump(tester, browser);

      await run(tester);

      expect(dialog.directoryAsked, 1);
      expect(transfers.items, isEmpty);
      expect(browser.downloads, isEmpty);
    }, variant: desktop);

    testWidgets('a file that fails is listed, and the rest still come', (
      tester,
    ) async {
      final dest = Directory.systemTemp.createTempSync('folder');
      addTearDown(() => dest.deleteSync(recursive: true));
      useFakeSaveDialog(null).directory = dest.path;
      final browser = _FailsOne()..putBinary('/home/me/dev/bad.bin', [9]);
      await _pump(tester, browser);

      await run(tester);

      expect(File('${dest.path}/dev/main.dart').existsSync(), isTrue);
      expect(File('${dest.path}/dev/bad.bin').existsSync(), isFalse);
      expect(find.textContaining('1 failed'), findsWidgets);
      expect(find.textContaining('bad.bin: Permission denied'), findsOneWidget);
      expect(transfers.items.first.note, '1 files, 1 failed, 0 skipped');
      await tester.tap(find.bySemanticsLabel('OK'));
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }, variant: desktop);

    testWidgets('cancelling leaves no part folder and no folder', (
      tester,
    ) async {
      final dest = Directory.systemTemp.createTempSync('folder');
      addTearDown(() => dest.deleteSync(recursive: true));
      useFakeSaveDialog(null).directory = dest.path;
      final browser = FakeFileBrowser()..hold = Completer<void>();
      await _pump(tester, browser);

      await _menu(tester, 'dev');
      await tester.tap(find.text('Download folder'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      transfers.cancel(transfers.items.first);
      await settle(tester);

      expect(transfers.items.first.state, TransferState.cancelled);
      expect(dest.listSync(), isEmpty);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }, variant: desktop);
  });

  test('a row says what a transfer is doing while it has no byte count', () {
    const direction = TuiTransferDirection.download;
    String line(TuiTransferStatus status, {String? phase, String? note}) =>
        tuiTransferStatusLine(
          direction: direction,
          status: status,
          host: 'box',
          doneBytes: 2048,
          totalBytes: 4096,
          phase: phase,
          note: note,
        );
    expect(
      line(TuiTransferStatus.running, phase: 'Compressing with zip'),
      'Compressing with zip from box',
    );
    expect(line(TuiTransferStatus.running), contains('2.0 KB of 4.0 KB'));
    expect(
      line(TuiTransferStatus.done, note: '3 files, 1 failed, 0 skipped'),
      endsWith('· 3 files, 1 failed, 0 skipped'),
    );
    expect(line(TuiTransferStatus.done), isNot(contains('files')));
  });

  test(
    'a local browser archives a real folder with what the machine has',
    () async {
      final tmp = Directory.systemTemp.createTempSync('local');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final src = Directory('${tmp.path}/my folder')..createSync();
      File('${src.path}/a.txt').writeAsStringSync('hi');
      final browser = LocalFileBrowser(
        process: (command) => Process.start(
          'sh',
          ['-c', command],
          environment: {'TMPDIR': tmp.path},
        ),
      );
      final tool = await browser.findArchiveTool();
      expect(tool, isNotNull);
      final made = await browser.archiveFolder(src.path, tool!);
      expect(File(made.path).existsSync(), isTrue);
      await browser.removeArchive(made.path);
      expect(File(made.path).parent.existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('the report lists failures and skips, a few of each', () {
    final text = folderReport(
      failed: [for (var i = 0; i < 20; i++) 'f$i: nope'],
      skipped: ['l (link)'],
    );
    expect(text, contains('Failed:\nf0: nope'));
    expect(text, contains('… and 5 more'));
    expect(text, contains('Skipped, never followed:\nl (link)'));
    expect(folderReport(failed: [], skipped: []), isEmpty);
  });
}

/// Refuses one file, as a login that may not read it is.
class _FailsOne extends FakeFileBrowser {
  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) {
    if (path.endsWith('bad.bin')) {
      throw const FileBrowserException(
        'Permission denied.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    return super.download(
      path,
      localPath,
      offset: offset,
      length: length,
      onProgress: onProgress,
      cancel: cancel,
    );
  }
}
