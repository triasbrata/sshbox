import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:xterm2/xterm.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    terminalSettings.value = TerminalSettings.defaultStyle;
    appTheme.value = AppTheme.defaults;
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
    expect(tickOn('Clode'), findsOneWidget);

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
}
