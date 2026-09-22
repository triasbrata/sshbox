import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/session/tmux.dart';
import 'package:sshbox/src/ui/tmux_panes.dart';
import 'package:xterm2/xterm.dart';

List<int> _line(String line) => utf8.encode('$line\n');

/// tmux's end of control mode, as far as a session needs it on attach: every
/// command gets an empty reply, in order, except the question of where things
/// stand, which gets [layout] with pane %1 active.
///
/// Given [afterCapture], a pane's history is the line `before` with the
/// cursor under it, and tmux goes straight on from answering its capture to
/// [afterCapture] in the same read.
class _FakeTmux {
  _FakeTmux(this.layout, {this.afterCapture});

  final String layout;
  final String? afterCapture;
  final _output = StreamController<Uint8List>();
  final commands = <String>[];
  var _number = 0;

  late final CommandChannel channel = (
    output: _output.stream,
    write: _answer,
    close: () {},
  );

  void say(String line) => _output.add(Uint8List.fromList(_line(line)));

  void _answer(Uint8List data) {
    for (final command in utf8.decode(data).trim().split('\n')) {
      commands.add(command);
      final number = ++_number;
      final reply = ['%begin 1789000000 $number 1'];
      if (command.startsWith('display -p "#{window_id}')) {
        reply.add('@1\t$layout\t%1');
      }
      final after = afterCapture;
      final capture = after != null && command.startsWith('capture-pane');
      if (after != null && command.startsWith('display -p -t')) {
        reply.add('0\t1\t0\t0\t1');
      }
      if (capture) reply.add('before');
      reply.add('%end 1789000000 $number 1');
      if (capture) {
        reply.add(after);
        _output.add(Uint8List.fromList(reply.expand(_line).toList()));
      } else {
        reply.forEach(say);
      }
    }
  }
}

void main() {
  test(
    "tmux copies the device's variables from the channel into its session",
    () {
      final command = TmuxSession.command('sshbox-abc');
      expect(
        command,
        contains(
          'update-environment " LC_SSHBOX_KEY LC_SSHBOX_HOST_ID '
          'LC_SSHBOX_NOTIFY_URL LC_SSHBOX_NOTIFY_SECRET FORCE_HYPERLINK"',
        ),
      );
      // A server that listed an earlier version's names gets the new ones.
      expect(
        command,
        contains('grep -q "LC_SSHBOX_NOTIFY_SECRET FORCE_HYPERLINK" ||'),
      );
      expect(command, contains('export FORCE_HYPERLINK=1; exec "\$t"'));
      expect(command, isNot(contains('LC_SSHBOX_TOKEN')));
      // The name is an argument to the script rather than part of it.
      expect(
        command,
        endsWith('new-session -A -s "\$n" 2>&1\' sh \'sshbox-abc\''),
      );
    },
  );

  test('tmux is looked for beyond PATH, and every tmux runs from there', () {
    final command = TmuxSession.command('sshbox-abc');
    // The script is one quoted argument: a quote inside would end it early.
    expect(command, startsWith("sh -c '"));
    expect(command, endsWith("' sh 'sshbox-abc'"));
    expect(
      command.substring(7, command.length - "' sh 'sshbox-abc'".length),
      isNot(contains("'")),
    );

    // PATH first, then where package managers put it, then the login shell.
    final at = [
      for (final place in [
        r't=$(command -v tmux)',
        '/opt/homebrew/bin/tmux',
        '/usr/local/bin/tmux',
        '/opt/local/bin/tmux',
        '/home/linuxbrew/.linuxbrew/bin/tmux',
        r'"$HOME/.nix-profile/bin/tmux"',
        '/run/current-system/sw/bin/tmux',
        r'"$HOME/.local/bin/tmux"',
        '/snap/bin/tmux',
        r'"$SHELL" -lc "command -v tmux" </dev/null 2>/dev/null | tail -n 1',
      ])
        command.indexOf(place),
    ];
    expect(at, everyElement(isNonNegative));
    expect(at, orderedEquals([...at]..sort()));

    expect(command, contains(r'"$t" show -gv update-environment'));
    expect(command, contains(r'exec "$t" -u -C "$@" new-session'));
    // None by name, which is what missed Homebrew's.
    expect(command.split(' '), isNot(contains('tmux')));
  });

  test('list-sessions reads into rows, a name keeping every space and '
      'quote, and what is not a row dropped', () {
    // As tmux 3.2a prints the listing, between what a shell might add.
    final sessions = TmuxSession.parseList([
      'Last login: today',
      '0 1 1789000000 1789000100 sshbox-abc',
      '2 3 1789000000 1789000300  my  "build" \$(x) `y`; z ',
      'tmux is not installed on this host (looked on PATH, in Homebrew and '
          'the other usual places)',
      '1 1 1789000000 1789000200 x',
      '1 1 notanumber 1789000200 y',
      '1 1 1789000000 1789000200 ',
    ]);
    // The session that wrote most recently first.
    expect(sessions.map((session) => session.name), [
      ' my  "build" \$(x) `y`; z ',
      'x',
      'sshbox-abc',
    ]);
    final [build, x, ours] = sessions;
    expect((build.attached, build.windows, build.inUse), (2, 3, true));
    expect((ours.attached, ours.inUse), (0, false));
    expect(x.windows, 1);
    expect(ours.created, DateTime.fromMillisecondsSinceEpoch(1789000000000));
    expect(ours.activity, DateTime.fromMillisecondsSinceEpoch(1789000100000));
  });

  test('%output unescapes to the bytes the pane wrote', () {
    final written = <int>[];
    final client = TmuxClient(
      write: (_) {},
      onOutput: (pane, data) {
        expect(pane, 3);
        written.addAll(data);
      },
      onNotification: (_) {},
    );

    // Octal for control bytes and the backslash itself; UTF-8 as it was,
    // here split across two reads of the channel.
    final e = utf8.encode('é');
    client.add([...utf8.encode(r'%output %3 \033[1mhi\134 caf'), e[0]]);
    client.add([e[1], ...utf8.encode(r'\015\012'), 0x0a]);

    expect(utf8.decode(written), '\x1b[1mhi\\ café\r\n');
  });

  test('layouts parse into a tree, both ways and nested', () {
    // Real layouts from tmux 3.2a: a left pane beside a stacked pair, then a
    // top pane over three side by side.
    final across = TmuxLayout.parse(
      'd67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}',
    );
    expect(across.sideBySide, isTrue);
    expect(across.children, hasLength(2));
    final stacked = across.children[1];
    expect(stacked.sideBySide, isFalse);
    expect(stacked.children.map((c) => (c.pane, c.y, c.height)), [
      (1, 0, 12),
      (2, 13, 11),
    ]);
    expect(across.panes.map((leaf) => (leaf.pane, leaf.x, leaf.width)), [
      (0, 0, 40),
      (1, 41, 39),
      (2, 41, 39),
    ]);

    final down = TmuxLayout.parse(
      'b268,80x24,0,0[80x12,0,0,0,80x11,0,13{40x11,0,13,1,19x11,41,13,2,'
      '19x11,61,13,3}]',
    );
    expect(down.sideBySide, isFalse);
    expect(down.children[1].sideBySide, isTrue);
    expect(down.panes.map((leaf) => leaf.pane), [0, 1, 2, 3]);
    expect(down.panes.last.x, 61);

    expect(
      () => TmuxLayout.parse('ffff,80x24,0,0{80x24,0,0'),
      throwsFormatException,
    );
  });

  test(
    'a reply goes to the command that asked, around notifications',
    () async {
      final notifications = <String>[];
      final client = TmuxClient(
        write: (_) {},
        onOutput: (_, _) {},
        onNotification: notifications.add,
      );

      final panes = client.command('list-panes -F "#{pane_id}"');
      final bogus = client.command('bogus');
      for (final line in [
        // The new-session tmux was started with: nobody here asked for it.
        '%begin 1 257 0',
        '%end 1 257 0',
        '%session-changed \$0 sshbox-test',
        '%begin 1 262 1',
        // Output that looks like a notification, inside a reply.
        '%0',
        '%end 1 262 1',
        '%layout-change @0 a87d,80x24,0,0,0 a87d,80x24,0,0,0 *',
        '%begin 1 263 1',
        'parse error: unknown command: bogus',
        '%error 1 263 1',
      ]) {
        client.add(_line(line));
      }

      expect(await panes, ['%0']);
      await expectLater(
        bogus,
        throwsA(
          isA<TmuxException>().having(
            (e) => e.message,
            'message',
            'parse error: unknown command: bogus',
          ),
        ),
      );
      expect(notifications, [
        '%session-changed \$0 sshbox-test',
        '%layout-change @0 a87d,80x24,0,0,0 a87d,80x24,0,0,0 *',
      ]);
    },
  );

  test("screen's title sequence is dropped, not printed", () async {
    final fake = _FakeTmux('b25d,80x24,0,0,1');
    final tmux = TmuxSession(
      name: 'sshbox-test',
      channel: fake.channel,
      newTerminal: Terminal.new,
      transform: (data) => data,
      onChanged: () {},
      onEnded: () {},
    );
    addTearDown(tmux.dispose);
    fake.say('%session-changed \$1 sshbox-test');
    await pumpEventQueue();

    // What zsh sends at every prompt under TERM=screen, split where two
    // reads of the pane can split it.
    fake.say(r'%output %1 \033');
    fake.say(r'%output %1 k/tmp\033\134~ $ ');
    await pumpEventQueue();

    expect(
      tmux.panes.single.terminal.buffer.lines[0].getText().trimRight(),
      r'~ $',
    );
  });

  test(
    "Claude Code's copy in a pane reaches the clipboard once, whole",
    () async {
      final fake = _FakeTmux('b25d,80x24,0,0,1');
      final copied = <String>[];
      final tmux = TmuxSession(
        name: 'sshbox-test',
        channel: fake.channel,
        newTerminal: () =>
            ClipboardTerminal()..onClipboardStore = ((_, t) => copied.add(t)),
        transform: (data) => data,
        onChanged: () {},
        onEnded: () {},
      );
      addTearDown(tmux.dispose);
      fake.say('%session-changed \$1 sshbox-test');
      await pumpEventQueue();

      // What Claude Code 2.1.278 writes inside tmux: the OSC 52, then the same
      // again in tmux's passthrough. tmux 3.2a's control mode hands both on as
      // the pane wrote them, whatever set-clipboard says — measured — in
      // pieces, as it reads them, with its octal escapes.
      final reply = List.filled(1000, 'a long reply, past 8 KB\n').join();
      final plain = '\x1b]52;c;${base64.encode(utf8.encode(reply))}\x07';
      final written = utf8.encode(
        '$plain\x1bPtmux;${plain.replaceAll('\x1b', '\x1b\x1b')}\x1b\\done',
      );
      String escaped(List<int> bytes) => [
        for (final byte in bytes)
          byte < 0x20 || byte == 0x5c
              ? '\\${byte.toRadixString(8).padLeft(3, '0')}'
              : String.fromCharCode(byte),
      ].join();
      for (var i = 0; i < written.length; i += 1000) {
        final end = (i + 1000).clamp(0, written.length);
        fake.say('%output %1 ${escaped(written.sublist(i, end))}');
      }
      await pumpEventQueue();

      expect(copied, [reply]);
      expect(
        tmux.panes.single.terminal.buffer.lines[0].getText().trimRight(),
        'done',
      );
    },
  );

  test('what a pane writes as its history is read is drawn after it', () async {
    final fake = _FakeTmux(
      'b25d,80x24,0,0,1',
      afterCapture: r'%output %1 after\015\012',
    );
    final tmux = TmuxSession(
      name: 'sshbox-test',
      channel: fake.channel,
      newTerminal: Terminal.new,
      transform: (data) => data,
      onChanged: () {},
      onEnded: () {},
    );
    addTearDown(tmux.dispose);
    fake.say('%session-changed \$1 sshbox-test');
    await pumpEventQueue();

    final lines = tmux.panes.single.terminal.buffer.lines;
    expect(
      [lines[0].getText().trimRight(), lines[1].getText().trimRight()],
      ['before', 'after'],
    );
  });

  testWidgets('two panes sit side by side, and touching one focuses it', (
    tester,
  ) async {
    // Small enough that tmux's 80 columns fit the test's screen.
    var style = const TerminalStyle(fontSize: 8);
    final fake = _FakeTmux('b25d,80x24,0,0{40x24,0,0,1,39x24,41,0,2}');
    late StateSetter rebuild;
    final tmux = TmuxSession(
      name: 'sshbox-test',
      channel: fake.channel,
      newTerminal: Terminal.new,
      transform: (data) => data,
      onChanged: () => rebuild(() {}),
      onEnded: () {},
    );
    addTearDown(tmux.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return TmuxPaneLayout(
              tmux: tmux,
              textStyle: style,
              padding: EdgeInsets.zero,
              pane: (pane, focused) => TerminalView(
                pane.terminal,
                key: ValueKey('pane ${pane.id}'),
                autoResize: false,
                textStyle: style,
              ),
            );
          },
        ),
      ),
    );
    fake.say('%session-changed \$1 sshbox-test');
    await tester.pump();
    await tester.pump();

    final left = tester.getRect(find.byKey(const ValueKey('pane 1')));
    final right = tester.getRect(find.byKey(const ValueKey('pane 2')));
    expect(left.top, right.top);
    expect(left.height, right.height);
    // tmux's border cell between them, and each terminal at its own cells.
    expect(right.left, greaterThan(left.right));
    expect(
      tmux.panes.map((p) => (p.terminal.viewWidth, p.terminal.viewHeight)),
      [(40, 24), (39, 24)],
    );
    expect(tmux.focused?.id, 1);
    // Laid out in cells measured as xterm2 measures them, or the panes drift.
    expect(
      tester
          .state<TerminalViewState>(find.byKey(const ValueKey('pane 1')))
          .renderTerminal
          .cellSize,
      terminalCellSize(style, TextScaler.noScaling),
    );

    await tester.tap(find.byKey(const ValueKey('pane 2')));
    await tester.pump();
    expect(tmux.focused?.id, 2);
    expect(fake.commands, contains('select-pane -t %2'));

    // A bigger font from Settings: every pane re-measured in the new cells,
    // and tmux told how many of them fit now.
    rebuild(() => style = const TerminalStyle(fontSize: 10));
    await tester.pump();
    final cell = terminalCellSize(style, TextScaler.noScaling);
    expect(
      tester
          .state<TerminalViewState>(find.byKey(const ValueKey('pane 1')))
          .renderTerminal
          .cellSize,
      cell,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('pane 1'))),
      Size(40 * cell.width, 24 * cell.height),
    );
    final screen = tester.getSize(find.byType(TmuxPaneLayout));
    expect(
      fake.commands.last,
      'refresh-client -C ${screen.width ~/ cell.width}x'
      '${screen.height ~/ cell.height}',
    );
  });
}
