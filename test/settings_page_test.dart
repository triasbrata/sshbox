import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/notifications/notify_key.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:xterm2/xterm.dart';

import 'fake_relay.dart';

/// The terminal's key bar as it has always been: the divider after files and
/// upload, then every key in its place.
const _today = [
  'divider', 'esc', 'tab', 'ctrl', 'alt', //
  'divider', 'left', 'down', 'up', 'right', 'space',
  'divider', 'ctrl-c', 'ctrl-d', 'ctrl-z',
  'divider', 'home', 'end', 'pgup', 'pgdn',
  'divider', '-', '/', '|', '~', ':', '*',
];

/// What the key bar on screen shows, left to right, by id.
List<String> _barOrder(WidgetTester tester) {
  Finder inBar(Finder finder) =>
      find.descendant(of: find.byType(TerminalKeyBar), matching: finder);
  final dividers = inBar(find.byType(VerticalDivider));
  final placed = [
    for (var i = 0; i < dividers.evaluate().length; i++)
      (tester.getCenter(dividers.at(i)).dx, keyBarDivider),
    for (final MapEntry(key: id, value: key) in terminalKeys.entries)
      if (inBar(find.text(key.label)).evaluate().isNotEmpty)
        (tester.getCenter(inBar(find.text(key.label))).dx, id),
    for (final MapEntry(key: id, value: key)
        in keyBarSettings.customKeys.entries)
      if (inBar(find.text(key.label)).evaluate().isNotEmpty)
        (tester.getCenter(inBar(find.text(key.label))).dx, id),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, id) in placed) id];
}

/// Wide enough that the whole bar is built, not only what fits a phone.
Future<void> _wide(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(2000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpBar(
  WidgetTester tester,
  List<String> keys, {
  Map<String, CustomKey> customKeys = const {},
  void Function(String data)? onEmit,
}) async {
  await _wide(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: TerminalKeyBar(
          controller: KeyBarController(),
          terminal: Terminal(),
          onEmit: onEmit ?? (_) {},
          keys: keys,
          customKeys: customKeys,
        ),
      ),
    ),
  );
}

/// Opens Add key and picks [choice] from it.
Future<void> _addFromSheet(WidgetTester tester, String choice) async {
  await tester.tap(find.text('Add key'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(BottomSheet), matching: find.text(choice)),
  );
  // Settled, which also sits out the toast that says where it went.
  await tester.pumpAndSettle();
}

/// The picker's cap that reads [label].
Finder _cap(String label) => find.descendant(
  of: find.byType(Dialog),
  matching: find.widgetWithText(KeyButton, label),
);

/// The combination as the picker shows it.
Finder _shown(String text) =>
    find.descendant(of: find.byType(Dialog), matching: find.text(text));

final _labelField = find.widgetWithText(TextField, 'Label');

String _labelText(WidgetTester tester) =>
    tester.widget<TextField>(_labelField).controller!.text;

/// Whether the picker's Add or Save can be pressed.
bool _canSave(WidgetTester tester, String button) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, button))
        .onPressed !=
    null;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    terminalSettings.value = TerminalSettings.defaultStyle;
    appTheme.value = AppTheme.defaults;
    keyBarSettings.value = KeyBarSettings.defaults;
    keyBarSettings.macLayout = false;
  });

  testWidgets('saves the theme picked, and the next start reads it back', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    expect(appTheme.value, AppTheme.defaults);

    // A card for every theme, the one in use ticked.
    for (final scheme in terminalSchemes) {
      expect(find.text(scheme.name), findsOneWidget);
    }
    Finder tickOn(String name) => find.descendant(
      of: find.widgetWithText(Card, name),
      matching: find.byIcon(Icons.check_circle),
    );
    expect(tickOn('Jeansh'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.tap(find.text('Dracula'));
    await tester.pump();
    final dracula = terminalSchemes.firstWhere((s) => s.name == 'Dracula');
    expect(appTheme.value, (mode: ThemeMode.light, scheme: dracula));
    expect(tickOn('Dracula'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    appTheme.value = AppTheme.defaults;
    await appTheme.load();
    expect(appTheme.value, (mode: ThemeMode.light, scheme: dracula));
  });

  testWidgets('lists every font in its own face, and saves the one picked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));

    for (final font in terminalFonts) {
      final row = find.ancestor(
        of: find.textContaining(font.label, findRichText: true),
        matching: find.byType(ListTile),
      );
      expect(row, findsOneWidget, reason: font.label);
      // The sample under the name is drawn in that font.
      final sample = tester.widget<Text>(
        find.descendant(of: row, matching: find.byType(Text)).last,
      );
      expect(sample.style?.fontFamily, font.family);
    }
    expect(find.widgetWithText(ListTile, 'Font size'), findsOneWidget);
    // The preview is a terminal of its own, in the chosen style.
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle,
      TerminalSettings.defaultStyle,
    );

    await tester.tap(find.textContaining('JetBrains Mono', findRichText: true));
    await tester.pump();
    expect(terminalSettings.value.fontFamily, 'JetBrains Mono');
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle,
      terminalStyleOf('JetBrains Mono', 13),
    );

    // All the way right is the largest size.
    await tester.drag(find.byType(Slider), const Offset(1000, 0));
    await tester.pump();
    expect(terminalSettings.value.fontSize, maxFontSize);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sshbox.terminal.fontFamily'), 'JetBrains Mono');
    expect(prefs.getDouble('sshbox.terminal.fontSize'), maxFontSize);

    // And it is what the next start reads.
    terminalSettings.value = TerminalSettings.defaultStyle;
    await terminalSettings.load();
    expect(terminalSettings.value, terminalStyleOf('JetBrains Mono', 24));
  });

  test('a font no longer bundled gives way to the default', () async {
    SharedPreferences.setMockInitialValues({
      'sshbox.terminal.fontFamily': 'Comic Mono',
      'sshbox.terminal.fontSize': 99.0,
    });
    await terminalSettings.load();
    expect(terminalSettings.value, terminalStyleOf('monospace', maxFontSize));
  });

  test('every font falls back to the Nerd Font for prompt glyphs', () {
    for (final font in terminalFonts) {
      final fallback = terminalStyleOf(font.family, 13).fontFamilyFallback;
      expect(fallback.first, 'CaskaydiaCove Nerd Font Mono');
      // Then xterm2's own, which ends at the system's monospace.
      expect(fallback, contains('monospace'));
    }
  });

  test('every bundled family is declared under that name in pubspec.yaml', () {
    // A name that drifts from the pubspec's draws in the system font, and
    // nothing else would say so.
    final declared = RegExp(
      r'^\s*- family: (.+)$',
      multiLine: true,
    ).allMatches(File('pubspec.yaml').readAsStringSync()).map((m) => m[1]);
    for (final font in terminalFonts.where((f) => f.family != 'monospace')) {
      expect(declared, contains(font.family));
    }
  });

  group('reset notification keys', () {
    late FakeRelay relay;
    late NotifyKeys notifyKeys;

    /// Settings, down at the row, with the dialog it opens up, and two hosts
    /// with a key each.
    Future<void> openDialog(WidgetTester tester) async {
      relay = FakeRelay();
      notifyKeys = NotifyKeys(InMemorySecretStore(), relay: relay);
      await notifyKeys.useFcmToken('fcm-token');
      await notifyKeys.forConnect('host-1');
      await notifyKeys.forConnect('host-2');
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(notifyKeys: notifyKeys)),
      );
      // A host's own key is copied from its page, not from here.
      expect(find.text('Copy notification key'), findsNothing);
      final reset = find.text('Reset notification keys');
      await tester.scrollUntilVisible(
        reset,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // The scroll stops as soon as the row is built, which a list builds a
      // little past its bottom edge: on a short window the last section can be
      // in the tree and still under the fold, where a tap misses it.
      await tester.ensureVisible(reset);
      await tester.pump();
      await tester.tap(reset);
      await tester.pumpAndSettle();
    }

    /// Resets in the dialog, and waits for the toast that says how it went.
    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('asks first, saying servers holding an old key stop until '
        'their host reconnects', (tester) async {
      await openDialog(tester);
      expect(
        find.textContaining('Servers holding an old key stop notifying'),
        findsOneWidget,
      );
      expect(
        find.textContaining('until their host reconnects'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(relay.revoked, isEmpty);
      expect(await notifyKeys.valueFor('host-1'), isNotNull);
    });

    testWidgets("revokes every host's key and drops it", (tester) async {
      await openDialog(tester);
      final ids = relay.registered.map((r) => r.keyId);
      await confirm(tester);
      expect(relay.revoked, ids);
      expect(await notifyKeys.valueFor('host-1'), isNull);
      expect(await notifyKeys.valueFor('host-2'), isNull);
      expect(find.textContaining('Notification keys reset'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('with the relay out of reach, hands the old keys to no host '
        'and leaves them to be revoked later', (tester) async {
      await openDialog(tester);
      final ids = relay.registered.map((r) => r.keyId).toList();
      relay.down = true;
      await confirm(tester);
      expect(await notifyKeys.valueFor('host-1'), isNull);
      expect(
        find.textContaining('Some old keys are not revoked yet'),
        findsOneWidget,
      );

      relay.down = false;
      await notifyKeys.useFcmToken('fcm-token');
      expect(relay.revoked, ids);
      await tester.pumpAndSettle();
    });
  });

  group('key bar', () {
    testWidgets('with nothing saved, the bar is the one it has always been', (
      tester,
    ) async {
      await keyBarSettings.load();
      expect(keyBarSettings.value, KeyBarSettings.defaults);

      await _pumpBar(tester, keyBarSettings.keys);
      expect(_barOrder(tester), _today);
    });

    testWidgets('a divider never doubles up, leads or trails', (tester) async {
      await _pumpBar(tester, [
        'divider', 'esc', 'divider', 'divider', 'tab', 'divider', //
      ]);
      expect(_barOrder(tester), ['divider', 'esc', 'divider', 'tab']);
    });

    test('a saved bar drops ids it does not know, and gains keys added since',
        () async {
      SharedPreferences.setMockInitialValues({
        'sshbox.keyBar.v1': jsonEncode([
          {'id': 'tab', 'shown': false},
          {'id': 'f13', 'shown': true},
          {'id': 'divider', 'shown': true},
          {'id': 'esc', 'shown': true},
          {'id': 'tab', 'shown': true},
          {'id': 'custom:a', 'shown': true, 'label': 'LS', 'send': r'ls\n'},
          // A custom key with nothing to type is no key.
          {'id': 'custom:b', 'shown': true, 'label': 'X'},
          {
            'id': 'custom:c',
            'shown': true,
            'label': '^R',
            'send': '\x12',
            'combo': 'Ctrl+R',
          },
          // A key a later version has: its text is what it types here.
          {
            'id': 'custom:d',
            'shown': true,
            'label': 'F13',
            'send': r'\e[1;2P',
            'combo': 'F13',
          },
          // One picked on the macOS layout.
          {
            'id': 'custom:e',
            'shown': true,
            'label': '⌘←',
            'send': '\x01',
            'combo': 'Super+←',
            'layout': 'mac',
          },
        ]),
      });
      await keyBarSettings.load();
      expect(keyBarSettings.value, [
        (id: 'divider', custom: null),
        (id: 'esc', custom: null),
        (id: 'custom:a', custom: (label: 'LS', send: r'ls\n', combo: null)),
        (
          id: 'custom:c',
          custom: (
            label: '^R',
            send: '\x12',
            combo: (key: 'R', ctrl: true, alt: false, shift: false, superKey: false, mac: false),
          ),
        ),
        (id: 'custom:d', custom: (label: 'F13', send: r'\e[1;2P', combo: null)),
        (
          id: 'custom:e',
          custom: (
            label: '⌘←',
            send: '\x01',
            combo: (
              key: '←',
              ctrl: false,
              alt: false,
              shift: false,
              superKey: true,
              mac: true,
            ),
          ),
        ),
        // TAB stays off, as its first entry has it; the rest are new to it.
        for (final id in terminalKeyBarDefault)
          if (!const {'tab', 'divider', 'esc'}.contains(id))
            (id: id, custom: null),
      ]);

      // One this build cannot read at all is the bar as it ships.
      SharedPreferences.setMockInitialValues({'sshbox.keyBar.v1': '[{oops'});
      await keyBarSettings.load();
      expect(keyBarSettings.value, KeyBarSettings.defaults);
    });

    test('a key hidden by the switch before is off the bar now', () async {
      // v1's list as the switches left it: ESC, and the divider after ALT,
      // switched off.
      const hidden = {0, 4};
      SharedPreferences.setMockInitialValues({
        'sshbox.keyBar.v1': jsonEncode([
          for (final (i, id) in terminalKeyBarDefault.indexed)
            {'id': id, 'shown': !hidden.contains(i)},
        ]),
      });
      await keyBarSettings.load();
      expect(keyBarSettings.keys, [
        for (final (i, id) in terminalKeyBarDefault.indexed)
          if (!hidden.contains(i)) id,
      ]);
    });

    testWidgets('Keyboard › Key bar opens every item under a preview', (
      tester,
    ) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      final row = find.text('Key bar');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.byType(KeyBarSettingsPage), findsOneWidget);
      expect(_barOrder(tester), _today);
      final esc = find.widgetWithText(ListTile, 'ESC');
      expect(
        find.descendant(of: esc, matching: find.byIcon(Icons.drag_handle)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: esc, matching: find.byTooltip('Remove')),
        findsOneWidget,
      );
      // Taken off rather than hidden: no switch is left.
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Add key'), findsOneWidget);
    });

    testWidgets('a key removed leaves the bar and stays off, and Add key puts '
        'it back on the end', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      final esc = find.widgetWithText(ListTile, 'ESC');

      await tester.tap(find.descendant(of: esc, matching: find.byTooltip('Remove')));
      await tester.pump();

      expect(_barOrder(tester), [..._today]..remove('esc'));
      expect(esc, findsNothing);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('sshbox.keyBar.v1')!) as List;
      expect(saved, contains(equals({'id': 'esc', 'shown': false})));
      // Not taken, at the next start, for a key a later version added.
      await keyBarSettings.load();
      expect(keyBarSettings.keys, isNot(contains('esc')));

      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
      // Offered as the bar draws it, and alone: the rest are on the bar.
      final offered = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(KeyButton),
      );
      expect(offered, findsOneWidget);
      expect(
        find.descendant(of: offered, matching: find.text('ESC')),
        findsOneWidget,
      );
      await tester.tap(offered);
      await tester.pumpAndSettle();

      expect(keyBarSettings.keys.last, 'esc');
      expect(_barOrder(tester), [..._today]..remove('esc')..add('esc'));
    });

    testWidgets('a divider goes on as many times as you like', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      await _addFromSheet(tester, 'Divider');
      await _addFromSheet(tester, 'Divider');

      expect(keyBarSettings.keys, [
        ...terminalKeyBarDefault,
        keyBarDivider,
        keyBarDivider,
      ]);
    });

    testWidgets('a key of your own, picked on the keyboard, joins the bar and '
        'sends the combination', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      await _addFromSheet(tester, 'Custom key…');
      // No text to type what it sends, and nothing to add until a key is
      // picked.
      expect(find.widgetWithText(TextField, 'Sends'), findsNothing);
      expect(_canSave(tester, 'Add'), isFalse);

      await tester.tap(find.widgetWithText(FilterChip, 'Ctrl'));
      await tester.tap(find.widgetWithText(FilterChip, 'Alt'));
      await tester.pump();
      expect(_shown('Ctrl+Alt+…'), findsOneWidget);
      expect(_canSave(tester, 'Add'), isFalse);

      await tester.tap(_cap('r'));
      await tester.pump();
      expect(_shown('Ctrl+Alt+R'), findsOneWidget);
      expect(_labelText(tester), 'M-^R');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final id = keyBarSettings.keys.last;
      expect(id, startsWith('custom:'));
      const combo = (key: 'R', ctrl: true, alt: true, shift: false, superKey: false, mac: false);
      expect(keyBarSettings.customKeys, {
        id: (label: 'M-^R', send: '\x1b\x12', combo: combo),
      });
      expect(_barOrder(tester).last, id);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('sshbox.keyBar.v1')!) as List;
      expect(
        saved,
        contains(
          equals({
            'id': id,
            'shown': true,
            'label': 'M-^R',
            'send': '\x1b\x12',
            'combo': 'Ctrl+Alt+R',
          }),
        ),
      );

      final sent = <String>[];
      await _pumpBar(
        tester,
        keyBarSettings.keys,
        customKeys: keyBarSettings.customKeys,
        onEmit: sent.add,
      );
      await tester.tap(find.text('M-^R'));
      expect(sent, ['\x1b\x12']);
    });

    testWidgets('on a phone the picker scrolls to every key, Shift shows what '
        'it types, and a label written by hand stays', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      await _addFromSheet(tester, 'Custom key…');

      await tester.enterText(_labelField, 'BS');
      await tester.tap(find.widgetWithText(FilterChip, 'Shift'));
      await tester.pump();
      expect(_cap('@'), findsOneWidget);
      expect(_cap('2'), findsNothing);

      final keys = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(_cap('F12'), 100, scrollable: keys);
      await tester.tap(_cap('F12'));
      await tester.pump();
      expect(_shown('Shift+F12'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'Shift'));
      await tester.tap(find.widgetWithText(FilterChip, 'Alt'));
      await tester.scrollUntilVisible(_cap(r'\'), -100, scrollable: keys);
      await tester.tap(_cap(r'\'));
      await tester.pump();
      expect(_shown(r'Alt+\'), findsOneWidget);
      expect(_labelText(tester), 'BS');

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final key = keyBarSettings.customKeys.values.single;
      expect(key.label, 'BS');
      expect(key.combo, (key: r'\', ctrl: false, alt: true, shift: false, superKey: false, mac: false));
      // Escaped, for an earlier version to read back as ESC and a backslash.
      expect(decodeKeyText(key.send), '\x1b\\');
    });

    testWidgets('a key of your own opens in the picker showing its '
        'combination, and its label follows a change', (tester) async {
      await keyBarSettings.choose([
        (
          id: 'custom:a',
          custom: (
            label: 'C-→',
            send: '\x1b[1;5C',
            combo: (key: '→', ctrl: true, alt: false, shift: false, superKey: false, mac: false),
          ),
        ),
        ...KeyBarSettings.defaults,
      ]);
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      // Its combination, under its label.
      expect(find.widgetWithText(ListTile, 'Ctrl+→'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'C-→'));
      await tester.pumpAndSettle();
      expect(find.text('Change custom key'), findsOneWidget);
      expect(_shown('Ctrl+→'), findsOneWidget);
      expect(tester.widget<KeyButton>(_cap('→')).active, isTrue);

      await tester.tap(find.widgetWithText(FilterChip, 'Ctrl'));
      await tester.tap(find.widgetWithText(FilterChip, 'Alt'));
      await tester.pump();
      expect(_shown('Alt+→'), findsOneWidget);
      expect(_labelText(tester), 'M-→');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(keyBarSettings.value.first, (
        id: 'custom:a',
        custom: (
          label: 'M-→',
          send: '\x1b[1;3C',
          combo: (key: '→', ctrl: false, alt: true, shift: false, superKey: false, mac: false),
        ),
      ));
    });

    testWidgets('a key made before the picker still types its text, and opens '
        'in the picker empty with its label kept', (tester) async {
      await keyBarSettings.choose([
        (id: 'custom:a', custom: (label: 'LS', send: r'ls\n', combo: null)),
        ...KeyBarSettings.defaults,
      ]);
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      final sent = <String>[];
      await _pumpBar(
        tester,
        keyBarSettings.keys,
        customKeys: keyBarSettings.customKeys,
        onEmit: sent.add,
      );
      await tester.tap(find.text('LS'));
      expect(sent, ['ls\r']);

      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      // Its text, as written, under its label.
      expect(find.widgetWithText(ListTile, r'ls\n'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'LS'));
      await tester.pumpAndSettle();
      expect(find.text('Change custom key'), findsOneWidget);
      expect(
        _shown('Pick a key, with Ctrl, Alt, Shift or Super if you like'),
        findsOneWidget,
      );
      expect(_labelText(tester), 'LS');
      expect(_canSave(tester, 'Save'), isFalse);

      await tester.tap(find.widgetWithText(FilterChip, 'Ctrl'));
      await tester.tap(_cap('l'));
      await tester.pump();
      expect(_labelText(tester), 'LS');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(keyBarSettings.value.first, (
        id: 'custom:a',
        custom: (
          label: 'LS',
          send: '\x0c',
          combo: (key: 'L', ctrl: true, alt: false, shift: false, superKey: false, mac: false),
        ),
      ));
    });

    testWidgets('Clear lets go of the key, every modifier and the label, and '
        'the next key fills the label in again', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      await _addFromSheet(tester, 'Custom key…');

      for (final name in ['Ctrl', 'Alt', 'Shift', 'Super']) {
        await tester.tap(find.widgetWithText(FilterChip, name));
      }
      await tester.tap(_cap('F5'));
      await tester.pump();
      expect(_shown('Ctrl+Alt+Shift+Super+F5'), findsOneWidget);
      // Super is for apps that read extended keys, and the picker says so.
      expect(find.textContaining('extended keys'), findsOneWidget);
      await tester.enterText(_labelField, 'MINE');
      expect(_canSave(tester, 'Add'), isTrue);

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(
        _shown('Pick a key, with Ctrl, Alt, Shift or Super if you like'),
        findsOneWidget,
      );
      expect(
        tester.widgetList<FilterChip>(find.byType(FilterChip)).map(
          (chip) => chip.selected,
        ),
        everyElement(isFalse),
      );
      expect(
        tester
            .widgetList<KeyButton>(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byType(KeyButton),
              ),
            )
            .where((key) => key.active),
        isEmpty,
      );
      expect(find.textContaining('extended keys'), findsNothing);
      expect(_labelText(tester), isEmpty);
      expect(_canSave(tester, 'Add'), isFalse);

      await tester.tap(_cap('F5'));
      await tester.pump();
      expect(_labelText(tester), 'F5');
    });

    testWidgets('the macOS layout names the modifiers the Mac way, is kept '
        'for the next key, and a key picked on it reopens on it', (
      tester,
    ) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      await _addFromSheet(tester, 'Custom key…');

      await tester.tap(find.widgetWithText(FilterChip, 'Alt'));
      await tester.tap(_cap('b'));
      await tester.pump();
      expect(_labelText(tester), 'M-b');

      await tester.tap(find.text('macOS'));
      await tester.pump();
      expect(find.widgetWithText(FilterChip, 'Alt'), findsNothing);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '⌥ Option'))
            .selected,
        isTrue,
      );
      // The combination, and the label it filled in.
      expect(_shown('⌥B'), findsNWidgets(2));
      expect(_labelText(tester), '⌥B');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sshbox.keyBar.layout'), 'mac');

      // ⌘⌫ deletes the line, with a plain control character: no word about
      // extended keys.
      await tester.tap(find.widgetWithText(FilterChip, '⌥ Option'));
      await tester.tap(find.widgetWithText(FilterChip, '⌘ Command'));
      await tester.tap(_cap('⌫'));
      await tester.pump();
      expect(_labelText(tester), '⌘⌫');
      expect(find.textContaining('extended keys'), findsNothing);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final id = keyBarSettings.keys.last;
      const combo = (
        key: 'BKSP',
        ctrl: false,
        alt: false,
        shift: false,
        superKey: true,
        mac: true,
      );
      expect(keyBarSettings.customKeys[id], (
        label: '⌘⌫',
        send: '\x15',
        combo: combo,
      ));
      final saved = jsonDecode(prefs.getString('sshbox.keyBar.v1')!) as List;
      expect(
        saved,
        contains(
          equals({
            'id': id,
            'shown': true,
            'label': '⌘⌫',
            'send': '\x15',
            'combo': 'Super+BKSP',
            'layout': 'mac',
          }),
        ),
      );
      // The next start reads both back.
      keyBarSettings.macLayout = false;
      await keyBarSettings.load();
      expect(keyBarSettings.customKeys[id]!.combo, combo);
      expect(keyBarSettings.macLayout, isTrue);
      // It went on the end, out of sight below the rest.
      await tester.drag(
        find.byType(ReorderableListView),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, '⌘⌫').first);
      await tester.pumpAndSettle();
      expect(find.text('Change custom key'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '⌘ Command'))
            .selected,
        isTrue,
      );
      expect(tester.widget<KeyButton>(_cap('⌫')).active, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // A new key opens on the layout last picked, and PC is kept too.
      await _addFromSheet(tester, 'Custom key…');
      expect(find.widgetWithText(FilterChip, '⌃ Control'), findsOneWidget);
      await tester.tap(find.text('PC'));
      await tester.pump();
      expect(find.widgetWithText(FilterChip, 'Ctrl'), findsOneWidget);
      expect(prefs.getString('sshbox.keyBar.layout'), 'pc');
    });

    testWidgets('a key of your own removed is deleted, with an Undo', (
      tester,
    ) async {
      const ls = (
        id: 'custom:a',
        custom: (label: 'LS', send: r'ls\n', combo: null),
      );
      await keyBarSettings.choose([ls, ...KeyBarSettings.defaults]);
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'LS'),
          matching: find.byTooltip('Remove'),
        ),
      );
      // A frame for the toast's overlay, one to start its slide, and the slide.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(keyBarSettings.customKeys, isEmpty);
      expect(find.text('Deleted LS'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(keyBarSettings.value, [ls, ...KeyBarSettings.defaults]);
    });

    testWidgets('a key dragged by its handle moves along the bar', (
      tester,
    ) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      final esc = find.widgetWithText(ListTile, 'ESC');
      final height = tester.getSize(esc).height;

      // Down into the lower half of TAB, the row below: that is when the list
      // puts it after TAB. A whole row exactly leaves it level with TAB's top,
      // which still counts as before it.
      final drag = await tester.startGesture(
        tester.getCenter(
          find.descendant(of: esc, matching: find.byIcon(Icons.drag_handle)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await drag.moveBy(Offset(0, height * 0.75));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(keyBarSettings.keys.take(2), ['tab', 'esc']);
      expect(_barOrder(tester).take(3), ['divider', 'tab', 'esc']);
    });

    testWidgets('Reset to default asks first, then brings the bar back, '
        'custom keys gone', (tester) async {
      await keyBarSettings.choose([
        for (final item in KeyBarSettings.defaults)
          if (item.id != 'esc') item,
        (id: 'custom:a', custom: (label: 'LS', send: r'ls\n', combo: null)),
      ]);
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(keyBarSettings.keys, isNot(contains('esc')));
      expect(keyBarSettings.customKeys, isNotEmpty);

      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      expect(keyBarSettings.value, KeyBarSettings.defaults);
      expect(keyBarSettings.customKeys, isEmpty);
      expect(_barOrder(tester), _today);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sshbox.keyBar.v1'), isNull);
    });
  });
}
