import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';
import 'package:sshbox/src/session/open_command.dart';
import 'package:sshbox/src/session/open_request.dart';

String _b64(String s) => base64.encode(utf8.encode(s));

var _nonces = 0;

/// What the script writes: the secret, the time, a nonce and the path.
String _osc(
  String secret,
  String path, {
  required DateTime at,
  String? nonce,
}) =>
    '\x1b]7733;open;$secret;${at.millisecondsSinceEpoch ~/ 1000};'
    '${nonce ?? (0x10000000 + _nonces++).toRadixString(16)};${_b64(path)}\x07';

void main() {
  late List<String> opened;
  late int refused;
  late List<(int, String)> dropped;
  late OpenRequests requests;
  late ClipboardTerminal terminal;
  var clock = DateTime(2026);

  setUp(() {
    opened = [];
    refused = 0;
    dropped = [];
    clock = DateTime(2026);
    requests = OpenRequests(
      onOpen: opened.add,
      onRefused: () => refused++,
      onDropped: (count, why) => dropped.add((count, why)),
      secret: 'sek-ret',
      clockOffset: 0,
      now: () => clock,
    );
    addTearDown(requests.dispose);
    terminal = ClipboardTerminal(
      onPrivateOSC: (code, args) => requests.handle(code, args),
    );
  });

  String osc(String secret, String path, {String? nonce, DateTime? at}) =>
      _osc(secret, path, at: at ?? clock, nonce: nonce);

  test('the right secret opens the path', () {
    terminal.write('a${osc('sek-ret', '/home/me/notes.md')}b');
    expect(opened, ['/home/me/notes.md']);
    expect(terminal.buffer.lines[0].getText().trimRight(), 'ab');
  });

  test('a wrong, missing or empty secret opens nothing', () {
    terminal.write(osc('sek-reT', '/etc/passwd'));
    terminal.write(osc('', '/etc/passwd'));
    terminal.write(osc('sek-ret-and-more', '/etc/passwd'));
    terminal.write('\x1b]7733;open;${_b64('/etc/passwd')}\x07');
    requests.secret = null;
    terminal.write(osc('sek-ret', '/etc/passwd'));
    expect(opened, isEmpty);
  });

  test('a path with a control character, or not absolute, is refused', () {
    for (final path in [
      'relative.txt',
      '/a\nb',
      '/a\x1bb',
      '/a\x7fb',
      '/a\u0085b',
      '/a\u202eb',
      '/a\u200fb',
      '/a\u2067b',
      '',
      '/${'x' * 5000}',
    ]) {
      terminal.write(osc('sek-ret', path));
    }
    terminal.write('\x1b]7733;open;sek-ret;1;abcdef012;not base64!\x07');
    expect(opened, isEmpty);
  });

  test('a replayed sequence opens nothing, once', () {
    final once = osc('sek-ret', '/srv/a.md', nonce: 'deadbeef01');
    terminal.write(once);
    terminal.write(once);
    clock = clock.add(const Duration(seconds: 30));
    terminal.write(once);
    expect(opened, ['/srv/a.md']);
  });

  test('a sequence opens once per host: a second tab on the same host, '
      'sharing its ring, does not open it again', () {
    final ring = OpenSecretRing(['sek-ret']);
    OpenRequests tab() => OpenRequests(
      onOpen: opened.add,
      ring: ring,
      clockOffset: 0,
      now: () => clock,
    );
    final once = osc('sek-ret', '/srv/a.md', nonce: 'deadbeef02');
    ClipboardTerminal(onPrivateOSC: tab().handle).write(once);
    ClipboardTerminal(onPrivateOSC: tab().handle).write(once);
    expect(opened, ['/srv/a.md']);
    // A fresh nonce in the second tab still opens.
    ClipboardTerminal(onPrivateOSC: tab().handle)
        .write(osc('sek-ret', '/srv/b.md'));
    expect(opened, ['/srv/a.md', '/srv/b.md']);
  });

  test('a stale or future time opens nothing', () {
    terminal.write(
      osc('sek-ret', '/old', at: clock.subtract(const Duration(minutes: 3))),
    );
    terminal.write(
      osc('sek-ret', '/future', at: clock.add(const Duration(minutes: 3))),
    );
    expect(opened, isEmpty);
    terminal.write(
      osc(
        'sek-ret',
        '/fresh',
        at: clock.subtract(const Duration(seconds: 100)),
      ),
    );
    expect(opened, ['/fresh']);
  });

  test('a host clock ten minutes off works once its offset is known', () {
    final host = clock.add(const Duration(minutes: 10));
    terminal.write(osc('sek-ret', '/skewed', at: host));
    expect(opened, isEmpty);
    requests.clockOffset = 600;
    terminal.write(osc('sek-ret', '/skewed', at: host));
    expect(opened, ['/skewed']);
  });

  test('with no offset measured, a nonce still opens only once', () {
    requests.clockOffset = null;
    final old = osc(
      'sek-ret',
      '/x',
      at: clock.subtract(const Duration(hours: 2)),
      nonce: 'cafe0123',
    );
    terminal.write(old);
    terminal.write(old);
    expect(opened, ['/x']);
  });

  test('with no offset measured, a time over a day off is still refused', () {
    requests.clockOffset = null;
    terminal.write(
      osc('sek-ret', '/old', at: clock.subtract(const Duration(days: 2))),
    );
    terminal.write(
      osc('sek-ret', '/future', at: clock.add(const Duration(days: 2))),
    );
    expect(opened, isEmpty);
  });

  test('a refused request says so at most every ten seconds, and only for '
      'the command\'s own shape', () {
    terminal.write(osc('wrong', '/a'));
    terminal.write(osc('wrong', '/b'));
    terminal.write('\x1b]7733;something;else\x07');
    terminal.write('\x1b]7733;open;wrong\x07');
    expect(refused, 1);
    clock = clock.add(OpenRequests.refusedEvery);
    terminal.write(osc('wrong', '/c'));
    expect(refused, 2);
  });

  test('a burst is bounded, and the allowance comes back', () {
    for (var i = 0; i < 9; i++) {
      terminal.write(osc('sek-ret', '/f$i'));
    }
    expect(opened, hasLength(OpenRequests.burst));
    clock = clock.add(OpenRequests.burstWindow);
    terminal.write(osc('sek-ret', '/later'));
    expect(opened.last, '/later');
  });

  test('what the app cannot take is said, with how many and why, never '
      'dropped quietly', () {
    for (var i = 0; i < 7; i++) {
      terminal.write(osc('sek-ret', '/f$i'));
    }
    expect(opened, hasLength(OpenRequests.burst));
    // The first of the two over the limit is said at once, the second joins
    // the next word.
    expect(dropped, [(1, 'more than 5 files at a time')]);
    clock = clock.add(OpenRequests.burstWindow);
    for (var i = 7; i < 13; i++) {
      terminal.write(osc('sek-ret', '/f$i'));
    }
    expect(dropped.last, (2, 'more than 5 files at a time'));

    // A path that is no UTF-8, one that is too long and one with a control
    // character are said, each with its own reason.
    clock = clock.add(const Duration(seconds: 3));
    terminal.write(
      '\x1b]7733;open;sek-ret;${clock.millisecondsSinceEpoch ~/ 1000};'
      '${(0x30000000).toRadixString(16)};${base64.encode([0x2f, 0xff, 0xfe])}'
      '\x07',
    );
    expect(dropped.last, (1, 'the name is not valid UTF-8'));
    clock = clock.add(const Duration(seconds: 3));
    terminal.write(osc('sek-ret', '/${'a' * OpenRequests.maxPath}'));
    expect(dropped.last, (1, 'the path is longer than 4096 bytes'));
    clock = clock.add(const Duration(seconds: 3));
    terminal.write(osc('sek-ret', '/a\x01b'));
    expect(dropped.last, (1, 'the name holds a control character'));
    // A wrong secret is a refusal, not a drop.
    final before = dropped.length;
    terminal.write(osc('wrong', '/x'));
    expect(dropped, hasLength(before));
  });

  test('drops held back by the two-second spacing are said when it ends, '
      'with no later drop needed', () async {
    for (var i = 0; i < 7; i++) {
      terminal.write(osc('sek-ret', '/f$i'));
    }
    expect(dropped, [(1, 'more than 5 files at a time')]);
    await Future<void>.delayed(
      OpenRequests.droppedEvery + const Duration(milliseconds: 200),
    );
    expect(dropped, [
      (1, 'more than 5 files at a time'),
      (1, 'more than 5 files at a time'),
    ]);
    // Nothing held, nothing more said.
    await Future<void>.delayed(
      OpenRequests.droppedEvery + const Duration(milliseconds: 200),
    );
    expect(dropped, hasLength(2));
    requests.dispose();
  });

  test('a held drop is not said after the requests are disposed', () async {
    for (var i = 0; i < 7; i++) {
      terminal.write(osc('sek-ret', '/f$i'));
    }
    requests.dispose();
    await Future<void>.delayed(
      OpenRequests.droppedEvery + const Duration(milliseconds: 200),
    );
    expect(dropped, hasLength(1));
  });

  test('every secret of the newest four counts, an older one does not, and '
      'one is no use to a host that never made it', () {
    final ring = OpenSecretRing();
    final made = [for (var i = 0; i < 5; i++) ring.issue()];
    final both = OpenRequests(
      onOpen: opened.add,
      ring: ring,
      clockOffset: 0,
      now: () => clock,
    );
    final t = ClipboardTerminal(onPrivateOSC: both.handle);
    t.write(osc(made[0], '/oldest'));
    expect(opened, isEmpty);
    for (var i = 1; i < 5; i++) {
      t.write(osc(made[i], '/live$i'));
    }
    expect(opened, ['/live1', '/live2', '/live3', '/live4']);
    expect(ring.newest, made.last);
    // Another host's ring has none of them.
    final other = OpenRequests(
      onOpen: opened.add,
      ring: OpenSecretRing(),
      clockOffset: 0,
      now: () => clock,
    );
    ClipboardTerminal(onPrivateOSC: other.handle)
        .write(osc(made.last, '/other'));
    expect(opened, hasLength(4));
  });

  test('the ring is empty until a secret is made, takes one by hand and can '
      'be emptied, and a path decodes to itself or to nothing', () {
    final ring = OpenSecretRing();
    expect(ring.isEmpty, isTrue);
    expect(ring.newest, isNull);
    final r = OpenRequests(onOpen: opened.add, ring: ring, now: () => clock);
    r.secret = 'by-hand';
    expect(ring.isEmpty, isFalse);
    expect(ring.accepts('by-hand'), isTrue);
    r.secret = null;
    expect(ring.isEmpty, isTrue);
    expect(ring.accepts('by-hand'), isFalse);
    expect(OpenRequests.decodePath(_b64('/a/b')), '/a/b');
    expect(OpenRequests.decodePath(_b64('relative')), isNull);
    expect(OpenRequests.decodePath('!!!'), isNull);
  });

  test('constantTimeEquals agrees with ==', () {
    expect(OpenRequests.constantTimeEquals('abc', 'abc'), isTrue);
    expect(OpenRequests.constantTimeEquals('abc', 'abd'), isFalse);
    expect(OpenRequests.constantTimeEquals('abc', 'abcd'), isFalse);
    expect(OpenRequests.constantTimeEquals('', ''), isTrue);
    expect(OpenRequests.constantTimeEquals('a', ''), isFalse);
  });

  test(
    'the remote install writes new, renames in, and leaves others alone',
    () {
      final home = Directory.systemTemp.createTempSync('jeansh-home');
      addTearDown(() => home.deleteSync(recursive: true));
      String run([String secret = 'sek-ret', String key = '-']) =>
          (Process.runSync(
                    'sh',
                    [
                      '-c',
                      r'printf "%s\n%s\n" "$1" "$2" | ' +
                          openCommandInstallScript(),
                      'sh',
                      secret,
                      key,
                    ],
                    environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
                    includeParentEnvironment: false,
                  ).stdout
                  as String)
              .trim();
      final target = '${home.path}/.local/bin/jeansh';

      expect(run(), 'installed');
      expect(File(target).readAsStringSync(), openCommandScript);
      expect(File(target).statSync().mode & 0x1ed, 0x1ed); // 0755
      expect(run(), 'current');
      expect(Directory('${home.path}/.local/bin').listSync(), hasLength(1));

      // Each connect's secret goes in the private file, replacing the last,
      // even when the command itself is current; nothing is left beside it.
      final secretFile = File('${home.path}/.config/jeansh/open-secret');
      expect(secretFile.readAsStringSync(), 'sek-ret\n');
      expect(secretFile.statSync().mode & 0x1ff, 0x180); // 0600
      expect(
        Directory('${home.path}/.config/jeansh').statSync().mode & 0x1ff,
        0x1c0, // 0700
      );
      expect(run('next-one'), 'current');
      expect(secretFile.readAsStringSync(), 'next-one\n');
      // Nothing on stdin, or something that is no secret, writes nothing.
      expect(run(''), '');
      expect(run('not a secret!'), '');
      expect(secretFile.readAsStringSync(), 'next-one\n');
      expect(Directory('${home.path}/.config/jeansh').listSync(), hasLength(1));
      // A link in the file's place is replaced, never written through.
      secretFile.deleteSync();
      File('${home.path}/victim0').writeAsStringSync('keep');
      Link(secretFile.path).createSync('${home.path}/victim0');
      expect(run('after-link'), 'current');
      expect(File('${home.path}/victim0').readAsStringSync(), 'keep');
      expect(secretFile.readAsStringSync(), 'after-link\n');
      // A link at the folder is refused, and said.
      Process.runSync('rm', ['-rf', '${home.path}/.config/jeansh']);
      Directory('${home.path}/elsewhere').createSync();
      Link('${home.path}/.config/jeansh').createSync('${home.path}/elsewhere');
      expect(run('refused'), 'secret folder is a link');
      expect(Directory('${home.path}/elsewhere').listSync(), isEmpty);
      Link('${home.path}/.config/jeansh').deleteSync();

      File(target).writeAsStringSync('#!/bin/sh\n$openCommandMarker\nold\n');
      expect(run(), 'installed');
      expect(File(target).readAsStringSync(), openCommandScript);

      File(target).writeAsStringSync('#!/bin/sh\necho mine\n');
      expect(run(), 'left alone');
      expect(File(target).readAsStringSync(), contains('mine'));

      File(target).deleteSync();
      File('${home.path}/victim').writeAsStringSync('keep');
      Link(target).createSync('${home.path}/victim');
      expect(run(), 'left alone');
      expect(File('${home.path}/victim').readAsStringSync(), 'keep');

      // A link at the name is left alone even when what it points at is
      // Jeansh's own.
      File('${home.path}/own').writeAsStringSync(openCommandScript);
      Link(target).deleteSync();
      Link(target).createSync('${home.path}/own');
      expect(run(), 'left alone');
      expect(Link(target).targetSync(), '${home.path}/own');

      // A link planted at a temp name is never followed: its target keeps its
      // mode, and the install still goes in.
      Link(target).deleteSync();
      Process.runSync('rm', ['-f', target]);
      File('${home.path}/secret').writeAsStringSync('mine');
      Process.runSync('chmod', ['600', '${home.path}/secret']);
      for (final name in [
        'jeansh.1234.new',
        'jeansh.XXXXXX',
        'jeansh.aaaaaa',
      ]) {
        Link('${home.path}/.local/bin/$name').createSync('${home.path}/secret');
      }
      expect(run(), 'installed');
      expect(
        File('${home.path}/secret').statSync().mode & 0x1ff,
        0x180,
      ); // 0600
      expect(File('${home.path}/secret').readAsStringSync(), 'mine');
      expect(File(target).readAsStringSync(), openCommandScript);
      File(target).deleteSync();

      // A FIFO is not read, which would hang: left alone.
      Process.runSync('mkfifo', [target]);
      expect(run(), 'left alone');
    },
  );

  test('the Settings switch installs into ~/.local/bin, and only its own', () async {
    SharedPreferences.setMockInitialValues({});
    final home = Directory.systemTemp.createTempSync('jeansh-sw');
    addTearDown(() => home.deleteSync(recursive: true));
    final setting = LocalOpenCommandSetting(home: home.path);
    final target = File('${home.path}/.local/bin/jeansh');

    expect(setting.value, installOpenCommandDefault);
    expect(await setting.choose(true), isNull);
    expect(target.readAsStringSync(), openCommandScript);
    expect(target.statSync().mode & 0x1ed, 0x1ed); // 0755
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'sshbox.terminal.localOpenCommand',
      ),
      isTrue,
    );

    // Somebody else's file, and a link, are left alone and the switch says so.
    target.writeAsStringSync('#!/bin/sh\necho mine\n');
    expect(await setting.choose(true), isNotNull);
    expect(target.readAsStringSync(), contains('mine'));
    target.deleteSync();
    File('${home.path}/victim').writeAsStringSync('keep');
    Link(target.path).createSync('${home.path}/victim');
    expect(await setting.choose(true), isNotNull);
    expect(File('${home.path}/victim').readAsStringSync(), 'keep');

    // Off writes nothing, and is saved.
    expect(await setting.choose(false), isNull);
    expect(setting.value, isFalse);
  });

  group('the jeansh script, run through a real sh', () {
    late Directory dir;
    late File tty;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('jeansh-open');
      tty = File('${dir.path}/tty')..createSync();
      installOpenCommand('${dir.path}/bin');
      writeOpenSecret(dir.path, 'sek-ret');
      File('${dir.path}/a b\'s.txt').writeAsStringSync('x');
      Directory('${dir.path}/folder').createSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ProcessResult run(List<String> args, {String? envSecret}) =>
        Process.runSync(
          'sh',
          ['${dir.path}/bin/jeansh', ...args],
          workingDirectory: dir.path,
          environment: {
            'JEANSH_TTY': tty.path,
            'HOME': dir.path,
            'LC_SSHBOX_OPEN_SECRET': ?envSecret,
          },
          includeParentEnvironment: false,
        );

    test('writes the sequence, for each file that is there', () {
      final result = run([
        'a b\'s.txt',
        'missing',
        'folder',
        '/dev/zero',
        './a b\'s.txt',
      ]);
      final real = dir.resolveSymbolicLinksSync();
      final written = tty.readAsStringSync();
      final pattern = RegExp(
        '\x1b\\]7733;open;sek-ret;(\\d{10});([0-9a-f]{16});'
        '${RegExp.escape(_b64('$real/a b\'s.txt'))}\x07',
      );
      final both = pattern.allMatches(written).toList();
      expect(both, hasLength(2));
      expect(written, '${both[0][0]}${both[1][0]}');
      // A fresh time near now, and a nonce of its own every time.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((int.parse(both[0][1]!) - now).abs(), lessThan(60));
      expect(both[0][2], isNot(both[1][2]));
      expect(result.exitCode, 1);
      expect(result.stderr, contains('missing: no such file'));
      expect(result.stderr, contains('folder: is a folder'));
      expect(result.stderr, contains('/dev/zero: is not a regular file'));
      // And the app takes what it wrote, each once.
      final seen = <String>[];
      final requests = OpenRequests(
        onOpen: seen.add,
        secret: 'sek-ret',
        clockOffset: 0,
      );
      final terminal = ClipboardTerminal(onPrivateOSC: requests.handle);
      terminal.write(written);
      expect(seen, ['$real/a b\'s.txt', '$real/a b\'s.txt']);
      terminal.write(written);
      expect(seen, hasLength(2));
    });

    test('says so, and writes nothing, with no secret file', () {
      File('${dir.path}/.config/jeansh/open-secret').deleteSync();
      final result = run(['a b\'s.txt']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('not running in a Jeansh terminal'));
      expect(tty.readAsStringSync(), isEmpty);
      expect(run([]).exitCode, 2);
    });

    test('a secret in the environment alone is not taken: an ssh from this '
        'shell would pass it on', () {
      File('${dir.path}/.config/jeansh/open-secret').deleteSync();
      final result = run(['a b\'s.txt'], envSecret: 'sek-ret');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('not running in a Jeansh terminal'));
      expect(tty.readAsStringSync(), isEmpty);
      // And with the file there, the file's secret is the one written.
      writeOpenSecret(dir.path, 'from-file');
      expect(run(['a b\'s.txt'], envSecret: 'from-env').exitCode, 0);
      expect(tty.readAsStringSync(), contains(';from-file;'));
      expect(tty.readAsStringSync(), isNot(contains('from-env')));
    });

    test('a secret file that is a link, or not the user\'s, is not read', () {
      final file = File('${dir.path}/.config/jeansh/open-secret')..deleteSync();
      File('${dir.path}/elsewhere').writeAsStringSync('sek-ret\n');
      Link(file.path).createSync('${dir.path}/elsewhere');
      expect(run(['a b\'s.txt']).exitCode, 1);
      expect(tty.readAsStringSync(), isEmpty);
    });

    test('files the app would drop are said, with a non-zero exit', () {
      for (var i = 0; i < 7; i++) {
        File('${dir.path}/f$i').writeAsStringSync('x');
      }
      final result = run([for (var i = 0; i < 7; i++) 'f$i']);
      expect(
        '\x07'.allMatches(tty.readAsStringSync()),
        hasLength(openMostFiles),
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains('f5: not opened, at most 5 files'));
      expect(result.stderr, contains('f6: not opened, at most 5 files'));
      expect(result.stderr, contains('2 of 7 not opened'));

      // A name that is not UTF-8, where iconv is there to tell (musl's takes
      // any bytes).
      if (Process.runSync('sh', [
            '-c',
            r'printf "\377" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1',
          ]).exitCode !=
          0) {
        tty.writeAsStringSync('');
        // Made and passed by the shell, Dart's own arguments being UTF-8.
        final bad = Process.runSync(
          'sh',
          ['-c', r'n=$(printf "b\377d"); printf x > "$n"; sh bin/jeansh "$n"'],
          workingDirectory: dir.path,
          environment: {'JEANSH_TTY': tty.path, 'HOME': dir.path},
          includeParentEnvironment: false,
          stdoutEncoding: latin1,
          stderrEncoding: latin1,
        );
        expect(bad.exitCode, 1);
        expect(bad.stderr, contains('not valid UTF-8'));
        expect(tty.readAsStringSync(), isEmpty);
      }
    });

    test('the secret file is private, rewritten each time, and never '
        'through a link', () {
      final folder = Directory('${dir.path}/.config/jeansh');
      final file = File('${folder.path}/open-secret');
      expect(file.statSync().mode & 0x1ff, 0x180); // 0600
      expect(folder.statSync().mode & 0x1ff, 0x1c0); // 0700
      writeOpenSecret(dir.path, 'second');
      expect(file.readAsStringSync(), 'second\n');
      expect(folder.listSync(), hasLength(1));

      // A link in the file's place is replaced, never written through.
      file.deleteSync();
      File('${dir.path}/victim').writeAsStringSync('keep');
      Link(file.path).createSync('${dir.path}/victim');
      writeOpenSecret(dir.path, 'third');
      expect(File('${dir.path}/victim').readAsStringSync(), 'keep');
      expect(file.readAsStringSync(), 'third\n');

      // A link at the folder is refused, loudly.
      Process.runSync('rm', ['-rf', folder.path]);
      Directory('${dir.path}/elsewhere').createSync();
      Link(folder.path).createSync('${dir.path}/elsewhere');
      expect(
        () => writeOpenSecret(dir.path, 'fourth'),
        throwsA(
          isA<OpenInstallException>().having(
            (e) => e.message,
            'message',
            contains('is a link'),
          ),
        ),
      );
      expect(Directory('${dir.path}/elsewhere').listSync(), isEmpty);
    });

    group(
      'every way the local install can fail is an error that says what',
      () {
        final real = runChmod;
        tearDown(() => runChmod = real);

        Matcher failsWith(String text) => throwsA(
          isA<OpenInstallException>().having(
            (e) => e.message,
            'message',
            contains(text),
          ),
        );

        test('chmod cannot run, for the command and for the secret', () {
          runChmod = (_) => throw const ProcessException('chmod', [], 'gone');
          expect(
            () => installOpenCommand('${dir.path}/b1'),
            failsWith('executable: gone'),
          );
          expect(Directory('${dir.path}/b1').listSync(), isEmpty);
          expect(
            () => writeOpenSecret('${dir.path}/h3', 'x'),
            failsWith('private: gone'),
          );
        });

        test('a write fails with no OS message, and the failure still names '
            'the file', () {
          runChmod = (_) => throw const FileSystemException('boom');
          expect(
            () => installOpenCommand('${dir.path}/b2'),
            failsWith('Could not write ${dir.path}/b2/jeansh: boom.'),
          );
          expect(Directory('${dir.path}/b2').listSync(), isEmpty);
        });

        test('a temp file that is already gone is no second error', () {
          runChmod = (args) {
            File(args[1]).deleteSync();
            return ProcessResult(0, 1, '', '');
          };
          expect(
            () => installOpenCommand('${dir.path}/b4'),
            failsWith('chmod failed'),
          );
        });

        test('the secret folder cannot be made or made private', () {
          // ~/.config is a file, so nothing can be made under it.
          final h = Directory('${dir.path}/h4')..createSync();
          File('${h.path}/.config').writeAsStringSync('a file');
          expect(
            () => writeOpenSecret(h.path, 'x'),
            failsWith('Could not write the key for the jeansh command'),
          );
          // chmod of the folder refuses; the file's own chmod is not reached.
          runChmod = (_) => ProcessResult(0, 1, '', '');
          expect(
            () => writeOpenSecret('${dir.path}/h5', 'x'),
            failsWith('private: chmod failed'),
          );
          expect(
            File('${dir.path}/h5/.config/jeansh/open-secret').existsSync(),
            isFalse,
          );
        });
      },
    );

    test('a chmod that fails is an error, and leaves no .new behind', () {
      final bin = '${dir.path}/bin3';
      final real = runChmod;
      addTearDown(() => runChmod = real);
      runChmod = (_) => ProcessResult(0, 1, '', 'Operation not permitted');
      expect(
        () => installOpenCommand(bin),
        throwsA(
          isA<OpenInstallException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('chmod failed'),
              contains('Operation not permitted'),
            ),
          ),
        ),
      );
      expect(Directory(bin).listSync(), isEmpty);
      expect(File('$bin/jeansh').existsSync(), isFalse);
      // The secret's file the same: a failed chmod never leaves it readable.
      expect(
        () => writeOpenSecret('${dir.path}/h2', 'x'),
        throwsA(isA<OpenInstallException>()),
      );
      expect(Directory('${dir.path}/h2/.config/jeansh').listSync(), isEmpty);
    });

    test('the install words a failure as one, and leaves no .new', () {
      final bin = '${dir.path}/bin2';
      // A folder that cannot be written: said as a failure, not as "not the
      // app's own".
      Directory(bin).createSync();
      Process.runSync('chmod', ['555', bin]);
      addTearDown(() => Process.runSync('chmod', ['755', bin]));
      if (Process.runSync('id', ['-u']).stdout.toString().trim() != '0') {
        expect(
          () => installOpenCommand(bin),
          throwsA(
            isA<OpenInstallException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Could not write'),
                isNot(contains('not the app')),
              ),
            ),
          ),
        );
      }
      Process.runSync('chmod', ['755', bin]);
      expect(Directory(bin).listSync(), isEmpty);

      // The settings path words it the same way.
      final home = Directory('${dir.path}/home')..createSync();
      Directory('${home.path}/.local').createSync();
      File('${home.path}/.local/bin').writeAsStringSync('a file, not a folder');
      final problem = installOpenCommandInHome(home.path);
      expect(problem, contains('Could not write'));
      expect(installOpenCommandInHome(''), contains('no home folder'));
    });

    test(
      'install is new-then-rename, and never touches a file not its own',
      () {
        final bin = '${dir.path}/bin';
        expect(File('$bin/jeansh').readAsStringSync(), openCommandScript);
        expect(File('$bin/jeansh').statSync().mode & 0x49, 0x49);
        // A planted link is replaced, not written through.
        File('${dir.path}/victim').writeAsStringSync('keep');
        File('$bin/jeansh').deleteSync();
        Link('$bin/jeansh').createSync('${dir.path}/victim');
        expect(
          () => installOpenCommand(bin),
          throwsA(isA<FileSystemException>()),
        );
        expect(File('${dir.path}/victim').readAsStringSync(), 'keep');
        // Somebody else's file stays.
        Link('$bin/jeansh').deleteSync();
        File('$bin/jeansh').writeAsStringSync('#!/bin/sh\necho mine\n');
        expect(
          () => installOpenCommand(bin),
          throwsA(isA<FileSystemException>()),
        );
        expect(File('$bin/jeansh').readAsStringSync(), contains('mine'));
        // An older copy of its own is brought up to date.
        File('$bin/jeansh')
            .writeAsStringSync('#!/bin/sh\n$openCommandMarker\nold\n');
        installOpenCommand(bin);
        expect(File('$bin/jeansh').readAsStringSync(), openCommandScript);
      },
    );
  });

  group("the host's push key is a file", () {
    const key =
        'jnk_abcDEF0123456789abcdef0123456789:MIGHAgEAMBMGByqGSM49+/AgEGCCqGSM49=';
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('jeansh-key'));
    tearDown(() => home.deleteSync(recursive: true));

    String install(String secret, String key) =>
        (Process.runSync(
                  'sh',
                  [
                    '-c',
                    r'printf "%s\n%s\n" "$1" "$2" | ' +
                        openCommandInstallScript(),
                    'sh',
                    secret,
                    key,
                  ],
                  environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
                  includeParentEnvironment: false,
                ).stdout
                as String)
            .trim();
    File file() => File('${home.path}/.config/jeansh/notify-key');

    test('the install writes it private, replaces it on the next, and leaves '
        'it alone for a placeholder', () {
      expect(install('sek-ret', key), 'installed');
      expect(file().readAsStringSync(), '$key\n');
      expect(file().statSync().mode & 0x1ff, 0x180); // 0600
      expect(
        Directory('${home.path}/.config/jeansh').statSync().mode & 0x1ff,
        0x1c0, // 0700
      );
      // Rotated on a reinstall.
      expect(install('sek-ret', 'jnk_new:AAAA'), 'current');
      expect(file().readAsStringSync(), 'jnk_new:AAAA\n');
      // No key sent, none touched.
      expect(install('sek-ret', '-'), 'current');
      expect(file().readAsStringSync(), 'jnk_new:AAAA\n');
      // Something that is no key is refused, and nothing is written.
      expect(install('sek-ret', 'a key; rm -rf /'), '');
      expect(file().readAsStringSync(), 'jnk_new:AAAA\n');
      expect(Directory('${home.path}/.config/jeansh').listSync(), hasLength(2));
    });

    test('with the open secret not sent, only the key is put in place: no '
        'jeansh command is written', () {
      expect(install('-', key), 'keyed');
      expect(file().readAsStringSync(), '$key\n');
      expect(File('${home.path}/.local/bin/jeansh').existsSync(), isFalse);
      expect(
        File('${home.path}/.config/jeansh/open-secret').existsSync(),
        isFalse,
      );
    });

    test('a link in its place is replaced, never written through, and a '
        'link at the folder is refused', () {
      install('-', key);
      file().deleteSync();
      File('${home.path}/victim').writeAsStringSync('keep');
      Link(file().path).createSync('${home.path}/victim');
      expect(install('-', 'jnk_x:BBBB'), 'keyed');
      expect(File('${home.path}/victim').readAsStringSync(), 'keep');
      expect(file().readAsStringSync(), 'jnk_x:BBBB\n');
      Process.runSync('rm', ['-rf', '${home.path}/.config/jeansh']);
      Directory('${home.path}/elsewhere').createSync();
      Link('${home.path}/.config/jeansh').createSync('${home.path}/elsewhere');
      expect(install('-', key), 'secret folder is a link');
      expect(Directory('${home.path}/elsewhere').listSync(), isEmpty);
    });

    group('jeansh notify, through a real sh with stand-ins for curl and '
        'openssl', () {
      late Directory bin;
      late File log;
      setUp(() {
        bin = Directory('${home.path}/stub')..createSync();
        log = File('${home.path}/stub.log')..createSync();
        installOpenCommand('${home.path}/.local/bin');
        File('${bin.path}/curl').writeAsStringSync(
          '#!/bin/sh\nprintf "curl" >> "${log.path}"\n'
          'for a in "\$@"; do printf "\\n  %s" "\$a" >> "${log.path}"; done\n'
          'printf "\\n" >> "${log.path}"\n',
        );
        // The three things the script asks of openssl: random hex, a hash
        // and a signature, which takes the key on file descriptor 3.
        File('${bin.path}/openssl').writeAsStringSync('''#!/bin/sh
case "\$1" in
  rand) echo 00112233445566778899aabbccddeeff ;;
  base64) cat ;;
  dgst)
    case "\$*" in
      *-sign*) cat /dev/fd/3 >> "${log.path}.pem"; printf SIGNED ;;
      *) sha256sum ;;
    esac ;;
esac
''');
        Process.runSync('chmod', [
          '755',
          '${bin.path}/curl',
          '${bin.path}/openssl',
        ]);
      });

      ProcessResult notify(
        List<String> args, {
        Map<String, String> env = const {},
      }) => Process.runSync(
        'sh',
        ['${home.path}/.local/bin/jeansh', 'notify', ...args],
        environment: {
          'HOME': home.path,
          'PATH': '${bin.path}:/usr/bin:/bin',
          'JEANSH_RELAY_URL': 'http://relay.invalid',
          ...env,
        },
        includeParentEnvironment: false,
      );

      test('takes the key from the file, even with another one in the '
          'environment', () {
        install('-', key);
        final result = notify(
          ['Build', 'done'],
          env: {'LC_SSHBOX_KEY': 'jnk_fromenv:ZZZZ'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final sent = log.readAsStringSync();
        expect(
          sent,
          contains('X-PARTNER-ID: jnk_abcDEF0123456789abcdef0123456789'),
        );
        expect(sent, isNot(contains('jnk_fromenv')));
        expect(sent, contains('http://relay.invalid/v1/send'));
        expect(sent, contains('X-SIGNATURE: SIGNED'));
        expect(sent, contains('{"title":"Build","body":"done"}'));
        // The file's key, after the colon, is what openssl was given.
        final pem = File('${log.path}.pem').readAsStringSync();
        expect(pem, contains('MIGHAgEAMBMGByqGSM49+/AgEGCCqGSM49='));
        expect(pem, isNot(contains('ZZZZ')));
      });

      test('sends nothing when only the environment has a key: what an ssh '
          'from a Jeansh shell would have carried', () {
        final result = notify(['Build', 'done'], env: {'LC_SSHBOX_KEY': key});
        expect(result.exitCode, 1);
        expect(result.stderr, contains('no push key on this host'));
        expect(log.readAsStringSync(), isEmpty);
      });

      test('a file that is a link is not read', () {
        install('-', key);
        file().deleteSync();
        File('${home.path}/elsewhere').writeAsStringSync('$key\n');
        Link(file().path).createSync('${home.path}/elsewhere');
        expect(notify(['x', 'y']).exitCode, 1);
        expect(log.readAsStringSync(), isEmpty);
      });

      test('goes down the connection first, and to the relay only when that '
          'fails', () {
        install('-', key);
        final direct = notify(
          ['only a body'],
          env: {
            'LC_SSHBOX_NOTIFY_URL': 'http://127.0.0.1:9/v1/send',
            'LC_SSHBOX_NOTIFY_SECRET': 'conn-secret',
          },
        );
        expect(direct.exitCode, 0);
        final sent = log.readAsStringSync();
        expect(sent, contains('http://127.0.0.1:9/v1/send'));
        expect(sent, isNot(contains('relay.invalid')));
      });
    });
  });
}
