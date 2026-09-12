import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:xterm2/xterm.dart';

/// WCAG's contrast ratio between two colours.
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

List<Color> _ansi(TerminalTheme t) => [
  t.black,
  t.red,
  t.green,
  t.yellow,
  t.blue,
  t.magenta,
  t.cyan,
  t.white,
  t.brightBlack,
  t.brightRed,
  t.brightGreen,
  t.brightYellow,
  t.brightBlue,
  t.brightMagenta,
  t.brightCyan,
  t.brightWhite,
];

/// Published colours under 2.5:1 on their own background, kept as published.
const _publishedFaint = {
  'Gruvbox light yellow',
  'Catppuccin light yellow',
  'Catppuccin light magenta',
};

void main() {
  test('Clode draws the terminal the way it did before there were themes', () {
    final clode = terminalSchemes.first;
    expect(AppTheme.defaults.scheme, same(clode));
    expect(clode.accent, const Color(0xFF4CC38A));

    // The light ANSI set it had, after VS Code's Light+.
    const lightAnsi = [
      0xFF000000, 0xFFCD3131, 0xFF107C10, 0xFF946F00, //
      0xFF0451A5, 0xFFBC05BC, 0xFF0A7F9E, 0xFF555555,
      0xFF666666, 0xFFE04848, 0xFF148F14, 0xFFA88400,
      0xFF2A6FD6, 0xFFC837C8, 0xFF0A93B3, 0xFF8C8C8C,
    ];
    for (final brightness in Brightness.values) {
      // Background, text, cursor and selection came from the app's colours.
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
            ..._ansi(theme),
          ])
            c.toARGB32(),
        ],
        [
          app.surfaceContainerLow.toARGB32(),
          app.onSurface.toARGB32(),
          app.primary.toARGB32(),
          app.primary.withValues(alpha: 0.35).toARGB32(),
          if (brightness == Brightness.dark)
            for (final c in _ansi(TerminalThemes.defaultTheme)) c.toARGB32()
          else
            ...lightAnsi,
        ],
        reason: '$brightness',
      );
    }
  });

  test('text, the six main colours and the accent read in every theme', () {
    for (final scheme in terminalSchemes) {
      for (final brightness in Brightness.values) {
        final theme = scheme.terminal(brightness);
        final where = '${scheme.name} ${brightness.name}';
        expect(
          ThemeData.estimateBrightnessForColor(theme.background),
          brightness,
          reason: where,
        );
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
            greaterThanOrEqualTo(
              _publishedFaint.contains('$where $name') ? 2 : 2.5,
            ),
            reason: '$where $name',
          );
        }
        // The Ctrl-link underline and the focused tmux pane's border.
        final accent = ColorScheme.fromSeed(
          seedColor: scheme.accent,
          brightness: brightness,
        ).primary;
        expect(
          _contrast(accent, theme.background),
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
