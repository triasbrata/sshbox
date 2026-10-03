import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/telemetry/input_log.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:xterm2/xterm.dart' show TerminalView;

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
      expect(line, contains('paste text 16 (terminal)'));
      expect(line, isNot(contains('secret')));
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
    expect(added, isNot(contains('private words')));
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
}
