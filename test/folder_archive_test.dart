@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/folder_archive.dart';

/// A name for every way a shell, an option parser or a pattern could be made
/// to read a folder's name as something other than a name.
const _evil = [
  "it's a \"folder\"",
  r'$(touch pwned-sub)',
  '`touch pwned-tick`',
  'a;touch pwned-semi',
  '-rf',
  '--help',
  '@listfile',
  'star*[x]?',
  'new\nline',
  'tab\there',
];

late Directory _tmp;
late ScriptRunner _runner;

ScriptRunner _sh(Directory tmp, {String path = ''}) => processRunner(
  (script) => Process.start(
    'sh',
    ['-c', script],
    environment: {'TMPDIR': tmp.path, if (path.isNotEmpty) 'PATH': path},
  ),
);

/// A stand-in archiver that records its argv, one per line, and makes the
/// archive, or does what [body] says.
String _stub(Directory dir, String name, {String body = ''}) {
  final file = File('${dir.path}/$name');
  file.writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > "${dir.path}/$name.argv"
$body
for a in "\$@"; do case "\$a" in */jeansh.zip|*/jeansh.tar.gz) echo data > "\$a";; esac; done
''');
  Process.runSync('chmod', ['755', file.path]);
  return file.path;
}

List<String> _argv(Directory dir, String name) =>
    File('${dir.path}/$name.argv').readAsStringSync().split('\n');

List<String> _leftovers(Directory tmp) => tmp
    .listSync()
    .map((e) => e.path.split('/').last)
    .where((n) => n.startsWith('jeansh-zip.'))
    .toList();

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('archive');
    _runner = _sh(_tmp);
  });
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('finding a tool', () {
    test('prefers zip, then 7z, then bsdtar, then tar with gzip', () {
      ArchiveKind? kind(String out) => FolderArchiver.parseProbe(out)?.kind;
      const all =
          'zip=/usr/bin/zip\n7z=/usr/bin/7z\nbsdtar=/usr/bin/bsdtar\n'
          'tar=/bin/tar\ngzip=/bin/gzip\n';
      expect(kind(all), ArchiveKind.zip);
      expect(
        kind(all.replaceFirst('zip=/usr/bin/zip\n', '')),
        ArchiveKind.sevenZip,
      );
      expect(
        kind('7za=/x/7za\ntar=/bin/tar\ngzip=/bin/gzip'),
        ArchiveKind.sevenZip,
      );
      expect(kind('7zz=/x/7zz\n7z=/x/7z'), ArchiveKind.sevenZip);
      expect(
        FolderArchiver.parseProbe('7zz=/x/7zz\n7z=/y/7z')!.binary,
        '/x/7zz',
      );
      expect(kind('bsdtar=/b\ntar=/bin/tar\ngzip=/g'), ArchiveKind.bsdtar);
      final tar = FolderArchiver.parseProbe('tar=/bin/tar\ngzip=/bin/gzip')!;
      expect(tar.kind, ArchiveKind.tarGz);
      expect(tar.extension, '.tar.gz');
      expect(FolderArchiver.parseProbe('zip=/usr/bin/zip')!.extension, '.zip');
    });

    test('tar alone is no tool, and neither is nothing or noise', () {
      expect(FolderArchiver.parseProbe('tar=/bin/tar'), isNull);
      expect(FolderArchiver.parseProbe(''), isNull);
      // A name that is not an absolute path is not believed.
      expect(
        FolderArchiver.parseProbe('zip=zip\nbash: zip: not found'),
        isNull,
      );
    });

    test('the probe finds what is on PATH and runs none of it', () async {
      final bin = Directory('${_tmp.path}/bin')..createSync();
      _stub(bin, 'zip', body: 'touch "${_tmp.path}/RAN"');
      final tool = await FolderArchiver(
        _sh(_tmp, path: '${bin.path}:/bin:/usr/bin'),
      ).findArchiveTool();
      expect(tool?.kind, ArchiveKind.zip);
      expect(tool?.binary, '${bin.path}/zip');
      expect(File('${_tmp.path}/RAN').existsSync(), isFalse);
    });

    test('a host with no archiver says null, not an error', () async {
      final empty = Directory('${_tmp.path}/empty')..createSync();
      // sh itself is found by absolute path; nothing else is on PATH.
      final tool = await FolderArchiver(
        processRunner(
          (script) => Process.start(
            '/bin/sh',
            ['-c', script],
            environment: {'TMPDIR': _tmp.path, 'PATH': empty.path},
            includeParentEnvironment: false,
          ),
        ),
      ).findArchiveTool();
      // $PATH is extended with usual places, so a real tar+gzip may still be
      // found there; what matters is that nothing throws.
      expect(tool == null || tool.kind == ArchiveKind.tarGz, isTrue);
    });
  });

  group('the straggler sweep', () {
    void age(String path) =>
        Process.runSync('touch', ['-t', '202001010000', path]);

    test(
      'removes only this login\'s old real folders under the temp folder',
      () async {
        final old = Directory('${_tmp.path}/jeansh-zip.OLD123')..createSync();
        File('${old.path}/jeansh.zip').writeAsStringSync('x');
        age(old.path);
        final fresh = Directory('${_tmp.path}/jeansh-zip.NEW123')..createSync();
        final other = Directory('${_tmp.path}/other.OLD')..createSync();
        age(other.path);
        final nested = Directory('${_tmp.path}/sub/jeansh-zip.DEEP')
          ..createSync(recursive: true);
        age(nested.path);
        // A link named like ours, to a folder that is old and full of files.
        final victim = Directory('${_tmp.path}/victim')..createSync();
        File('${victim.path}/precious').writeAsStringSync('keep');
        age(victim.path);
        Link('${_tmp.path}/jeansh-zip.LINK').createSync(victim.path);
        // A plain file named like ours.
        final file = File('${_tmp.path}/jeansh-zip.FILE')
          ..writeAsStringSync('x');
        age(file.path);

        final result = await _runner(FolderArchiver.sweepScript);
        expect(result.exitCode, 0);

        expect(old.existsSync(), isFalse, reason: 'old and ours: swept');
        expect(fresh.existsSync(), isTrue, reason: 'in use');
        expect(other.existsSync(), isTrue, reason: 'not our prefix');
        expect(nested.existsSync(), isTrue, reason: 'only directly under tmp');
        expect(File('${victim.path}/precious').existsSync(), isTrue);
        expect(Link('${_tmp.path}/jeansh-zip.LINK').existsSync(), isTrue);
        expect(file.existsSync(), isTrue, reason: 'not a folder');
      },
    );
  });

  group('archiving', () {
    Directory tree() {
      final root = Directory('${_tmp.path}/src')..createSync();
      return root;
    }

    test('splits a folder into where it is and what it is called', () {
      expect(FolderArchiver.split('/home/me/dev'), ('/home/me', 'dev'));
      expect(FolderArchiver.split('/home/me/dev/'), ('/home/me', 'dev'));
      expect(FolderArchiver.split('/dev'), ('/', 'dev'));
      expect(FolderArchiver.split('/'), isNull);
      expect(FolderArchiver.split('/a/..'), isNull);
    });

    test('refuses the root, so nothing is run', () async {
      await expectLater(
        FolderArchiver(_runner).archiveFolder(
          '/',
          const ArchiveTool(ArchiveKind.zip, '/usr/bin/zip'),
        ),
        throwsA(isA<FileBrowserException>()),
      );
    });

    for (final kind in ArchiveKind.values) {
      test(
        '${kind.name}: a name is one argument and never a command',
        () async {
          final src = tree();
          final bin = Directory('${_tmp.path}/bin')..createSync();
          final stub = _stub(bin, 'tool');
          final tool = ArchiveTool(kind, stub);
          final archiver = FolderArchiver(_runner);
          for (final name in _evil) {
            final dir = Directory('${src.path}/$name')..createSync();
            File('${dir.path}/f').writeAsStringSync('x');
            final made = await archiver.archiveFolder(dir.path, tool);
            expect(made.path, matches(RegExp(r'/jeansh-zip\.\w+/jeansh\.')));
            final argv = _argv(bin, 'tool');
            expect(
              argv.join('\n'),
              contains('./$name'),
              reason: 'the name arrives whole, behind ./',
            );
            expect(argv, isNot(contains(name)), reason: 'never bare');
            await archiver.removeArchive(made.path);
          }
          // Nothing a name said ran.
          for (final file in src.listSync(recursive: true)) {
            expect(file.path.split('/').last, isNot(startsWith('pwned')));
          }
          expect(
            Directory(_tmp.path)
                .listSync(recursive: true)
                .where((e) => e.path.split('/').last.startsWith('pwned')),
            isEmpty,
          );
          expect(_leftovers(_tmp), isEmpty);
        },
      );
    }

    test('the commands, tool by tool', () async {
      final src = tree();
      final bin = Directory('${_tmp.path}/bin')..createSync();
      Directory('${src.path}/d').createSync();
      for (final (kind, must) in [
        (ArchiveKind.zip, ['-qry', '-nw']),
        (ArchiveKind.sevenZip, ['a', '-tzip', '-spd', '-snl', '--']),
        (ArchiveKind.bsdtar, ['--format', 'zip', '-cf', '--']),
        (ArchiveKind.tarGz, ['-czf', '--']),
      ]) {
        final stub = _stub(bin, 'tool');
        final made = await FolderArchiver(_runner)
            .archiveFolder('${src.path}/d', ArchiveTool(kind, stub));
        expect(_argv(bin, 'tool'), containsAll(must));
        expect(
          made.path.endsWith(kind == ArchiveKind.tarGz ? '.tar.gz' : '.zip'),
          isTrue,
        );
        await FolderArchiver(_runner).removeArchive(made.path);
      }
    });

    test('a real tar.gz holds the folder, spaces and quotes and all', () async {
      final src = tree();
      final dir = Directory("${src.path}/it's \$(x) here")..createSync();
      File('${dir.path}/a b.txt').writeAsStringSync('hello');
      final archiver = FolderArchiver(_runner);
      final made = await archiver.archiveFolder(
        dir.path,
        const ArchiveTool(ArchiveKind.tarGz, '/bin/tar'),
      );
      expect(made.size, greaterThan(0));
      expect(File(made.path).statSync().mode & 0x1ff, 0x180, reason: '0600');
      expect(
        Directory(File(made.path).parent.path).statSync().mode & 0x1ff,
        0x1c0,
        reason: '0700',
      );
      final list = Process.runSync('tar', ['-tzf', made.path]).stdout as String;
      expect(list, contains("it's \$(x) here/a b.txt"));
      await archiver.removeArchive(made.path);
      expect(_leftovers(_tmp), isEmpty);
    });

    test(
      'a failing tool is said with what it printed, and leaves nothing',
      () async {
        final src = tree();
        Directory('${src.path}/d').createSync();
        final bin = Directory('${_tmp.path}/bin')..createSync();
        final stub = _stub(
          bin,
          'tool',
          body: 'echo "zip I/O error: No space left on device" >&2; exit 15',
        );
        await expectLater(
          FolderArchiver(
            _runner,
          ).archiveFolder('${src.path}/d', ArchiveTool(ArchiveKind.zip, stub)),
          throwsA(
            isA<FileBrowserException>().having(
              (e) => e.message,
              'message',
              allOf(contains('exit 15'), contains('No space left on device')),
            ),
          ),
        );
        expect(_leftovers(_tmp), isEmpty);
      },
    );

    test(
      'a zero exit with an empty archive is an error, not a success',
      () async {
        final src = tree();
        Directory('${src.path}/d').createSync();
        final bin = Directory('${_tmp.path}/bin')..createSync();
        // Exits 0 and writes nothing.
        final file = File('${bin.path}/tool')
          ..writeAsStringSync('#!/bin/sh\nexit 0\n');
        Process.runSync('chmod', ['755', file.path]);
        await expectLater(
          FolderArchiver(_runner).archiveFolder(
            '${src.path}/d',
            ArchiveTool(ArchiveKind.zip, file.path),
          ),
          throwsA(
            isA<FileBrowserException>().having(
              (e) => e.message,
              'message',
              contains('came out empty'),
            ),
          ),
        );
        expect(_leftovers(_tmp), isEmpty);
      },
    );

    test('a folder that is gone is an error', () async {
      await expectLater(
        FolderArchiver(_runner).archiveFolder(
          '${_tmp.path}/nope/d',
          const ArchiveTool(ArchiveKind.tarGz, '/bin/tar'),
        ),
        throwsA(isA<FileBrowserException>()),
      );
      expect(_leftovers(_tmp), isEmpty);
    });

    test('cancel stops the tool and removes the archive folder', () async {
      final src = tree();
      Directory('${src.path}/d').createSync();
      final bin = Directory('${_tmp.path}/bin')..createSync();
      final pidFile = '${_tmp.path}/pid';
      final stub = File('${bin.path}/tool')
        ..writeAsStringSync(
          '#!/bin/sh\necho \$\$ > "$pidFile"\nexec sleep 30\n',
        );
      Process.runSync('chmod', ['755', stub.path]);
      final cancel = Completer<void>();
      final run = FolderArchiver(_runner).archiveFolder(
        '${src.path}/d',
        ArchiveTool(ArchiveKind.zip, stub.path),
        cancel: cancel.future,
      );
      final expectation = expectLater(
        run,
        throwsA(
          isA<FileBrowserException>().having(
            (e) => e.fault,
            'fault',
            FileBrowserFault.cancelled,
          ),
        ),
      );
      for (var i = 0; i < 50 && !File(pidFile).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(_leftovers(_tmp), hasLength(1), reason: 'being made');
      final pid = int.parse(File(pidFile).readAsStringSync().trim());
      cancel.complete();
      await expectation;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_leftovers(_tmp), isEmpty);
      expect(
        Process.runSync('kill', ['-0', '$pid']).exitCode,
        isNot(0),
        reason: 'the tool is dead',
      );
    });
  });

  group('removing', () {
    test('only an archive folder of ours, by its exact shape', () {
      expect(
        FolderArchiver.removeScript('/tmp/jeansh-zip.abc123/jeansh.zip'),
        "rm -rf -- '/tmp/jeansh-zip.abc123'",
      );
      expect(
        FolderArchiver.removeScript('/tmp/jeansh-zip.abc123/jeansh.tar.gz'),
        isNotNull,
      );
      for (final bad in [
        '/tmp',
        '/',
        '/home/me/important.zip',
        '/tmp/jeansh-zip.abc/../../etc/jeansh.zip',
        '/tmp/jeansh-zip.a b/jeansh.zip',
        r'/tmp/jeansh-zip.$(x)/jeansh.zip',
        '/tmp/jeansh-zip.abc/other.zip',
        'jeansh-zip.abc/jeansh.zip',
      ]) {
        expect(FolderArchiver.removeScript(bad), isNull, reason: bad);
      }
    });

    test('a bad path removes nothing', () async {
      final keep = Directory('${_tmp.path}/keep')..createSync();
      await FolderArchiver(_runner).removeArchive('${keep.path}/jeansh.zip');
      expect(keep.existsSync(), isTrue);
    });
  });

  test('one line of what a tool said is short and has no control bytes', () {
    final said = FolderArchiver.oneLine('a\x1b[31m\n\nb\nc\nd\ne\n');
    expect(said, 'c · d · e');
    expect(said.contains('\x1b'), isFalse);
    expect(FolderArchiver.oneLine('x' * 1000).length, lessThanOrEqualTo(301));
  });
}
