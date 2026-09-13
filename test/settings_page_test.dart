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
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, id) in placed) id];
}

/// Wide enough that the whole bar is built, not only what fits a phone.
Future<void> _wide(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(2000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpBar(WidgetTester tester, List<String> keys) async {
  await _wide(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: TerminalKeyBar(
          controller: KeyBarController(),
          terminal: Terminal(),
          onEmit: (_) {},
          keys: keys,
        ),
      ),
    ),
  );
}

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

      await _pumpBar(tester, keyBarSettings.shown);
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
        ]),
      });
      await keyBarSettings.load();
      expect(keyBarSettings.value, [
        (id: 'tab', shown: false),
        (id: 'divider', shown: true),
        (id: 'esc', shown: true),
        for (final id in terminalKeyBarDefault)
          if (!const {'tab', 'divider', 'esc'}.contains(id))
            (id: id, shown: true),
      ]);

      // One this build cannot read at all is the bar as it ships.
      SharedPreferences.setMockInitialValues({'sshbox.keyBar.v1': '[{oops'});
      await keyBarSettings.load();
      expect(keyBarSettings.value, KeyBarSettings.defaults);
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
        find.descendant(of: esc, matching: find.byType(Switch)),
        findsOneWidget,
      );
    });

    testWidgets('a key switched off leaves the bar, and stays off', (
      tester,
    ) async {
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));
      final esc = find.widgetWithText(ListTile, 'ESC');

      await tester.tap(find.descendant(of: esc, matching: find.byType(Switch)));
      await tester.pump();

      expect(_barOrder(tester), [..._today]..remove('esc'));
      // Its row stays, in its place, to switch back on.
      expect(esc, findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('sshbox.keyBar.v1')!) as List;
      expect(saved.first, {'id': 'esc', 'shown': false});
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

      expect(keyBarSettings.shown.take(2), ['tab', 'esc']);
      expect(_barOrder(tester).take(3), ['divider', 'tab', 'esc']);
    });

    testWidgets('Reset to default asks first, then brings the bar back', (
      tester,
    ) async {
      await keyBarSettings.choose([
        for (final item in KeyBarSettings.defaults)
          item.id == 'esc' ? (id: 'esc', shown: false) : item,
      ]);
      await _wide(tester);
      await tester.pumpWidget(const MaterialApp(home: KeyBarSettingsPage()));

      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(keyBarSettings.shown, isNot(contains('esc')));

      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      expect(keyBarSettings.value, KeyBarSettings.defaults);
      expect(_barOrder(tester), _today);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sshbox.keyBar.v1'), isNull);
    });
  });
}
