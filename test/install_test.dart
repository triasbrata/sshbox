@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/update/install.dart';
import 'package:sshbox/src/update/updater.dart';

/// One tar entry, written by hand so a test can say anything a hostile
/// archive could: [type] '0' a file, '5' a folder, '2' a symbolic link, '1' a
/// hard link, '6' a FIFO.
List<int> tarEntry(
  String name, {
  String type = '0',
  String body = '',
  String link = '',
  int mode = 0x1ed,
}) {
  final content = utf8.encode(body);
  final header = Uint8List(512);
  void put(int at, String text) {
    final bytes = utf8.encode(text);
    header.setRange(at, at + bytes.length, bytes);
  }

  String octal(int value, int width) =>
      value.toRadixString(8).padLeft(width - 1, '0');
  put(0, name);
  put(100, octal(mode, 8));
  put(108, octal(0, 8));
  put(116, octal(0, 8));
  put(124, octal(content.length, 12));
  put(136, octal(0, 12));
  put(148, '        ');
  put(156, type);
  put(157, link);
  put(257, 'ustar');
  put(263, '00');
  final sum = header.fold<int>(0, (total, byte) => total + byte);
  put(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  final padded = (content.length + 511) ~/ 512 * 512;
  return [...header, ...content, ...List.filled(padded - content.length, 0)];
}

/// [entries] as a `.tar.gz` in [dir].
File tarGz(Directory dir, List<List<int>> entries, {String name = 'b'}) =>
    File('${dir.path}/$name.tar.gz')..writeAsBytesSync(
      gzip.encode([...entries.expand((e) => e), ...List.filled(1024, 0)]),
    );

/// A folder packed the way tools/build_desktop.sh packs the Linux build: GNU
/// tar, the one folder at the top.
///
/// A Mac's tar is bsdtar, which writes pax headers — a name not ASCII, and
/// the Mac's own extended attributes, which it adds to everything — that CI's
/// GNU tar never writes and the updater never meets: the feed's Linux build
/// is packed on Linux, and the Mac's is a zip. So bsdtar is asked for GNU's
/// format and none of the Mac's metadata, to pack what CI packs.
File packed(Directory from, String top, File into) {
  final result = Process.runSync(
    'tar',
    [
      if (_bsdtar) ...['--format=gnutar', '--no-mac-metadata'],
      '-C',
      from.path,
      '-czf',
      into.path,
      top,
    ],
    environment: {'COPYFILE_DISABLE': '1'},
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return into;
}

/// Whether this machine's tar is bsdtar, as a Mac's is, rather than GNU's.
final _bsdtar = (Process.runSync('tar', ['--version']).stdout as String)
    .contains('bsdtar');

/// A stand-in for the jeansh program: a script that, started, writes which
/// build it is into `ran` beside the install, with where it was started from.
String program(String which) =>
    '#!/bin/sh\nprintf \'%s %s\\n\' $which "\$PWD" > "\${0%/*}/../ran"\n';

/// Waits up to [seconds] for [done].
Future<void> until(bool Function() done, {int seconds = 10}) async {
  for (var i = 0; i < seconds * 20 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Every file anywhere under [dir] whose name starts with `pwned`.
List<String> pwned(Directory dir) => dir
    .listSync(recursive: true, followLinks: false)
    .map((e) => e.path)
    .where((path) => path.split('/').last.startsWith('pwned'))
    .toList();

/// A folder name holding everything a script could misread: a space, both
/// quotes, a command substitution both ways, `;`, `&`, cmd's `%` and `^`, a
/// glob and something not ASCII.
const nasty =
    'it\'s "x" \$(touch pwned-sub) `touch pwned-tick`; & %PATH% ^ '
    '[b]* café';

void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('install_test'));
  tearDown(() {
    // A test that took write away gives it back first.
    Process.runSync('chmod', ['-R', 'u+w', base.path]);
    base.deleteSync(recursive: true);
  });

  test('an install is found where a release unpacks, and nowhere else', () {
    expect(
      Install.of('/home/u/Apps/jeansh-1.0.73+77/jeansh', 'linux')?.root.path,
      '/home/u/Apps/jeansh-1.0.73+77',
    );
    expect(
      Install.of(
        '/Applications/Jeansh.app/Contents/MacOS/Jeansh',
        'macos',
      )?.root.path,
      '/Applications/Jeansh.app',
    );
    expect(
      Install.of(r'C:\Apps\Jeansh-1.0.73\Jeansh.exe', 'windows'),
      isNotNull,
    );
    // A build that is not laid out as a release unpacks, this test runner
    // among them, is left alone.
    expect(Install.of('/opt/x/Contents/MacOS/Jeansh', 'macos'), isNull);
    expect(Install.of('/usr/bin/other', 'linux'), isNull);
    expect(Install.of(Platform.resolvedExecutable, 'linux'), isNull);
  });

  group('checking an archive', () {
    test('a build packed as CI packs it passes and names its folder', () {
      final build = Directory('${base.path}/src/jeansh-1.0.74+78/lib')
        ..createSync(recursive: true);
      File('${build.parent.path}/jeansh').writeAsStringSync('');
      File('${build.path}/libapp.so.1').writeAsStringSync('');
      Link('${build.path}/libapp.so').createSync('libapp.so.1');
      final archive = packed(
        Directory('${base.path}/src'),
        'jeansh-1.0.74+78',
        File('${base.path}/linux.tar.gz'),
      );
      expect(checkArchive(archive.path, 'linux'), 'jeansh-1.0.74+78');

      // A bundle's framework links, stored as ditto stores them: as links in
      // a zip made on Unix.
      final framework = Directory(
        '${base.path}/mac/Jeansh.app/Contents/Frameworks/App.framework/'
        'Versions/A',
      )..createSync(recursive: true);
      File('${framework.path}/App').writeAsStringSync('');
      Link('${framework.parent.path}/Current').createSync('A');
      Link('${framework.parent.parent.path}/App')
          .createSync('Versions/Current/App');
      final zip = Process.runSync('zip', [
        '-qry',
        '${base.path}/mac.zip',
        'Jeansh.app',
      ], workingDirectory: '${base.path}/mac');
      expect(zip.exitCode, 0, reason: '${zip.stderr}');
      expect(checkArchive('${base.path}/mac.zip', 'macos'), 'Jeansh.app');
      // Windows builds have no links, so one there is refused.
      expect(
        () => checkArchive('${base.path}/mac.zip', 'windows'),
        throwsA(isA<UpdateException>()),
      );
    });

    test('an entry that could land outside its folder is refused', () {
      final top = tarEntry('top/', type: '5');
      final hostile = <String, List<List<int>>>{
        'a walk upwards': [top, tarEntry('../evil')],
        'a walk upwards inside a name': [top, tarEntry('top/../../evil')],
        'an absolute name': [top, tarEntry('/tmp/evil')],
        'a Windows separator': [top, tarEntry(r'top\..\..\evil')],
        'a drive': [top, tarEntry('top/C:evil')],
        'a name not in ASCII': [top, tarEntry('top/café')],
        'a link to an absolute path': [
          top,
          tarEntry('top/l', type: '2', link: '/etc'),
        ],
        'a link upwards out of the folder': [
          top,
          tarEntry('top/l', type: '2', link: '../../..'),
        ],
        'a file written through a link': [
          top,
          tarEntry('top/l', type: '2', link: 'sub'),
          tarEntry('top/l/x'),
        ],
        'a file written through a link, the case changed': [
          top,
          tarEntry('top/l', type: '2', link: 'sub'),
          tarEntry('top/L/x'),
        ],
        // Each link stays inside on its own; written through the first, the
        // second lands above the folder.
        'a link written through a link': [
          top,
          tarEntry('top/d/', type: '5'),
          tarEntry('top/d/l', type: '2', link: '..'),
          tarEntry('top/d/l/l2', type: '2', link: '..'),
        ],
        'a hard link': [top, tarEntry('top/h', type: '1', link: '/etc/passwd')],
        'a hard link inside': [
          top,
          tarEntry('top/jeansh'),
          tarEntry('top/h', type: '1', link: 'top/jeansh'),
        ],
        'a FIFO': [top, tarEntry('top/f', type: '6')],
        'two folders at the top': [top, tarEntry('top/a'), tarEntry('b/c')],
        'a file at the top': [tarEntry('jeansh')],
        'a link at the top': [tarEntry('top', type: '2', link: '.')],
        'nothing': [],
      };
      hostile.forEach((what, entries) {
        expect(
          () => checkArchive(tarGz(base, entries).path, 'linux'),
          throwsA(isA<UpdateException>()),
          reason: what,
        );
      });
    });

    test('a zip entry that walks out is refused', () {
      // The archive package writes a name as it stands, which zip will not.
      final archive = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile.string('top/jeansh', 'x'))
          ..addFile(ArchiveFile.string('top/../../evil', 'x')),
      );
      final file = File('${base.path}/b.zip')..writeAsBytesSync(archive);
      expect(
        () => checkArchive(file.path, 'windows'),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('staging', () {
    late Directory apps;
    late Install install;
    setUp(() {
      apps = Directory('${base.path}/$nasty')..createSync();
      final root = Directory('${apps.path}/jeansh-1.0.73+77')..createSync();
      File('${root.path}/jeansh').writeAsStringSync(program('old'));
      Process.runSync('chmod', ['0755', '${root.path}/jeansh']);
      install = Install('linux', root);
    });

    /// A new build of [files] by name, packed as CI packs it.
    File build(Map<String, String> files) {
      final src = Directory('${base.path}/src/jeansh-1.0.74+78')
        ..createSync(recursive: true);
      files.forEach((name, body) {
        final file = File('${src.path}/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync(body);
        Process.runSync('chmod', ['0755', file.path]);
      });
      return packed(
        src.parent,
        'jeansh-1.0.74+78',
        File('${base.path}/Jeansh-1.0.74+78-linux-x64.tar.gz'),
      );
    }

    /// What is beside the install, by name.
    List<String> beside() =>
        apps.listSync().map((e) => e.path.split('/').last).toList()..sort();

    test('unpacks beside the install, in a folder of its own, and leaves the '
        'install alone', () async {
      final staged = await install.stage(
        build({'jeansh': program('new'), 'lib/libapp.so': ''}),
      );

      expect(staged.path, startsWith('${apps.path}/$stagePrefix'));
      expect(staged.path, endsWith('/new/jeansh-1.0.74+78'));
      expect(File('${staged.path}/jeansh').readAsStringSync(), program('new'));
      expect(
        File('${install.root.path}/jeansh').readAsStringSync(),
        program('old'),
      );
      expect(pwned(base), isEmpty);
    });

    test(
      'a build with no program in it is refused, and nothing is left',
      () async {
        await expectLater(
          install.stage(build({'lib/libapp.so': ''})),
          throwsA(
            isA<UpdateException>().having(
              (e) => e.message,
              'message',
              contains('no jeansh'),
            ),
          ),
        );
        expect(beside(), ['jeansh-1.0.73+77']);
      },
    );

    test(
      'a refused archive writes nothing, beside the install or anywhere',
      () async {
        for (final entries in [
          [tarEntry('jeansh-1.0.74+78/', type: '5'), tarEntry('../evil')],
          [
            tarEntry('jeansh-1.0.74+78/', type: '5'),
            tarEntry('jeansh-1.0.74+78/l', type: '2', link: '../../..'),
            tarEntry('jeansh-1.0.74+78/l/evil'),
          ],
        ]) {
          await expectLater(
            install.stage(tarGz(base, entries)),
            throwsA(isA<UpdateException>()),
          );
          expect(beside(), ['jeansh-1.0.73+77']);
        }
        expect(
          base
              .listSync(recursive: true, followLinks: false)
              .where((e) => e.path.endsWith('evil')),
          isEmpty,
        );
      },
    );

    test(
      'a link that only leaves through another is caught once unpacked',
      () async {
        // Lexically both stay inside: l1 is the folder, and l2 is a/l1/.. —
        // but on the disk a/l1 is the folder, so l2 is the one above it.
        final archive = tarGz(base, [
          tarEntry('jeansh-1.0.74+78/', type: '5'),
          tarEntry('jeansh-1.0.74+78/jeansh', body: program('new')),
          tarEntry('jeansh-1.0.74+78/a/', type: '5'),
          tarEntry('jeansh-1.0.74+78/a/l1', type: '2', link: '..'),
          tarEntry('jeansh-1.0.74+78/l2', type: '2', link: 'a/l1/..'),
        ]);
        expect(checkArchive(archive.path, 'linux'), 'jeansh-1.0.74+78');
        await expectLater(
          install.stage(archive),
          throwsA(
            isA<UpdateException>().having(
              (e) => e.message,
              'message',
              contains('links out of it'),
            ),
          ),
        );
        expect(beside(), ['jeansh-1.0.73+77']);
      },
    );

    test('where the install\'s folder takes nothing new, it says so', () async {
      Process.runSync('chmod', ['0555', apps.path]);
      expect(install.refusal, contains('cannot write to ${apps.path}'));
      await expectLater(
        install.stage(build({'jeansh': program('new')})),
        throwsA(isA<UpdateException>()),
      );
    });

    group('then the swap, by the helper, once this copy has quit', () {
      /// Stands in for the running copy: the helper waits for it to go.
      late Process running;
      setUp(() async => running = await Process.start('sleep', ['60']));
      tearDown(() => running.kill());

      File ran() => File('${apps.path}/ran');

      test('puts the new build in place and starts it', () async {
        final staged = await install.stage(build({'jeansh': program('new')}));
        final stage = staged.parent.parent;
        await install.handOff(staged, processId: running.pid);

        // The helper waits in a folder only this user can open.
        final helpers = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => File('${d.path}/finish-update.sh').existsSync())
            .toList();
        expect(helpers, hasLength(1));
        expect(helpers.single.statSync().mode & 0x1ff, 0x1c0);

        // Nothing moves while the copy runs.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(
          File('${install.root.path}/jeansh').readAsStringSync(),
          program('old'),
        );
        expect(ran().existsSync(), isFalse);

        running.kill();
        await until(() => ran().existsSync());
        expect(ran().readAsStringSync(), 'new /\n');
        expect(helpers.single.existsSync(), isFalse, reason: 'it cleans up');
        expect(
          File('${install.root.path}/jeansh').readAsStringSync(),
          program('new'),
        );
        expect(
          File('${stage.path}/old/jeansh').readAsStringSync(),
          program('old'),
        );
        // Where the helper ran, and where this test runs.
        expect(pwned(base), isEmpty);
        expect(
          Directory.systemTemp.listSync().where(
            (e) => e.path.split('/').last.startsWith('pwned'),
          ),
          isEmpty,
        );
        expect(File('pwned-sub').existsSync(), isFalse);

        // The next start removes the old copy, and says nothing.
        expect(install.cleanUp(), isFalse);
        expect(beside(), ['jeansh-1.0.73+77', 'ran']);
      });

      test(
        'a swap that fails puts the old install back and starts it',
        () async {
          final staged = await install.stage(build({'jeansh': program('new')}));
          await install.handOff(staged, processId: running.pid);
          // A folder moved to another parent needs write on itself, for its
          // `..`: without it the second move fails after the first is done.
          Process.runSync('chmod', ['0555', staged.path]);

          running.kill();
          await until(() => ran().existsSync());
          expect(ran().readAsStringSync(), 'old /\n');
          expect(
            File('${install.root.path}/jeansh').readAsStringSync(),
            program('old'),
          );

          // The next start clears it away and says it did not go in.
          Process.runSync('chmod', ['0755', staged.path]);
          expect(install.cleanUp(), isTrue);
          expect(beside(), ['jeansh-1.0.73+77', 'ran']);
        },
      );
    });
  });

  group('the helper script', () {
    late File script;
    late Directory dir;
    setUp(() {
      dir = Directory('${base.path}/helper')..createSync();
      script = File('${dir.path}/finish-update.sh')
        ..writeAsStringSync(posixHelper);
    });

    test('takes a process id and nothing else in its place', () {
      final result = Process.runSync('/bin/sh', [
        script.path,
        '1; touch pwned',
        'a',
        'b',
        'c',
        dir.path,
        'linux',
      ], workingDirectory: base.path);
      expect(result.exitCode, 1);
      expect(File('${dir.path}/ready').existsSync(), isFalse);
      expect(pwned(base), isEmpty);
    });

    test('called off while it waits, it changes nothing', () async {
      final install = Directory('${base.path}/install')..createSync();
      final running = await Process.start('sleep', ['60']);
      final helper = await Process.start('/bin/sh', [
        script.path,
        '${running.pid}',
        install.path,
        '${base.path}/new',
        '${base.path}/stage',
        dir.path,
        'linux',
      ]);
      await until(() => File('${dir.path}/ready').existsSync());
      // What Jeansh does when it gives up on the helper: its folder goes.
      File('${dir.path}/ready').deleteSync();
      running.kill();
      expect(await helper.exitCode, 0);
      expect(install.existsSync(), isTrue);
    });

    test('expands every path it is given inside double quotes, and nothing '
        'is evaluated', () {
      for (final name in ['pid', 'install', 'new', 'stage', 'dir']) {
        final uses = RegExp('.\\\$$name\\b').allMatches(posixHelper);
        expect(uses, isNotEmpty, reason: name);
        for (final use in uses) {
          expect(use.group(0)![0], '"', reason: '\$$name unquoted');
        }
      }
      expect(posixHelper, isNot(contains('eval')));
      expect(posixHelper, isNot(contains('`')));
    });
  });

  test('the Windows helper hands every path to .NET, and to nothing that '
      'expands it', () {
    // No double-quoted string, where PowerShell would expand a `$`; no
    // backtick; nothing that runs text as code, starts cmd, or reads a path
    // as a wildcard; and ASCII, which Windows PowerShell reads right with no
    // BOM.
    expect(windowsHelper, isNot(contains('"')));
    expect(windowsHelper, isNot(contains('`')));
    for (final word in [
      'Invoke-Expression',
      'iex ',
      'cmd',
      'Start-Process',
      '-Path',
      ' & ',
    ]) {
      expect(windowsHelper, isNot(contains(word)), reason: word);
    }
    expect(windowsHelper.codeUnits.every((unit) => unit < 0x80), isTrue);
    expect(windowsHelper, contains(r'[int]$ProcessId'));
  });

  test(
    'a file that is not the build the feed describes is never unpacked',
    () async {
      final root = Directory('${base.path}/jeansh-1.0.73+77')..createSync();
      var quit = 0;
      final updater = Updater(
        host: 'https://builds.example.test',
        version: '1.0.73+77',
        install: Install('linux', root),
        quit: () => quit++,
      );
      final archive = File('${base.path}/Jeansh-1.0.74+78-linux-x64.tar.gz')
        ..writeAsStringSync('something else');
      final update = Update(
        version: '1.0.74',
        build: 78,
        path: 'desktop/linux/Jeansh-1.0.74+78-linux-x64.tar.gz',
        size: 14,
        sha256: sha256.convert(utf8.encode('the real build')).toString(),
      );
      await expectLater(
        updater.restartInto(update, archive),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('not the file the release describes'),
          ),
        ),
      );
      expect(quit, 0);
      expect(
        base.listSync().map((e) => e.path.split('/').last),
        isNot(contains(startsWith(stagePrefix))),
      );
    },
  );
}
