import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/aggregator_script.dart';

/// The helper run for real under python3 against a Unix socket server of the
/// test's own, standing in for a Claude Code session's messaging socket.
void main() {
  late Directory root;
  late String script;
  late String cfg;
  late String state;
  late String sockPath;
  late ServerSocket server;
  late List<String> lines;
  const sid = '11111111-2222-4333-8444-555555555555';

  Map<String, String> env([Map<String, String> more = const {}]) => {
    'HOME': root.path,
    'CLAUDE_CONFIG_DIR': cfg,
    'XDG_STATE_HOME': state,
    'JEANSH_AGG_GAP': '0.3',
    'JEANSH_AGG_WAKE': '3',
    ...more,
  };

  Future<Map<String, dynamic>> run(
    List<String> args, {
    Map<String, String> more = const {},
    int exit = 0,
  }) async {
    final result = await Process.run(
      'python3',
      [script, ...args],
      environment: env(more),
      includeParentEnvironment: false,
    );
    expect(result.exitCode, exit, reason: '${result.stderr}');
    final line = (result.stdout as String).trim().split('\n').first;
    return jsonDecode(line) as Map<String, dynamic>;
  }

  void session({String? socket, int? pid, String kind = 'bg', String? cwd}) {
    File('$cfg/sessions/${pid ?? ioPid}.json').writeAsStringSync(
      jsonEncode({
        'pid': pid ?? ioPid,
        'sessionId': sid,
        'kind': kind,
        'status': 'idle',
        'cwd': cwd ?? root.path,
        'updatedAt': 1,
        'messagingSocketPath': socket ?? sockPath,
      }),
    );
  }

  String b64(String text) => base64.encode(utf8.encode(text));

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ok(), isTrue);
  }

  setUpAll(() {
    root = Directory('/tmp').createTempSync('jagg');
    script = '${root.path}/jeansh-agg.py';
    File(script).writeAsStringSync(aggregatorScript);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  setUp(() async {
    cfg = '${root.path}/claude';
    state = '${root.path}/state';
    for (final d in [cfg, state]) {
      final dir = Directory(d);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    Directory('$cfg/sessions').createSync(recursive: true);
    Directory('$cfg/projects/p').createSync(recursive: true);
    sockPath = '${root.path}/s.sock';
    final old = File(sockPath);
    if (old.existsSync()) old.deleteSync();
    server = await ServerSocket.bind(
      InternetAddress(sockPath, type: InternetAddressType.unix),
      0,
    );
    lines = [];
    server.listen((client) {
      final buffer = StringBuffer();
      client.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
        buffer.write(chunk);
        final text = buffer.toString();
        if (text.contains('\n')) {
          lines.addAll(text.split('\n').where((l) => l.isNotEmpty));
          buffer.clear();
        }
      }, onError: (_) {});
    });
  });
  tearDown(() => server.close());

  test('the script says its own version and marker', () async {
    expect(aggregatorScript.split('\n')[1], aggregatorMarker);
    expect(aggregatorScript, contains('\nVERSION = $aggregatorVersion\n'));
    final hello = await run(['hello']);
    expect(hello['version'], aggregatorVersion);
  });

  test('a message is written once, as one line from jeansh-<id>', () async {
    session(pid: ioPid);
    final said = await run(
      [
        'deliver',
        'msg-0001-aaaa',
        sid,
        '--text-b64',
        b64('hello — “there”\nsecond line'),
      ],
      more: {'JEANSH_AGG_FOREGROUND': '1'},
    );
    expect(said['state'], 'accepted');
    expect(lines, hasLength(1));
    final sent = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(sent['type'], 'user');
    expect(sent['from'], 'jeansh-msg-0001-aaaa');
    expect((sent['message'] as Map)['content'], 'hello — “there”\nsecond line');
    expect(sent['uuid'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    final status = await run(['status', 'msg-0001-aaaa']);
    expect(status['state'], 'sent');
  });

  test('delivered is read from the transcript, by origin.from', () async {
    session(pid: ioPid);
    await run(
      ['deliver', 'msg-0002-bbbb', sid, '--text-b64', b64('x')],
      more: {'JEANSH_AGG_FOREGROUND': '1'},
    );
    final transcript = File('$cfg/projects/p/$sid.jsonl');
    // Another message's line, and the same text from nobody: not ours.
    transcript.writeAsStringSync(
      '${jsonEncode({
        'type': 'user',
        'origin': {'kind': 'peer', 'from': 'jeansh-msg-9999-zzzz'},
      })}\n${jsonEncode({
        'type': 'user',
        'message': {'content': 'jeansh-msg-0002-bbbb'},
      })}\n',
    );
    expect((await run(['status', 'msg-0002-bbbb']))['state'], 'sent');
    transcript.writeAsStringSync(
      '${jsonEncode({
        'type': 'user',
        'isMeta': true,
        'origin': {'kind': 'peer', 'from': 'jeansh-msg-0002-bbbb'},
      })}\n',
      mode: FileMode.append,
    );
    expect((await run(['status', 'msg-0002-bbbb']))['state'], 'delivered');
  });

  test('the same id again writes nothing more', () async {
    session(pid: ioPid);
    final args = ['deliver', 'msg-0003-cccc', sid, '--text-b64', b64('once')];
    await run(args, more: {'JEANSH_AGG_FOREGROUND': '1'});
    final again = await run(args, more: {'JEANSH_AGG_FOREGROUND': '1'});
    expect(again['duplicate'], isTrue);
    expect(again['state'], 'sent');
    expect(lines, hasLength(1));
  });

  test('a session that holds or refuses peers is not written to', () async {
    session(pid: ioPid);
    File('$cfg/settings.json')
        .writeAsStringSync(jsonEncode({'crossSessionInbound': 'hold'}));
    final probe = await run(['probe', sid]);
    expect(probe['hold'], contains('crossSessionInbound is hold'));
    final said = await run(
      ['deliver', 'msg-0004-dddd', sid, '--text-b64', b64('x')],
      more: {'JEANSH_AGG_FOREGROUND': '1'},
    );
    expect(said['state'], 'accepted');
    final status = await run(['status', 'msg-0004-dddd']);
    expect(status['state'], 'refused');
    expect(status['reason'], contains('hold'));
    expect(lines, isEmpty);

    // An invalid value holds, as Claude Code does; accept does not.
    File('$cfg/settings.json')
        .writeAsStringSync(jsonEncode({'crossSessionInbound': 'sometimes'}));
    expect((await run(['probe', sid]))['hold'], isNotNull);
    File('$cfg/settings.json')
        .writeAsStringSync(jsonEncode({'crossSessionInbound': 'accept'}));
    expect((await run(['probe', sid]))['hold'], isNull);
  });

  test('a project setting and a bypass mode hold too', () async {
    final project = Directory('${root.path}/proj')..createSync();
    Directory('${project.path}/.claude').createSync();
    session(pid: ioPid, cwd: project.path);
    File('${project.path}/.claude/settings.json')
        .writeAsStringSync(jsonEncode({'crossSessionInbound': 'refuse'}));
    expect(
      (await run(['probe', sid]))['hold'],
      contains('crossSessionInbound is refuse'),
    );
    File('${project.path}/.claude/settings.json').deleteSync();
    expect((await run(['probe', sid]))['hold'], isNull);
    File('$cfg/projects/p/$sid.jsonl').writeAsStringSync(
      '${jsonEncode({'type': 'user', 'permissionMode': 'bypassPermissions'})}\n',
    );
    expect(
      (await run(['probe', sid]))['hold'],
      contains('bypasses permission prompts'),
    );
  });

  test('a session that is not running is undeliverable, not guessed', () async {
    final said = await run(
      ['deliver', 'msg-0005-eeee', sid, '--text-b64', b64('x')],
      more: {'JEANSH_AGG_FOREGROUND': '1'},
    );
    expect(said['state'], 'accepted');
    final status = await run(['status', 'msg-0005-eeee']);
    expect(status['state'], 'undeliverable');
    expect(lines, isEmpty);
  });

  test(
    'a stopped background session is respawned once, then written',
    () async {
      final log = File('${root.path}/respawn.log');
      if (log.existsSync()) log.deleteSync();
      final claude = File('${root.path}/fake-claude')
        ..writeAsStringSync('''#!/bin/sh
echo "\$@" >> "${log.path}"
cat > "$cfg/sessions/$ioPid.json" <<EOF
{"pid": $ioPid, "sessionId": "$sid", "kind": "bg", "status": "idle", "cwd": "${root.path}", "updatedAt": 2, "messagingSocketPath": "$sockPath"}
EOF
''');
      await Process.run('chmod', ['700', claude.path]);
      await run(
        [
          'deliver',
          'msg-0006-ffff',
          sid,
          '--text-b64',
          b64('wake up'),
          '--job',
          '11111111',
          '--claude',
          claude.path,
        ],
        more: {'JEANSH_AGG_FOREGROUND': '1'},
      );
      expect(log.readAsStringSync().trim(), 'respawn 11111111');
      expect(lines, hasLength(1));
      expect((await run(['status', 'msg-0006-ffff']))['state'], 'sent');
      // Not stopped: no respawn is ever tried.
      log.deleteSync();
      await run(
        [
          'deliver',
          'msg-0007-gggg',
          sid,
          '--text-b64',
          b64('again'),
          '--job',
          '11111111',
          '--claude',
          claude.path,
        ],
        more: {'JEANSH_AGG_FOREGROUND': '1'},
      );
      expect(log.existsSync(), isFalse);
      expect(lines, hasLength(2));
    },
  );

  test('the peer token goes first when the session published one', () async {
    session(pid: ioPid);
    // sha256 of the socket path names the key file.
    final digest = (await Process.run('python3', [
      '-c',
      'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())',
      sockPath,
    ])).stdout.toString().trim();
    File('$cfg/sessions/$ioPid.$digest.key')
        .writeAsStringSync(jsonEncode({'peerToken': 'tok123'}));
    await run(
      ['deliver', 'msg-0008-hhhh', sid, '--text-b64', b64('x')],
      more: {'JEANSH_AGG_FOREGROUND': '1'},
    );
    expect(lines, hasLength(2));
    expect(jsonDecode(lines.first), {'type': 'auth', 'token': 'tok123'});
    expect((jsonDecode(lines.last) as Map)['type'], 'user');
  });

  test('sends to one session go in order, each after a gap', () async {
    session(pid: ioPid);
    final starts = <int>[];
    for (final n in ['0a', '0b', '0c']) {
      final r = await run([
        'deliver',
        'msg-00$n-iiii',
        sid,
        '--text-b64',
        b64('m$n'),
      ]);
      expect(r['state'], 'accepted');
      starts.add(DateTime.now().millisecondsSinceEpoch);
    }
    await until(() => lines.length == 3);
    final got = [
      for (final l in lines)
        ((jsonDecode(l) as Map)['message'] as Map)['content'],
    ];
    expect(got, ['m0a', 'm0b', 'm0c']);
    for (final n in ['0a', '0b', '0c']) {
      await until(() {
        final f = File('$state/jeansh/agg/msg-00$n-iiii.json');
        return f.existsSync() && f.readAsStringSync().contains('"sent"');
      });
    }
  });

  test(
    'bad ids, sessions and text are refused before anything is kept',
    () async {
      await run(['deliver', 'short', sid, '--text-b64', b64('x')], exit: 2);
      await run([
        'deliver',
        'msg-0009-jjjj',
        'nope',
        '--text-b64',
        b64('x'),
      ], exit: 2);
      await run(['deliver', 'msg-0009-jjjj', sid, '--text-b64', '!!'], exit: 2);
      await run([
        'deliver',
        'msg-0009-jjjj',
        sid,
        '--text-b64',
        b64('  '),
      ], exit: 2);
      await run(['deliver', 'msg-0009-jjjj', sid, '--bogus', 'x'], exit: 2);
      await run(['status', '../etc'], exit: 2);
      await run(['probe', 'x'], exit: 2);
      await run(['nothing'], exit: 2);
      final journal = Directory('$state/jeansh/agg');
      expect(
        journal.existsSync()
            ? journal.listSync().where((e) => e.path.endsWith('.json'))
            : <FileSystemEntity>[],
        isEmpty,
      );
    },
  );

  group('install', () {
    late String home;
    setUp(() {
      home = Directory('${root.path}/home').path;
      if (Directory(home).existsSync()) {
        Directory(home).deleteSync(recursive: true);
      }
      Directory(home).createSync();
    });

    Future<String> install() async {
      final p = await Process.start(
        'sh',
        ['-c', aggregatorInstallCommand],
        environment: {'HOME': home, 'PATH': Platform.environment['PATH']!},
        includeParentEnvironment: false,
      );
      p.stdin.add(utf8.encode(aggregatorScript));
      await p.stdin.close();
      final out = await utf8.decodeStream(p.stdout);
      await p.exitCode;
      return out.trim();
    }

    test(
      'writes the script 0700, keeps a current one, refuses others',
      () async {
        expect(await install(), 'ok');
        final f = File('$home/$aggregatorDir/$aggregatorFile');
        expect(f.readAsStringSync(), aggregatorScript);
        expect(f.statSync().mode & 0x1ff, 0x1c0);
        expect(await install(), 'kept');
        f.writeAsStringSync(
          aggregatorScript.replaceFirst(
            'VERSION = $aggregatorVersion',
            'VERSION = 0',
          ),
        );
        expect(await install(), 'ok');
        expect(f.readAsStringSync(), aggregatorScript);
        f.writeAsStringSync('#!/bin/sh\necho mine\n');
        expect(await install(), 'refused');
        expect(f.readAsStringSync(), contains('mine'));
        f.deleteSync();
        Link(f.path).createSync('/etc/hostname');
        expect(await install(), 'refused');
      },
    );

    test('says nopython with no python3', () async {
      final p = await Process.start(
        '/bin/sh',
        ['-c', aggregatorInstallCommand],
        environment: {'HOME': home, 'PATH': '/nonexistent'},
        includeParentEnvironment: false,
      );
      await p.stdin.close();
      expect((await utf8.decodeStream(p.stdout)).trim(), 'nopython');
    });
  });

  test('run command quotes every argument as one word', () {
    final c = aggregatorRunCommand(['deliver', "a'b", r'$(x)']);
    expect(c, contains(r"'a'\''b'"));
    expect(c, contains(r"'$(x)'"));
    expect(c, startsWith('python3 "\$HOME/$aggregatorDir/$aggregatorFile" '));
  });
}

/// This test process's own pid: a live process the helper finds with
/// `kill(pid, 0)`.
int get ioPid => pid;
