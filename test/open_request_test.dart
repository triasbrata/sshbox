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
String _osc(String secret, String path) =>
    '\x1b]7733;open;$secret;${_b64(path)}\x07';

void main() {
  late List<String> opened;
  late OpenRequests requests;
  late ClipboardTerminal terminal;
  var clock = DateTime(2026);

  setUp(() {
    opened = [];
    clock = DateTime(2026);
    requests = OpenRequests(
      onOpen: opened.add,
      secret: 'sek-ret',
      now: () => clock,
    );
    terminal = ClipboardTerminal(
      onPrivateOSC: (code, args) => requests.handle(code, args),
    );
  });

  test('the right secret opens the path', () {
    terminal.write('a${_osc('sek-ret', '/home/me/notes.md')}b');
    expect(opened, ['/home/me/notes.md']);
    expect(terminal.buffer.lines[0].getText().trimRight(), 'ab');
  });

  test('a wrong, missing or empty secret opens nothing', () {
    terminal.write(_osc('sek-reT', '/etc/passwd'));
    terminal.write(_osc('', '/etc/passwd'));
    terminal.write(_osc('sek-ret-and-more', '/etc/passwd'));
    terminal.write('\x1b]7733;open;${_b64('/etc/passwd')}\x07');
    requests.secret = null;
    terminal.write(_osc('sek-ret', '/etc/passwd'));
    expect(opened, isEmpty);
  });

  test('a path with a control character, or not absolute, is refused', () {
    for (final path in [
      'relative.txt',
      '/a\nb',
      '/a\x1bb',
      '/a\x7fb',
      '/a\u0085b',
      '',
      '/${'x' * 5000}',
    ]) {
      terminal.write(_osc('sek-ret', path));
    }
    terminal.write('\x1b]7733;open;sek-ret;not base64!\x07');
    expect(opened, isEmpty);
  });

  test('a burst is bounded, and the allowance comes back', () {
    for (var i = 0; i < 9; i++) {
      terminal.write(_osc('sek-ret', '/f$i'));
    }
    expect(opened, hasLength(OpenRequests.burst));
    clock = clock.add(OpenRequests.window);
    terminal.write(_osc('sek-ret', '/later'));
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

    test('writes exactly the sequence, for each file that is there', () {
      final result = run(['a b\'s.txt', 'missing', 'folder', './a b\'s.txt']);
      final real = dir.resolveSymbolicLinksSync();
      final one = '\x1b]7733;open;sek-ret;${_b64('$real/a b\'s.txt')}\x07';
      expect(tty.readAsStringSync(), '$one$one');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('missing: no such file'));
      expect(result.stderr, contains('folder: is a folder'));
      // And the app takes what it wrote.
      final seen = <String>[];
      ClipboardTerminal(
        onPrivateOSC: OpenRequests(onOpen: seen.add, secret: 'sek-ret').handle,
      ).write(tty.readAsStringSync());
      expect(seen, ['$real/a b\'s.txt', '$real/a b\'s.txt']);
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
