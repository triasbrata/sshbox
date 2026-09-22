import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/desktop_clipboard.dart';

/// The clipboard tools a Linux desktop has, stood in by shell scripts on a
/// `PATH` of their own: each is run for real, as the app runs the real ones.
void main() {
  late Directory temp;
  late Directory bin;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('desktop-clipboard');
    bin = Directory('${temp.path}/bin')..createSync();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// A tool called [name] on [bin] that runs [body] as sh.
  void tool(String name, String body) {
    final file = File('${bin.path}/$name')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('/bin/chmod', ['755', file.path]);
  }

  /// A picture of [size] bytes, as a clipboard owner would hand one over.
  File picture(String name, {int size = 64}) =>
      File('${temp.path}/$name')
        ..writeAsBytesSync(List.generate(size, (i) => i % 256));

  final stamped = RegExp(r'^pasted-\d{8}-\d{6}\.png$');

  group('Linux', () {
    test('Wayland: wl-paste hands over the PNG, named for when it was '
        'pasted', () async {
      final png = picture('source.png');
      tool('wl-paste', '''
case "\$*" in
  --list-types) printf 'text/html\\nimage/png\\nimage/bmp\\n' ;;
  "--no-newline --type image/png") /bin/cat '${png.path}' ;;
  *) exit 1 ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );

      final image = await clipboard.image(1024, windows: false);

      expect(image!.name, matches(stamped));
      expect(File(image.path).readAsBytesSync(), png.readAsBytesSync());
      expect(clipboard.missing, isNull);
    });

    test('X11: a picture copied in a file manager is taken name and all, '
        'from its file URI', () async {
      final shot = picture('shot one.png');
      tool('xclip', '''
case "\$*" in
  "-selection clipboard -target TARGETS -out")
    printf 'TARGETS\\nx-special/gnome-copied-files\\ntext/uri-list\\n' ;;
  "-selection clipboard -target text/uri-list -out")
    printf '# copied\\r\\n%s\\r\\n' '${Uri.file(shot.path)}' ;;
  *) exit 1 ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'DISPLAY': ':0'},
      );

      final image = await clipboard.image(1024, windows: false);

      expect(image!.name, 'shot one.png');
      // A copy of ours, never the user's own file, which an upload of it
      // must not hold open or a later paste delete.
      expect(image.path, isNot(shot.path));
      expect(File(image.path).readAsBytesSync(), shot.readAsBytesSync());
    });

    test('a copied file that is no picture is no picture: the paste goes on '
        'to be text', () async {
      final notes = File('${temp.path}/notes.txt')..writeAsStringSync('hi');
      tool('wl-paste', '''
case "\$*" in
  --list-types) printf 'text/uri-list\\ntext/plain\\n' ;;
  "--no-newline --type text/uri-list") printf '${Uri.file(notes.path)}' ;;
  *) exit 1 ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );

      expect(await clipboard.image(1024, windows: false), isNull);
    });

    test('an empty clipboard is no picture, not an error', () async {
      tool('wl-paste', 'echo "Nothing is copied" >&2; exit 1');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );

      expect(await clipboard.image(1024, windows: false), isNull);
      expect(clipboard.missing, isNull);
    });

    test('with neither tool installed there is no picture, and what to '
        'install is said', () async {
      final wayland = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );
      expect(await wayland.image(1024, windows: false), isNull);
      expect(wayland.missing, contains('install wl-clipboard'));

      final x11 = DesktopClipboard(
        environment: {'PATH': bin.path, 'DISPLAY': ':0'},
      );
      expect(await x11.image(1024, windows: false), isNull);
      expect(x11.missing, contains('install xclip'));
    });

    test(
      'a picture past the limit is refused, and nothing of it kept',
      () async {
        final big = picture('big.png', size: 4096);
        tool('wl-paste', '''
case "\$*" in
  --list-types) printf 'image/png\\n' ;;
  *) /bin/cat '${big.path}' ;;
esac''');
        final clipboard = DesktopClipboard(
          environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
        );

        await expectLater(
          clipboard.image(1024, windows: false),
          throwsA(
            isA<PlatformException>()
                .having((e) => e.code, 'code', 'too_big')
                .having((e) => e.message, 'message', contains('files drawer')),
          ),
        );
      },
    );

    test('a copied file past the limit is refused before it is read', () async {
      final big = picture('big.png', size: 4096);
      tool('xclip', '''
case "\$*" in
  *TARGETS*) printf 'text/uri-list\\n' ;;
  *) printf '${Uri.file(big.path)}' ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'DISPLAY': ':0'},
      );

      await expectLater(
        clipboard.image(1024, windows: false),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'too_big'),
        ),
      );
    });

    test('a picture offered and then not handed over says so', () async {
      tool('wl-paste', '''
case "\$*" in
  --list-types) printf 'image/png\\n' ;;
  *) exit 0 ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );

      await expectLater(
        clipboard.image(1024, windows: false),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'unreadable')
              .having(
                (e) => e.message,
                'message',
                contains('copying it again'),
              ),
        ),
      );
    });

    test('one picture at a time: the last paste goes with the next', () async {
      final png = picture('source.png');
      tool('wl-paste', '''
case "\$*" in
  --list-types) printf 'image/png\\n' ;;
  *) /bin/cat '${png.path}' ;;
esac''');
      final clipboard = DesktopClipboard(
        environment: {'PATH': bin.path, 'WAYLAND_DISPLAY': 'wayland-0'},
      );

      final first = await clipboard.image(1024, windows: false);
      final second = await clipboard.image(1024, windows: false);

      expect(File(first!.path).existsSync(), isFalse);
      expect(File(second!.path).existsSync(), isTrue);
    });
  });

  group('Windows', () {
    /// What PowerShell was asked, and a stand-in for it: `sh` running
    /// [answer] with the environment PowerShell would have had.
    late List<String> asked;
    late Map<String, String> given;

    DesktopClipboard windows(String answer, {int exitCode = 0}) =>
        DesktopClipboard(
          environment: const {'SystemRoot': r'C:\WINDOWS'},
          start: (executable, arguments, {environment}) {
            asked = [executable, ...arguments];
            given = environment!;
            return Process.start('/bin/sh', [
              '-c',
              '$answer\nexit $exitCode',
            ], environment: environment);
          },
        );

    test('Windows PowerShell by its full path, the script encoded so no '
        'quote in it is mangled', () async {
      final clipboard = windows("printf 'none\\r\\n'");

      expect(await clipboard.image(1024, windows: true), isNull);

      expect(
        asked.first,
        r'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(asked, containsAllInOrder(['-NoProfile', '-STA']));
      final encoded = asked[asked.indexOf('-EncodedCommand') + 1];
      final bytes = base64.decode(encoded);
      final script = String.fromCharCodes([
        for (var i = 0; i + 1 < bytes.length; i += 2)
          bytes[i] | bytes[i + 1] << 8,
      ]);
      expect(script, contains('GetFileDropList'));
      expect(script, contains("GetDataPresent('PNG')"));
      expect(given['JEANSH_PASTE_LIMIT'], '1024');
      expect(clipboard.missing, isNull);
    });

    test('a bitmap written as PNG where the script was told to', () async {
      final clipboard = windows(
        r'''printf '\211PNG' > "$JEANSH_PASTE_OUT"; printf '\357\273\277png\r\n' ''',
      );

      final image = await clipboard.image(1024, windows: true);

      expect(image!.name, matches(stamped));
      expect(image.path, given['JEANSH_PASTE_OUT']);
      expect(File(image.path).readAsBytesSync(), [0x89, 0x50, 0x4e, 0x47]);
    });

    test('a picture copied in Explorer is taken name and all, the first '
        'picture of what was copied', () async {
      final notes = File('${temp.path}/notes.txt')..writeAsStringSync('hi');
      final shot = picture('Capture d’écran.PNG');
      final clipboard = windows(
        "printf 'file\\r\\n%s\\r\\n%s\\r\\n' '${notes.path}' '${shot.path}'",
      );

      final image = await clipboard.image(1024, windows: true);

      expect(image!.name, 'Capture d’écran.PNG');
      expect(File(image.path).readAsBytesSync(), shot.readAsBytesSync());
    });

    test('too big, or held back, says what to do', () async {
      await expectLater(
        windows("printf 'too_big'").image(1024, windows: true),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'too_big'),
        ),
      );
      await expectLater(
        windows("printf 'unreadable'").image(1024, windows: true),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'unreadable'),
        ),
      );
      final huge = windows(
        r'''head -c 4096 /dev/zero > "$JEANSH_PASTE_OUT"; printf png''',
      );
      await expectLater(
        huge.image(1024, windows: true),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'too_big'),
        ),
      );
      expect(File(given['JEANSH_PASTE_OUT']!).existsSync(), isFalse);
    });

    test(
      'a PowerShell that fails is no picture, and says so only then',
      () async {
        final clipboard = windows('echo Add-Type refused >&2', exitCode: 1);

        expect(await clipboard.image(1024, windows: true), isNull);
        expect(clipboard.missing, contains('Windows PowerShell'));
      },
    );
  });

  test('a pasted picture is named for the second it was pasted', () {
    expect(
      pastedName('png', DateTime(2026, 9, 21, 7, 5, 3)),
      'pasted-20260921-070503.png',
    );
  });
}
