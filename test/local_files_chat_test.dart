// The files drawer and chat in a desktop's Local shell: this machine's own
// files through dart:io, and Claude run beside the shell as a process, as an
// SSH exec channel runs it on a host.
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/local_file_browser.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';
import 'package:sshbox/src/ui/terminal_page.dart';

/// A pty that is up and never says a word, keeping what it was started with.
class _Pty implements Pty {
  _Pty(this.executable, this.arguments, this.workingDirectory, this.env);

  @override
  final String executable;
  @override
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? env;
  final _out = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A stand-in for Claude Code: its version, and a `-p` that answers each
/// message it is sent. Never this machine's own claude: it is found first on
/// a PATH of the test's own.
const _standIn = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.300 (Claude Code)"; exit 0 ;;
  -p)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"0e2e0000-0000-4000-8000-00000000c0de"}'
    while IFS= read -r line; do
      printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Echo from the stand-in"}]}}'
      printf '%s\n' '{"type":"result","subtype":"success"}'
    done ;;
esac
''';

void main() {
  late Directory temp;
  late Directory home;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('jeansh-local-');
    home = Directory('${temp.path}/home')..createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<Process> sh(String command) =>
      Process.start('/bin/sh', ['-c', command], workingDirectory: home.path);

  LocalFileBrowser browser() =>
      LocalFileBrowser(process: sh, home: () async => home.path);

  group('a Local shell\'s files', () {
    test('list folders first, dotfiles and links included', () async {
      Directory('${home.path}/src').createSync();
      File('${home.path}/b.txt').writeAsStringSync('b');
      File('${home.path}/.profile').writeAsStringSync('x');
      Link('${home.path}/to-src').createSync('${home.path}/src');
      Link('${home.path}/broken').createSync('${home.path}/nowhere');

      final entries = await browser().list(home.path);
      expect(entries.map((e) => e.name), [
        'src',
        '.profile',
        'b.txt',
        'broken',
        'to-src',
      ]);
      expect(entries.first.kind, RemoteEntryKind.directory);
      final b = entries.firstWhere((e) => e.name == 'b.txt');
      expect(b.path, '${home.path}/b.txt');
      expect(b.size, 1);
      final link = entries.firstWhere((e) => e.name == 'to-src');
      expect(link.kind, RemoteEntryKind.symlink);
      expect(link.isTraversable, isTrue);
      expect(
        entries.firstWhere((e) => e.name == 'broken').targetIsDirectory,
        isNull,
      );
      expect(await browser().resolveHome(), home.path);
      expect(
        await browser().stat('${home.path}/src'),
        RemoteEntryKind.directory,
      );
      expect(await browser().stat('${home.path}/none'), isNull);
    });

    test('open and save, refusing to write over a change made since', () async {
      final path = '${home.path}/notes.txt';
      File(path).writeAsStringSync('one\n');
      final files = browser();

      final read = await files.readText(path);
      expect(read.text, 'one\n');
      final stamp = await files.writeText(path, 'two\n', expected: read.stamp);
      expect(File(path).readAsStringSync(), 'two\n');

      // Somebody else saves meanwhile.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(path).writeAsStringSync('theirs\n');
      await expectLater(
        files.writeText(path, 'mine\n', expected: stamp),
        throwsA(
          isA<FileBrowserException>().having(
            (e) => e.fault,
            'fault',
            FileBrowserFault.changed,
          ),
        ),
      );
      expect(File(path).readAsStringSync(), 'theirs\n');
    });

    test('say what went wrong as the faults the pages act on', () async {
      final files = browser();
      File('${home.path}/bin').writeAsBytesSync([1, 0, 2]);
      Directory('${home.path}/full').createSync();
      File('${home.path}/full/x').writeAsStringSync('x');
      File('${home.path}/big').writeAsStringSync('x' * 20);

      Matcher fault(FileBrowserFault f) =>
          throwsA(isA<FileBrowserException>().having((e) => e.fault, '', f));
      expect(
        files.readText('${home.path}/none'),
        fault(FileBrowserFault.notFound),
      );
      expect(
        files.readText('${home.path}/bin'),
        fault(FileBrowserFault.notText),
      );
      expect(
        files.readText('${home.path}/big', maxBytes: 10),
        fault(FileBrowserFault.tooLarge),
      );
      await expectLater(
        files.delete('${home.path}/full'),
        fault(FileBrowserFault.notEmpty),
      );
      await files.delete('${home.path}/full', recursive: true);
      expect(Directory('${home.path}/full').existsSync(), isFalse);
    });

    test(
      'rename, delete a link and not what it points at, make a folder',
      () async {
        final files = browser();
        File('${home.path}/a').writeAsStringSync('a');
        Directory('${home.path}/d').createSync();
        Link('${home.path}/l').createSync('${home.path}/d');

        await files.rename('${home.path}/a', '${home.path}/b');
        expect(File('${home.path}/b').readAsStringSync(), 'a');
        await files.rename('${home.path}/d', '${home.path}/e');
        expect(Directory('${home.path}/e').existsSync(), isTrue);

        Link('${home.path}/l2').createSync('${home.path}/e');
        await files.delete('${home.path}/l2', recursive: true);
        expect(Directory('${home.path}/e').existsSync(), isTrue);

        await files.makeDirectory('${home.path}/new');
        expect(Directory('${home.path}/new').existsSync(), isTrue);
        await expectLater(
          files.makeDirectory('${home.path}/new'),
          throwsA(isA<FileBrowserException>()),
        );
      },
    );

    test(
      'upload private, never through a name taken, and replace whole',
      () async {
        final files = browser();
        final source = File('${temp.path}/up.bin')..writeAsBytesSync([1, 2, 3]);
        final target = '${home.path}/up.bin';
        final progress = <int>[];

        await files.upload(
          source.path,
          target,
          onProgress: (s, _) => progress.add(s),
        );
        expect(File(target).readAsBytesSync(), [1, 2, 3]);
        expect(File(target).statSync().mode & 0x1ff, 0x180);
        expect(progress.last, 3);

        // A link planted under the name is not written through.
        final victim = File('${temp.path}/victim')..writeAsStringSync('safe');
        Link('${home.path}/planted').createSync(victim.path);
        await expectLater(
          files.upload(source.path, '${home.path}/planted'),
          throwsA(isA<FileBrowserException>()),
        );
        expect(victim.readAsStringSync(), 'safe');

        source.writeAsBytesSync([9]);
        await files.upload(source.path, target, replace: true);
        expect(File(target).readAsBytesSync(), [9]);
        // Nothing of the replace is left beside it.
        expect(home.listSync().map((e) => e.path.split('/').last).toSet(), {
          'up.bin',
          'planted',
        });
      },
    );

    test('download all of a file, or a stretch of it', () async {
      final files = browser();
      File('${home.path}/log').writeAsStringSync('0123456789');
      final out = '${temp.path}/out';

      await files.download('${home.path}/log', out);
      expect(File(out).readAsStringSync(), '0123456789');
      await files.download('${home.path}/log', out, offset: 6, length: 3);
      expect(File(out).readAsStringSync(), '678');
    });

    test('search a literal string, nothing in it run', () async {
      File('${home.path}/a.txt')
          .writeAsStringSync('nothing\n\$(touch pwned) here\n');
      final hits = await browser()
          .search(root: home.path, query: r'$(touch pwned)')
          .toList();
      expect(hits, hasLength(1));
      expect(hits.single.path, '${home.path}/a.txt');
      expect(hits.single.line, 2);
      expect(File('${home.path}/pwned').existsSync(), isFalse);
    });
  });

  group('a Local shell, on a real LocalTransport', () {
    final pties = <_Pty>[];
    var chats = 0;

    /// [environment] as the app's own: HOME the test's, and a PATH that finds
    /// the stand-in claude first and nothing of this machine's user.
    LocalTransport transport() {
      final bin = Directory('${temp.path}/bin')..createSync(recursive: true);
      final claude = File('${bin.path}/claude')..writeAsStringSync(_standIn);
      Process.runSync('chmod', ['755', claude.path]);
      return LocalTransport(
        environment: {
          'HOME': home.path,
          'SHELL': '/bin/sh',
          'PATH': '${bin.path}:/usr/bin:/bin',
          'TMUX': '/tmp/somebody-else,1,0',
        },
        startPty:
            (
              executable, {
              arguments = const [],
              workingDirectory,
              environment,
              rows = 25,
              columns = 80,
              ackRead = false,
            }) {
              final pty = _Pty(
                executable,
                arguments,
                workingDirectory,
                environment,
              );
              pties.add(pty);
              return pty;
            },
      );
    }

    setUp(() {
      pties.clear();
      chats = 0;
    });

    test('Claude answers in a chat run beside the shell, found and quoted '
        'as on a host', () async {
      final session = LiveSession(
        host: localHost(),
        transport: (_, _) => transport(),
      );
      addTearDown(session.dispose);
      await session.connect(secrets: InMemorySecretStore());

      expect(session.canChat, isTrue);
      expect(await session.chatRefusal(), isNull);

      final chat = session.chat;
      await chat.start();
      await chat.send('hello');
      for (var i = 0; i < 100; i++) {
        if (!chat.busy) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(chat.entries.whereType<ChatSaid>().map((e) => e.text), [
        'hello',
        'Echo from the stand-in',
      ]);
      session.closeChat();
    });

    test(
      'a terminal beside the shell is a pty of its own, as attach wants',
      () async {
        final session = LiveSession(
          host: localHost(),
          transport: (_, _) => transport(),
        );
        addTearDown(session.dispose);
        await session.connect(secrets: InMemorySecretStore());
        final shells = pties.length;

        final channel = await session.chat.openTerminal!(
          ClaudeChat.attachCommand('e2e0c0de'),
        );
        final pty = pties[shells];
        expect(pty.executable, '/bin/sh');
        expect(pty.arguments, ['-c', ClaudeChat.attachCommand('e2e0c0de')]);
        expect(pty.workingDirectory, home.path);
        // Not pointed at whichever tmux the app was started inside.
        expect(pty.env!.containsKey('TMUX'), isFalse);
        channel.close();
      },
    );

    Future<LiveSession> pumpLocal(WidgetTester tester) async {
      final session = LiveSession(
        host: localHost(),
        transport: (_, _) => transport(),
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: InMemorySecretStore(),
            onOpenFile: (_, {line}) {},
            onOpenWeb: (_) {},
            onOpenChat: () => chats++,
            onOpenGit: () {},
            onOpenDiff: (_) {},
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      await tester.runAsync(
        () => session.connect(secrets: InMemorySecretStore()),
      );
      await tester.pump();
      return session;
    }

    /// Real time for real files and processes, which a widget test's fake
    /// clock never gives, until [done].
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue);
    }

    bool enabled(WidgetTester tester, String tooltip) =>
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip(tooltip),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed !=
        null;

    testWidgets('offers the files drawer and chat, and the drawer lists home', (
      tester,
    ) async {
      File('${home.path}/made-by-the-test.txt').writeAsStringSync('hi');
      await pumpLocal(tester);

      expect(enabled(tester, 'Browse files'), isTrue);
      expect(enabled(tester, 'Chat with Claude'), isTrue);
      expect(enabled(tester, 'Git'), isTrue);

      await tester.tap(find.byTooltip('Browse files'));
      await until(
        tester,
        () => find.text('made-by-the-test.txt').evaluate().isNotEmpty,
      );
      expect(find.byType(FileBrowserPage), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('offers the files drawer and chat on Linux too', (
      tester,
    ) async {
      File('${home.path}/made-by-the-test.txt').writeAsStringSync('hi');
      await pumpLocal(tester);

      expect(enabled(tester, 'Browse files'), isTrue);
      expect(enabled(tester, 'Chat with Claude'), isTrue);
      await tester.tap(find.byTooltip('Browse files'));
      await until(
        tester,
        () => find.text('made-by-the-test.txt').evaluate().isNotEmpty,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets(
      'the chat button asks the stand-in Claude and opens chat',
      (tester) async {
        await pumpLocal(tester);
        await tester.tap(find.byTooltip('Chat with Claude'));
        // Opened only once the stand-in said a version new enough.
        await until(tester, () => chats == 1);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );

    testWidgets(
      'opens a file of home in the editor and saves it',
      (tester) async {
        final path = '${home.path}/notes.txt';
        File(path).writeAsStringSync('first\n');
        final session = await pumpLocal(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: FileEditorPage(browser: session.fileBrowser, path: path),
          ),
        );
        CodeLineEditingController editor() =>
            tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
        await until(
          tester,
          () => find.byType(CodeEditor).evaluate().isNotEmpty,
        );
        await until(tester, () => editor().text == 'first\n');

        editor().text = 'second\n';
        await tester.pump();
        await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
        await until(tester, () => File(path).readAsStringSync() == 'second\n');
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  });

  test('a WSL distro\'s files are its own share on Windows', () {
    expect(
      LocalFileBrowser.wslPath('Ubuntu', '/home/me/a b.txt'),
      r'\\wsl.localhost\Ubuntu\home\me\a b.txt',
    );
  });

  // #137: typing into an interactive Claude in a tmux pane, from a Local
  // shell's chat, as an SSH host's chat does. The session is
  // tools/e2e_live_claude.py in a pane of this test's own tmux server.
  group('a Local shell\'s chat types into a pane', () {
    final hasTmux =
        Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;
    const sid = 'e2e00004-0000-4000-8000-000000000004';
    late Map<String, String> env;

    Future<String> tmux(List<String> args) async {
      final result = await Process.run(
        'tmux',
        args,
        environment: env,
        includeParentEnvironment: false,
      );
      return '${result.stdout}'.trim();
    }

    setUp(() {
      final bin = Directory('${temp.path}/bin')..createSync();
      final claude = File('${bin.path}/claude')
        ..writeAsStringSync(
          '#!/bin/sh\ncase "\$1" in\n'
          "  --version) echo '2.1.300 (Claude Code)' ;;\n"
          '  agents) cat "\$HOME/.e2e-agents.json" ;;\n'
          '  *) exec cat >/dev/null ;;\nesac\n',
        );
      Process.runSync('chmod', ['755', claude.path]);
      env = {
        'HOME': home.path,
        'SHELL': '/bin/sh',
        'PATH': '${bin.path}:/usr/bin:/bin',
        'TMUX_TMPDIR': temp.path,
        'LANG': 'C.UTF-8',
      };
    });
    tearDown(() async {
      if (hasTmux) await tmux(['kill-server']);
    });

    test(
      'and the line reaches it, recorded as the session\'s turn',
      () async {
        // Where the stand-in, run in home, files its transcript, as the CLI
        // does: its directory with / and . made -.
        final projects = Directory(
          '${home.path}/.claude/projects/'
          '${home.path.replaceAll(RegExp('[/.]'), '-')}',
        )..createSync(recursive: true);
        final transcript = File('${projects.path}/$sid.jsonl')
          ..writeAsStringSync(
            '{"type":"user","message":{"role":"user","content":"Earlier '
            'question"}}\n{"type":"assistant","message":{"role":"assistant",'
            '"content":[{"type":"text","text":"Earlier answer"}]}}\n',
          );
        final script = File('tools/e2e_live_claude.py').absolute.path;
        await tmux([
          'new-session', '-d', '-s', 'e2e-live', '-x', '120', '-y', '30', //
          '-c', home.path, 'env PYTHONIOENCODING=utf-8 python3 $script $sid',
        ]);
        final drawn = DateTime.now().add(const Duration(seconds: 5));
        while (!(await tmux(['capture-pane', '-p', '-t', 'e2e-live']))
            .contains('❯')) {
          if (DateTime.now().isAfter(drawn)) fail('the pane never drew');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // The stand-in's own pid, as `claude agents` gives Claude's: the
        // pane's shell may not have exec'd it.
        final pid = int.parse(
          Directory('${home.path}/.claude/sessions')
              .listSync()
              .single
              .path
              .split('/')
              .last
              .replaceAll('.json', ''),
        );
        File('${home.path}/.e2e-agents.json').writeAsStringSync(
          '[{"kind":"interactive","pid":$pid,"sessionId":"$sid",'
          '"name":"E2E live session","cwd":"${home.path}","status":"idle"}]',
        );

        final session = LiveSession(
          host: localHost(),
          transport: (_, _) => LocalTransport(
            environment: env,
            startPty: (
              executable, {
              arguments = const [],
              workingDirectory,
              environment,
              rows = 25,
              columns = 80,
              ackRead = false,
            }) => _Pty(executable, arguments, workingDirectory, environment),
          ),
        );
        addTearDown(session.dispose);
        await session.connect(secrets: InMemorySecretStore());
        final chat = session.chat;
        final agent = (await chat.agents()).single;
        await chat.continueFrom(agent);
        // Picked again — as a reconnect, or a tap on its row, picks it — its
        // follow stopped and started afresh.
        await chat
            .continueFrom(agent)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail('picking it again never finished'),
            );
        expect(chat.readOnly, isNull);
        expect(
          chat.entries.whereType<ChatSaid>().map((e) => e.text),
          contains('Earlier answer'),
        );

        String said() => chat.entries
            .map((e) => e is ChatSaid ? '${e.text} ${e.why ?? ''}' : '$e')
            .join(' | ');
        unawaited(chat.send('hello from the chat'));
        final typed = DateTime.now().add(const Duration(seconds: 40));
        while (!transcript.readAsStringSync().contains('hello from the chat')) {
          if (DateTime.now().isAfter(typed)) {
            final pane = await tmux(['capture-pane', '-p', '-t', 'e2e-live']);
            fail('never typed; chat: ${said()}; pane: $pane');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // And its answer comes back through the follow.
        final answered = DateTime.now().add(const Duration(seconds: 10));
        while (!chat.entries.whereType<ChatSaid>().any(
          (e) => e.text == 'Echo: hello from the chat',
        )) {
          if (DateTime.now().isAfter(answered)) {
            fail('no answer followed; chat: ${said()}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        session.closeChat();
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: hasTmux ? false : 'tmux is not installed here',
    );
  });
}
