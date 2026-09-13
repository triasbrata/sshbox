import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:xterm2/xterm.dart';

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

  testWidgets('with no push token yet, copying says push is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    final copy = find.text('Copy notification token');
    // The page's own list, not the preview terminal's.
    await tester.scrollUntilVisible(
      copy,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Why the row is there at all, when hosts get the token by themselves.
    expect(find.textContaining('LC_SSHBOX_TOKEN'), findsOneWidget);

    await tester.tap(copy);
    // A frame for the toast's overlay, one to start its slide, and the slide.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('No FCM token yet — push is unavailable'), findsOneWidget);
    // The toast's countdown run out, rather than left running past the test.
    await tester.pumpAndSettle();
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
            combo: (key: 'R', ctrl: true, alt: false, shift: false),
          ),
        ),
        (id: 'custom:d', custom: (label: 'F13', send: r'\e[1;2P', combo: null)),
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
      const combo = (key: 'R', ctrl: true, alt: true, shift: false);
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
      expect(key.combo, (key: r'\', ctrl: false, alt: true, shift: false));
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
            combo: (key: '→', ctrl: true, alt: false, shift: false),
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
          combo: (key: '→', ctrl: false, alt: true, shift: false),
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
        _shown('Pick a key, with Ctrl, Alt or Shift if you like'),
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
          combo: (key: 'L', ctrl: true, alt: false, shift: false),
        ),
      ));
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
