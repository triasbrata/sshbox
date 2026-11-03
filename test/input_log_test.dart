import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/telemetry/input_log.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/chat/claude_chat.dart' show ChatModel;
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:xterm2/xterm.dart' show Terminal, TerminalView;

import 'log_messages.dart';

/// A fresh log and key handler per test, so what one prints never leaks in.
late AppLog log;
late InputLog input;

Future<void> pump(WidgetTester tester, Widget child) async {
  log = AppLog(maxLines: 50);
  input = InputLog(log, settle: const Duration(milliseconds: 10));
  HardwareKeyboard.instance.addHandler(input.onKey);
  addTearDown(() => HardwareKeyboard.instance.removeHandler(input.onKey));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

Future<void> type(WidgetTester tester, String text) async {
  for (final unit in text.split('')) {
    final key =
        LogicalKeyboardKey.findKeyByKeyId(unit.toLowerCase().codeUnitAt(0)) ??
        LogicalKeyboardKey.keyA;
    await tester.sendKeyDownEvent(key, character: unit);
    await tester.sendKeyUpEvent(key);
  }
}

/// What the log holds, each line without its timestamp and level.
List<String> lines() => log.current.isEmpty
    ? []
    : log.current
          .split('\n')
          .map((l) => l.split(' ').skip(2).join(' '))
          .toList();

Future<void> settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 50));

void main() {
  const secret = 'hunter2Zq';

  testWidgets(
    'typing in the terminal logs no character, a Home key is a line',
    (tester) async {
      await pump(tester, TerminalView(ClipboardTerminal(), autofocus: true));
      await tester.pump();
      await type(tester, secret);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await settle(tester);
      expect(lines(), ['key Home (terminal)']);
    },
  );

  testWidgets('typing in a plain field logs no character, an arrow is a line', (
    tester,
  ) async {
    await pump(tester, const TextField(autofocus: true));
    await tester.pump();
    await type(tester, secret);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(lines(), ['key Left (field)']);
  });

  testWidgets('an obscured field logs nothing, not even Backspace', (
    tester,
  ) async {
    await pump(tester, const TextField(autofocus: true, obscureText: true));
    await tester.pump();
    await type(tester, secret);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await settle(tester);
    expect(log.current, isEmpty);
  });

  testWidgets('a held key is one line with a count', (tester) async {
    await pump(tester, const TextField(autofocus: true));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(lines(), ['key Down (field) ×5']);
  });

  group('labelOf', () {
    KeyEvent down(LogicalKeyboardKey key, [String? character]) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );
    String? label(
      KeyEvent e, {
      bool ctrl = false,
      bool alt = false,
      bool meta = false,
      bool shift = false,
    }) => InputLog.labelOf(e, ctrl: ctrl, alt: alt, meta: meta, shift: shift);

    test('Ctrl+V is a line even where the platform names the letter', () {
      expect(label(down(LogicalKeyboardKey.keyV, 'v'), ctrl: true), 'Ctrl+V');
      expect(label(down(LogicalKeyboardKey.keyV, 'v'), meta: true), 'Meta+V');
    });

    test('a chord of Ctrl or Meta is a line, with the keys it names', () {
      expect(
        label(down(LogicalKeyboardKey.keyC, '\x03'), ctrl: true),
        'Ctrl+C',
      );
      expect(label(down(LogicalKeyboardKey.keyK), meta: true), 'Meta+K');
      expect(
        label(down(LogicalKeyboardKey.f5), ctrl: true, shift: true),
        'Ctrl+Shift+F5',
      );
    });

    test('a printable AltGr or Option combination is never a line', () {
      // AltGr+Q makes @ on a German layout; Windows spells AltGr as Ctrl+Alt.
      expect(
        label(down(LogicalKeyboardKey.keyQ, '@'), ctrl: true, alt: true),
        isNull,
      );
      expect(label(down(LogicalKeyboardKey.keyQ, '@'), alt: true), isNull);
      // Option+E on a Mac, a dead key with no character at all.
      expect(label(down(LogicalKeyboardKey.keyE), alt: true), isNull);
      expect(label(down(LogicalKeyboardKey.keyE, 'é'), alt: true), isNull);
      // Ctrl+Alt with no character is still how AltGr is spelt.
      expect(
        label(down(LogicalKeyboardKey.keyQ), ctrl: true, alt: true),
        isNull,
      );
    });

    test('a letter, a digit, a modifier alone and a key up are no line', () {
      expect(label(down(LogicalKeyboardKey.keyA, 'a')), isNull);
      expect(label(down(LogicalKeyboardKey.digit1, '1'), shift: true), isNull);
      expect(label(down(LogicalKeyboardKey.keyA)), isNull);
      expect(label(down(LogicalKeyboardKey.controlLeft), ctrl: true), isNull);
      expect(
        label(
          KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.home,
            logicalKey: LogicalKeyboardKey.home,
            timeStamp: Duration.zero,
          ),
        ),
        isNull,
      );
    });

    test('Alt with a named key is a line, as Option+Left is', () {
      expect(label(down(LogicalKeyboardKey.arrowLeft), alt: true), 'Alt+Left');
    });
  });

  group('pastes', () {
    test('a paste logs its kind and size, never its content', () {
      log = AppLog();
      input = InputLog(log);
      input.paste('terminal', 'text', 9);
      input.paste('chat', 'image', 1);
      input.paste('terminal', 'files', 2);
      expect(
        log.current.split('\n').map((l) => l.split(' ').skip(2).join(' ')),
        [
          'paste text 9 (terminal)',
          'paste image 1 (chat)',
          'paste files 2 (terminal)',
        ],
      );
    });

    test('a terminal text paste is logged once, by length', () {
      final before = appLog.length;
      ClipboardTerminal().paste('secret-clipboard');
      final line = appLog.current.split('\n').last;
      expect(appLog.length, before + 1);
      expect(line, contains('paste text <50 (terminal)'));
      expect(logMessages(line), isNot(contains('secret')));
    });

    test('a muted paste is not logged twice', () {
      final before = appLog.length;
      mutePasteLog(() => ClipboardTerminal().paste('abc'));
      expect(appLog.length, before);
    });

    testWidgets('Ctrl+V in a field logs the paste with no amount and no read', (
      tester,
    ) async {
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method != 'Clipboard.getData') return null;
          reads++;
          return <String, dynamic>{'text': 'password123'};
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      // The field's own paste reads the clipboard; only the log's read counts.
      await pump(
        tester,
        Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyV, control: true):
                DoNothingIntent(),
          },
          child: const TextField(autofocus: true),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(lines(), contains('paste text (field)'));
      expect(reads, 0, reason: 'the log must not read the clipboard');
    });
  });

  test('the buffer stays bounded under a flood of keys', () {
    final bounded = AppLog(maxLines: 20, maxBytes: 2000);
    final flood = InputLog(bounded);
    for (var i = 0; i < 500; i++) {
      flood.paste('terminal', 'text', i);
    }
    expect(bounded.length, lessThanOrEqualTo(20));
    expect(bounded.current.length, lessThanOrEqualTo(2000));
  });

  testWidgets('a dialog is a route line by kind, never its content', (
    tester,
  ) async {
    final before = appLog.length;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [LogRoutes()],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const Text('private words'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final added = appLog.current.split('\n').skip(before).join('\n');
    expect(added, contains('route open popup DialogRoute'));
    expect(logMessages(added), isNot(contains('private words')));
  });

  test('a setting logs its choice as a value, and no host text', () async {
    SharedPreferences.setMockInitialValues({});
    final before = appLog.length;
    await TerminalSettings().choose(size: 15);
    await chatEnterSends.choose(true);
    final added = appLog.current.split('\n').skip(before).join('\n');
    expect(added, contains('setting terminal font'));
    expect(added, contains('setting chat enter sends true'));
  });

  testWidgets('Shift+Insert in a field logs a text paste', (tester) async {
    await pump(tester, const TextField(autofocus: true));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(lines(), contains('paste text (field)'));
    expect(lines(), contains('key Shift+Insert (field)'));
  });

  test('the copy-on-select setting logs its value', () async {
    SharedPreferences.setMockInitialValues({});
    final before = appLog.length;
    await CopyOnSelectSetting().choose(false);
    final added = appLog.current.split('\n').skip(before).join('\n');
    expect(added, contains('setting copy on select false'));
  });

  testWidgets("tapping the key bar's symbol keys logs no character", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TerminalKeyBar(
            controller: KeyBarController(),
            terminal: Terminal(),
            onEmit: (_) {},
            keys: const ['esc', '-', '/', '|', '~', ':', '*'],
          ),
        ),
      ),
    );
    final before = appLog.length;
    for (final symbol in ['-', '/', '|', '~', ':', '*']) {
      await tester.tap(find.text(symbol));
    }
    await tester.tap(find.text('ESC'));
    final added = appLog.current.split('\n').skip(before).toList();
    expect(added.where((l) => l.contains('tap symbol key')), hasLength(6));
    final messages = logMessages(added.join('\n'));
    for (final symbol in ['-', '/', '|', '~', ':', '*']) {
      expect(
        messages.replaceAll('symbol key', '').replaceAll('tap ', ''),
        isNot(contains(symbol)),
        reason: 'the log holds "$symbol"',
      );
    }
    expect(messages, contains('tap ESC'), reason: 'a named key still logs');
  });

  test('a terminal paste logs a size bucket, never the exact length', () {
    for (final (length, bucket) in [
      (16, '<50'),
      (49, '<50'),
      (50, '<500'),
      (499, '<500'),
      (500, '<5000'),
      (4999, '<5000'),
      (5000, '5000+'),
    ]) {
      final before = appLog.length;
      ClipboardTerminal().paste('x' * length);
      final line = appLog.current.split('\n').last;
      expect(appLog.length, before + 1);
      expect(
        line,
        contains('paste text $bucket (terminal)'),
        reason: '$length',
      );
      expect(line, isNot(contains(' $length ')), reason: 'the length leaks');
    }
  });

  test('the chat send log names a model it knows, and never a host id', () {
    expect(ChatModel.logName(null), 'model unknown');
    expect(ChatModel.logName('claude-opus-5-5'), 'Opus 5.5');
    expect(ChatModel.logName('corp-model-xyz-internal'), 'other');
    expect(ChatModel.logName('claude-opus-5-5-hostname'), 'other');
  });

  test('the chat send log names only the model families it offers', () {
    expect(ChatModel.logName('claude-acmeinternal-1'), 'other');
    expect(ChatModel.logName('claude-default-5'), 'other');
    expect(ChatModel.logName('claude-haiku-4-5-20251001'), 'Haiku 4.5');
    expect(ChatModel.logName('claude-sonnet-5-5[1m]'), 'Sonnet 5.5');
    expect(ChatModel.logName('claude-fable-5-1'), 'Fable 5.1');
    expect(ChatModel.logName('opus'), 'Opus');
    expect(ChatModel.logName('default'), 'Default');
  });

  test('a scroll run to the program says how many wheel reports left, and '
      'where the last landed', () {
    log = AppLog(maxLines: 50);
    input = InputLog(log);
    // JEANSH-H: routed to the program, and nothing sent.
    input.scroll('wheel → program as wheel (session 1 pane %0, grid 80x24)');
    input.scroll('wheel → program as wheel (session 1 pane %0, grid 80x24)');
    input.flush();
    input.scroll('wheel → program as wheel (session 1 pane %0, grid 80x24)');
    input.wheelSent(12, 7);
    input.wheelSent(13, 30);
    input.flush();
    // Another route says nothing of it, and a report with no scroll held
    // counts into no line.
    input.wheelSent(1, 1);
    input.scroll('wheel → scrollback (session 1, grid 80x24)');
    input.wheelSent(2, 2);
    input.flush();
    expect(lines(), [
      'scroll wheel → program as wheel (session 1 pane %0, grid 80x24) ×2, '
          'sent 0',
      'scroll wheel → program as wheel (session 1 pane %0, grid 80x24), '
          'sent 2 at 13;30',
      'scroll wheel → scrollback (session 1, grid 80x24)',
    ]);
  });
}
