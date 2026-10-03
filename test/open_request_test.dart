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
  late OpenRequests requests;
  late ClipboardTerminal terminal;
  var clock = DateTime(2026);

  setUp(() {
    opened = [];
    refused = 0;
    clock = DateTime(2026);
    requests = OpenRequests(
      onOpen: opened.add,
      onRefused: () => refused++,
      secret: 'sek-ret',
      clockOffset: 0,
      now: () => clock,
    );
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
      String run() =>
          (Process.runSync(
                    'sh',
                    ['-c', openCommandInstallScript()],
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
    expect(await setting.choose(true), isTrue);
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
    expect(await setting.choose(true), isFalse);
    expect(target.readAsStringSync(), contains('mine'));
    target.deleteSync();
    File('${home.path}/victim').writeAsStringSync('keep');
    Link(target.path).createSync('${home.path}/victim');
    expect(await setting.choose(true), isFalse);
    expect(File('${home.path}/victim').readAsStringSync(), 'keep');

    // Off writes nothing, and is saved.
    expect(await setting.choose(false), isTrue);
    expect(setting.value, isFalse);
  });

  group('the jeansh script, run through a real sh', () {
    late Directory dir;
    late File tty;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('jeansh-open');
      tty = File('${dir.path}/tty')..createSync();
      installOpenCommand('${dir.path}/bin');
      File('${dir.path}/a b\'s.txt').writeAsStringSync('x');
      Directory('${dir.path}/folder').createSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ProcessResult run(List<String> args, {String? secret = 'sek-ret'}) =>
        Process.runSync(
          'sh',
          ['${dir.path}/bin/jeansh', ...args],
          workingDirectory: dir.path,
          environment: {
            'JEANSH_TTY': tty.path,
            'LC_SSHBOX_OPEN_SECRET': ?secret,
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

    test('says so, and writes nothing, outside a Jeansh terminal', () {
      final result = run(['a b\'s.txt'], secret: null);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('not running in a Jeansh terminal'));
      expect(tty.readAsStringSync(), isEmpty);
      expect(run([]).exitCode, 2);
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
}
