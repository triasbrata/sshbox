import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:xterm2/xterm.dart';

/// WCAG's contrast ratio between two colours.
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

ColorScheme _scheme(Color seed, Brightness brightness) =>
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

void main() {
  final green = appPalettes.first.seed;

  test('a light scheme gives a light terminal, a dark one a dark terminal', () {
    for (final brightness in Brightness.values) {
      final theme = terminalThemeOf(_scheme(green, brightness));
      expect(
        ThemeData.estimateBrightnessForColor(theme.background),
        brightness,
      );
    }
    // Dark keeps the ANSI colours the terminal always had.
    final dark = terminalThemeOf(_scheme(green, Brightness.dark));
    expect(dark.red, TerminalThemes.defaultTheme.red);
    expect(dark.brightWhite, TerminalThemes.defaultTheme.brightWhite);
  });

  test('the cursor follows the palette', () {
    final cursors = {
      for (final palette in appPalettes)
        terminalThemeOf(_scheme(palette.seed, Brightness.dark)).cursor,
    };
    expect(cursors, hasLength(appPalettes.length));
    final blue = _scheme(appPalettes[2].seed, Brightness.light);
    expect(terminalThemeOf(blue).cursor, blue.primary);
  });

  test('text and the six main colours read in every palette, light and dark', () {
    for (final brightness in Brightness.values) {
      for (final palette in appPalettes) {
        final theme = terminalThemeOf(_scheme(palette.seed, brightness));
        final where = '${palette.name}, $brightness';
        expect(
          _contrast(theme.foreground, theme.background),
          greaterThanOrEqualTo(4.5),
          reason: where,
        );
        for (final (name, color) in [
          ('red', theme.red),
          ('green', theme.green),
          ('yellow', theme.yellow),
          ('blue', theme.blue),
          ('magenta', theme.magenta),
          ('cyan', theme.cyan),
        ]) {
          expect(
            _contrast(color, theme.background),
            greaterThanOrEqualTo(3),
            reason: '$name, $where',
          );
        }
      }
    }
  });

  test('the same scheme gives back the same theme', () {
    // A new one would have xterm2 re-shape every glyph on every rebuild.
    final theme = terminalThemeOf(_scheme(green, Brightness.dark));
    expect(terminalThemeOf(_scheme(green, Brightness.dark)), same(theme));
  });
}
