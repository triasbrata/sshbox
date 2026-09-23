import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/pane_record.dart';
import 'package:sshbox/src/ui/pane_record_page.dart';

import 'fake_file_browser.dart';
import 'package:sshbox/src/ui/tui.dart';

List<String> _render(String output, {int columns = 20, int rows = 5}) =>
    renderRecord(utf8.encode(output), columns: columns, rows: rows);

/// [PaneRecord.pipe] as sh gets it once tmux has read its quoting and filled
/// in its formats.
String _pipe(String session, {int blocks = 16384}) {
  final quoted = PaneRecord.pipe(session, blocks: blocks);
  return quoted
      .substring(1, quoted.length - 1)
      .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!)
      .replaceAll('#{pid}', '1')
      .replaceAll('#{pane_id}', '%7');
}

void main() {
  group('renderRecord', () {
    test('keeps what a clear takes, however the clear is spelled', () {
      for (final clear in ['\x1b[H\x1b[J', '\x1b[H\x1b[2J\x1b[3J', '\x1bc']) {
        expect(_render('before\r\n${clear}after\r\n'), [
          'before',
          'after',
        ], reason: jsonEncode(clear));
      }
    });

    test('keeps the screen before a full-screen program, its last screen, '
        'and what came after it, in that order', () {
      expect(
        _render(
          'prompt\$ vim\r\n'
          '\x1b[?1049h\x1b[H\x1b[2Jfirst frame'
          '\x1b[1;1Hlast frame!'
          '\x1b[?1049l'
          'prompt\$ \r\n',
        ),
        ['prompt\$ vim', 'last frame!', 'prompt\$'],
      );
    });

    test('joins a wrapped line, and shows a skipped cell as a space', () {
      expect(_render('${'x' * 25}\r\nab\x1b[3Ccd\r\n'), ['x' * 25, 'ab   cd']);
    });

    test("drops screen's title sequence, as a pane does", () {
      expect(_render('\x1bktitle\x1b\\text\r\n'), ['text']);
    });
  });

  group('the pipe tmux runs', () {
    late Directory home;
    setUp(() async => home = await Directory.systemTemp.createTemp('record'));
    tearDown(() => home.delete(recursive: true));

    Future<Process> run(String session, {int blocks = 16384}) => Process.start(
      '/bin/sh',
      ['-c', _pipe(session, blocks: blocks)],
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
      includeParentEnvironment: false,
    );
    String dir(String session) => '${home.path}/${PaneRecord.dir(session)}';

    // What this sh's `ulimit -f` counts in, found by writing past a limit of
    // one: 512 bytes as POSIX has it, 1024 where it counts KB, as macOS's does.
    late int unit;
    setUpAll(() async {
      final probe = await Directory.systemTemp.createTemp('ulimit');
      final file = '${probe.path}/f';
      await Process.run('/bin/sh', [
        '-c',
        r'trap "" XFSZ; ulimit -f 1; head -c 4096 /dev/zero > "$0"',
        file,
      ]);
      unit = File(file).lengthSync();
      await probe.delete(recursive: true);
      expect(unit, anyOf(512, 1024));
    });

    test('turns over to a new file at its size, keeping the newest, in '
        'private files', () async {
      // A file of 1024 bytes wherever it runs, so 40 chunks turn it over.
      final pipe = await run('sshbox-a', blocks: 1024 ~/ unit);
      for (var i = 0; i < 40; i++) {
        final chunk = 'chunk-$i '.padRight(99, '.');
        pipe.stdin.add(utf8.encode('$chunk\n'));
        await pipe.stdin.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await pipe.stdin.close();
      expect(await pipe.exitCode, 0);

      final older = File('${dir('sshbox-a')}/1-%7.1');
      final current = File('${dir('sshbox-a')}/1-%7');
      expect(older.lengthSync(), 1024);
      expect(current.lengthSync(), lessThanOrEqualTo(1024));
      final kept = older.readAsStringSync() + current.readAsStringSync();
      expect(kept, endsWith('${'chunk-39 '.padRight(99, '.')}\n'));
      expect(kept, isNot(contains('chunk-0 ')));
      for (final file in [older, current]) {
        expect(file.statSync().mode & 0x1ff, 0x180);
      }
      expect(Directory(dir('sshbox-a')).statSync().mode & 0x1ff, 0x1c0);
    });

    test('writes nothing through a link planted in its way', () async {
      final elsewhere = await Directory('${home.path}/elsewhere').create();
      await Directory(dir('sshbox-a')).parent.create(recursive: true);
      await Link(dir('sshbox-a')).create(elsewhere.path);
      await Directory(dir('sshbox-b')).create(recursive: true);
      await Link('${dir('sshbox-b')}/1-%7').create('${home.path}/target');

      for (final session in ['sshbox-a', 'sshbox-b']) {
        final pipe = await run(session);
        pipe.stdin.add(utf8.encode('secret\n'));
        try {
          await pipe.stdin.close();
        } on SocketException catch (e) {
          // The pipe finds the link and exits without reading a byte. When it
          // has done so before this write lands — a runner that holds this
          // thread for a few milliseconds is enough — nobody is left at the
          // other end and the write fails with EPIPE (32 on Linux and macOS
          // alike): the refusal was quick, not wrong. Any other failure is
          // one. Whether anything reached the link's target is checked below
          // either way, and a pipe that followed the link would be reading
          // this, not gone.
          if (e.osError?.errorCode != 32) rethrow;
        }
        await pipe.exitCode;
      }
      expect(elsewhere.listSync(), isEmpty);
      expect(File('${home.path}/target').existsSync(), isFalse);
    });
  });

  group('PaneRecordReader', () {
    const session = 'sshbox-r';
    const dir = '/home/me/.local/state/jeansh/records/$session';

    FakeFileBrowser browser() => FakeFileBrowser()
      ..putBinary('$dir/1-%7.1', utf8.encode('l1\nl2\nl3\n'))
      ..putBinary('$dir/1-%7', utf8.encode('l4\nl5\n'));

    test('reads the end first, across both files, from a line start, then '
        'pages back to the beginning', () async {
      final reader = PaneRecordReader(
        browser(),
        session: session,
        name: '1-%7',
        page: 7,
      );
      expect(utf8.decode((await reader.tail())!), 'l4\nl5\n');
      expect(reader.start, 9);
      expect(utf8.decode(await reader.earlier()), 'l2\nl3\n');
      expect(utf8.decode(await reader.earlier()), 'l1\n');
      expect(reader.start, 0);
    });

    test('a pane with no record says so', () async {
      final reader = PaneRecordReader(
        browser(),
        session: session,
        name: '2-%1',
      );
      expect(await reader.tail(), isNull);
    });
  });

  testWidgets('the page shows the end of the record, newest at the bottom, '
      'and loads what came before', (tester) async {
    const dir = '/home/me/.local/state/jeansh/records/sshbox-p';
    final fake = FakeFileBrowser()
      ..putBinary(
        '$dir/1-%0',
        utf8.encode([for (var i = 1; i <= 30; i++) 'line $i\r\n'].join()),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: PaneRecordPage(
          reader: PaneRecordReader(
            fake,
            session: 'sshbox-p',
            name: '1-%0',
            page: 100,
          ),
          columns: 40,
          rows: 10,
        ),
      ),
    );
    // Until the read, and its replay on an isolate of its own, are done.
    Future<void> settle() async {
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.byType(TuiProgressBar).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    await settle();
    expect(find.text('line 30'), findsOneWidget);
    expect(find.text('line 1'), findsNothing);
    final bottom = tester.getTopLeft(find.text('line 30')).dy;
    expect(tester.getTopLeft(find.text('line 29')).dy, lessThan(bottom));

    for (var page = 0; page < 10; page++) {
      // Up to the top of what is read, where the button is.
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pump(const Duration(seconds: 2));
      if (find.text('LOAD EARLIER').evaluate().isEmpty) break;
      await tester.tap(find.text('LOAD EARLIER'));
      await settle();
    }
    expect(find.text('line 1'), findsOneWidget);
    expect(find.text('Start of the record'), findsOneWidget);
  });

  test('bytes past a page start mid-line are dropped only up to an escape '
      'sequence', () async {
    const dir = '/home/me/.local/state/jeansh/records/sshbox-e';
    final reader = PaneRecordReader(
      FakeFileBrowser()..putBinary(
        '$dir/1-%0',
        Uint8List.fromList(utf8.encode('abc\x1b[1mdef\nghi')),
      ),
      session: 'sshbox-e',
      name: '1-%0',
      page: 12,
    );
    expect(utf8.decode((await reader.tail())!), '\x1b[1mdef\nghi');
  });
}
