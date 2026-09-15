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
  test('Jeansh puts the green it always had on the denim of its icon', () {
    final clode = terminalSchemes.first;
    expect(AppTheme.defaults.scheme, same(clode));
    expect(clode.accent, const Color(0xFF4CC38A));
    expect(clode.neutral, const Color(0xFF373964));

    for (final brightness in Brightness.values) {
      // The terminal's colours are taken the way they were before there were
      // themes, from Material's default scheme of a seed: its surface and
      // text from the denim, in the variant whose greys keep its hue, and its
      // cursor and selection from the green, as they always were.
      final denim = ColorScheme.fromSeed(
        seedColor: clode.neutral!,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
      );
      final green = ColorScheme.fromSeed(
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
          denim.surfaceContainerLow.toARGB32(),
          denim.onSurface.toARGB32(),
          green.primary.toARGB32(),
          green.primary.withValues(alpha: 0.35).toARGB32(),
        ],
        reason: '$brightness',
      );

      // The app: the denim's surfaces under the green's accents.
      final app = clode.colorScheme(brightness);
      ColorScheme medium(Color seed, DynamicSchemeVariant variant) =>
          ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
            dynamicSchemeVariant: variant,
            contrastLevel: 0.5,
          );
      final cloth = medium(clode.neutral!, DynamicSchemeVariant.vibrant);
      final accent = medium(clode.accent, DynamicSchemeVariant.content);
      expect(app.surface, cloth.surface, reason: '$brightness');
      expect(app.surfaceContainerLow, cloth.surfaceContainerLow);
      expect(app.onSurface, cloth.onSurface);
      expect(app.primary, accent.primary, reason: '$brightness');
      expect(app.primaryContainer, accent.primaryContainer);
    }

    // Every other theme's app is still its accent's alone.
    for (final scheme in terminalSchemes.skip(1)) {
      expect(scheme.neutral, isNull, reason: scheme.name);
    }
  });

  test('the frame sits behind the terminal and the page, in every theme', () {
    for (final scheme in terminalSchemes) {
      for (final brightness in Brightness.values) {
        final app = scheme.colorScheme(brightness);
        final terminal = scheme.terminal(brightness).background;
        final where = '${scheme.name} ${brightness.name}';
        // The tab strip and key bars are dimmer than what they frame, so the
        // terminal is the brightest thing on screen...
        expect(
          app.chrome.computeLuminance(),
          lessThan(terminal.computeLuminance()),
          reason: '$where terminal',
        );
        // ...and in the dark, dimmer than every other page too.
        if (brightness == Brightness.dark) {
          expect(
            app.chrome.computeLuminance(),
            lessThan(app.surface.computeLuminance()),
            reason: '$where page',
          );
        }
        // A key on the bar still stands out from it.
        expect(
          _contrast(app.chromeKey, app.chrome),
          greaterThan(1.2),
          reason: '$where keys',
        );
      }
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

    test('is Jeansh when none is saved, or one no longer offered', () async {
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
