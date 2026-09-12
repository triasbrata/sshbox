import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';

/// WCAG's contrast ratio between two colours.
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  test('Clode keeps the terminal surface, text and cursor it had before '
      'there were themes', () {
    final clode = terminalSchemes.first;
    expect(AppTheme.defaults.scheme, same(clode));
    expect(clode.accent, const Color(0xFF4CC38A));

    for (final brightness in Brightness.values) {
      // The app's colours then: Material's default scheme from the accent.
      final app = ColorScheme.fromSeed(
        seedColor: clode.accent,
        brightness: brightness,
      );
      final theme = clode.terminal(brightness);
      expect(
        [
          for (final c in [
            theme.background,
            theme.foreground,
            theme.cursor,
            theme.selection,
          ])
            c.toARGB32(),
        ],
        [
          app.surfaceContainerLow.toARGB32(),
          app.onSurface.toARGB32(),
          app.primary.toARGB32(),
          app.primary.withValues(alpha: 0.35).toARGB32(),
        ],
        reason: '$brightness',
      );
    }
  });

  test('text, every colour and the accent read in every theme', () {
    for (final scheme in terminalSchemes) {
      for (final brightness in Brightness.values) {
        final theme = scheme.terminal(brightness);
        final where = '${scheme.name} ${brightness.name}';
        expect(
          ThemeData.estimateBrightnessForColor(theme.background),
          brightness,
          reason: where,
        );
        // Black on dark and white on light are left out: programs paint
        // backgrounds with them.
        for (final (name, color, least) in [
          ('text', theme.foreground, 7.0),
          ('red', theme.red, 4.5),
          ('green', theme.green, 4.5),
          ('yellow', theme.yellow, 4.5),
          ('blue', theme.blue, 4.5),
          ('magenta', theme.magenta, 4.5),
          ('cyan', theme.cyan, 4.5),
          ('bright red', theme.brightRed, 4.5),
          ('bright green', theme.brightGreen, 4.5),
          ('bright yellow', theme.brightYellow, 4.5),
          ('bright blue', theme.brightBlue, 4.5),
          ('bright magenta', theme.brightMagenta, 4.5),
          ('bright cyan', theme.brightCyan, 4.5),
          // Comments, dim text and zsh's autosuggestions.
          ('bright black', theme.brightBlack, 3.0),
        ]) {
          expect(
            _contrast(color, theme.background),
            greaterThanOrEqualTo(least),
            reason: '$where $name',
          );
        }

        final app = scheme.colorScheme(brightness);
        expect(
          _contrast(app.onSurface, app.surface),
          greaterThanOrEqualTo(7),
          reason: '$where app text',
        );
        expect(
          _contrast(app.primary, app.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$where app accent',
        );
        // The Ctrl-link underline and the focused tmux pane's border.
        expect(
          _contrast(app.primary, theme.background),
          greaterThanOrEqualTo(3),
          reason: '$where accent',
        );
      }
    }
  });

  test('every theme has its own red, green and blue, and its own accent', () {
    for (final brightness in Brightness.values) {
      for (final (i, a) in terminalSchemes.indexed) {
        for (final b in terminalSchemes.skip(i + 1)) {
          final x = a.terminal(brightness);
          final y = b.terminal(brightness);
          final pair = '${a.name}, ${b.name}, ${brightness.name}';
          expect(x.red, isNot(y.red), reason: '$pair red');
          expect(x.green, isNot(y.green), reason: '$pair green');
          expect(x.blue, isNot(y.blue), reason: '$pair blue');
        }
      }
    }
    // A new pick must change the app's theme: that is what repaints every
    // terminal. And the id is what is saved.
    expect(
      terminalSchemes.map((s) => s.accent).toSet(),
      hasLength(terminalSchemes.length),
    );
    expect(
      terminalSchemes.map((s) => s.id).toSet(),
      hasLength(terminalSchemes.length),
    );
  });

  test('the same theme and brightness give back the same terminal theme', () {
    // A new one would have xterm2 re-shape every glyph on every rebuild.
    final nord = terminalSchemes[2];
    expect(nord.terminal(Brightness.dark), same(nord.dark));
    expect(nord.terminal(Brightness.light), same(nord.light));
  });

  group('the theme picked', () {
    tearDown(() => appTheme.value = AppTheme.defaults);

    test('is saved by its id, and the next start reads it back', () async {
      SharedPreferences.setMockInitialValues({});
      final dracula = terminalSchemes.firstWhere((s) => s.id == 'dracula');
      await appTheme.choose(scheme: dracula);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sshbox.theme.scheme'), 'dracula');

      appTheme.value = AppTheme.defaults;
      await appTheme.load();
      expect(appTheme.value.scheme, same(dracula));
    });

    test('is Clode when none is saved, or one no longer offered', () async {
      // An earlier version's palette is not read.
      SharedPreferences.setMockInitialValues({'sshbox.theme.seed': 0xFF4A8FE7});
      appTheme.value = (mode: ThemeMode.dark, scheme: terminalSchemes.last);
      await appTheme.load();
      expect(appTheme.value.scheme, same(terminalSchemes.first));

      SharedPreferences.setMockInitialValues({'sshbox.theme.scheme': 'gone'});
      appTheme.value = (mode: ThemeMode.dark, scheme: terminalSchemes.last);
      await appTheme.load();
      expect(appTheme.value.scheme, same(terminalSchemes.first));
    });
  });
}
