// Where Jeansh meets termul, its design system: TUI-Termul/termul at
// df2cacf9d140f8c74220f2879bc7ee53b2b6a758, whose components live in
// termul/ as they are upstream, under its MIT licence (termul/LICENSE).
//
// This file only feeds them: termul's palette tokens grown from each of
// Jeansh's themes, light and dark — termul's own Paper, Paper Dark and
// Phosphor as termul has them — the app's ThemeData built on termul's, and
// termul's licence and credit for the app to show.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'terminal_schemes.dart';
import 'termul/termul_palette.dart';
import 'termul/termul_theme.dart';

export 'termul/components.dart';
export 'termul/termul_palette.dart';
export 'termul/termul_theme.dart';

/// Where Jeansh's look comes from, and who made it: what Settings › About
/// credits.
const termulUrl = 'https://github.com/TUI-Termul/termul';
const termulAuthorUrl = 'https://github.com/iyanqalbi';

/// termul's licence, as its repository states it.
const termulLicense = '''
MIT License

Copyright (c) 2026 TUI-Termul

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

/// Puts [termulLicense] on the licences page beside every package's: the
/// licence asks for its notice in every copy, and a build is one. termul is
/// no package of the build, so nothing else would. Called once, by `main`.
void registerTermulLicense() => LicenseRegistry.addLicense(
  () =>
      Stream.value(const LicenseEntryWithLineBreaks(['termul'], termulLicense)),
);

/// WCAG's contrast ratio between two colours, a translucent one taken over
/// [over] as it would be drawn.
double tuiContrast(Color a, Color b, {Color? over}) {
  if (over != null) {
    a = Color.alphaBlend(a, over);
    b = Color.alphaBlend(b, over);
  }
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

/// [color], lightened on a dark [ground] or darkened on a light one, hue and
/// saturation kept, just until it reads at [ratio] on it.
Color tuiContrasted(Color color, Color ground, double ratio) {
  final lighten = ground.computeLuminance() < .5;
  var hsl = HSLColor.fromColor(color);
  while (tuiContrast(hsl.toColor(), ground) < ratio) {
    final l = hsl.lightness + (lighten ? .01 : -.01);
    if (l < 0 || l > 1) break;
    hsl = hsl.withLightness(l);
  }
  return hsl.toColor();
}

/// termul's palette for [scheme] in [brightness]; Jeansh's own theme when
/// [scheme] is null.
///
/// Paper and Phosphor are termul's own palettes, as termul has them. The
/// rest are grown in termul's shape from the theme's terminal colours: the
/// page is the terminal's background, and so are the bars; a light theme's
/// boxes are paper-white over it and a dark one's a step up; hairlines are
/// the ink at 15% or 20%. Every colour that is read as text — the ink's
/// muted and dim greys, the accent, the deep accent and the ANSI colours —
/// is moved away from the page, hue kept, until it reads at 4.5:1 on every
/// layer it can sit on.
TermulPalette termulPaletteOf(TerminalScheme? scheme, Brightness brightness) {
  scheme ??= terminalSchemes.first;
  final light = brightness == Brightness.light;
  final own = switch ((scheme.id, light)) {
    ('paper', true) => TermulPalette.paper,
    ('paper', false) => TermulPalette.paperDark,
    ('phosphor', false) => TermulPalette.phosphor,
    _ => null,
  };
  if (own != null) return _readable(own);

  final t = scheme.terminal(brightness);
  final bg = t.background;
  final fg = t.foreground;
  Color mix(double f) => Color.lerp(bg, fg, f)!;
  final panel = light ? Color.lerp(bg, Colors.white, .8)! : mix(.05);
  final accent = scheme.accent;
  return _readable(
    TermulPalette(
      bg: bg,
      panel: panel,
      sidebar: bg,
      surface: light ? panel : mix(.1),
      border: fg.withValues(alpha: light ? .15 : .2),
      text: fg,
      muted: Color.lerp(fg, bg, .2)!,
      dim: Color.lerp(fg, bg, .45)!,
      accent: accent,
      deep: light ? tuiContrasted(accent, bg, 9) : fg,
      green: t.green,
      yellow: t.yellow,
      red: t.red,
      blue: t.blue,
      cyan: t.cyan,
      magenta: t.magenta,
      selection: accent.withValues(alpha: light ? .1 : .2),
    ),
  );
}

/// [p] with every colour read as text pushed to 4.5:1 on each layer.
TermulPalette _readable(TermulPalette p) {
  final grounds = [
    p.bg,
    p.panel,
    p.sidebar,
    p.surface,
    Color.alphaBlend(p.selection, p.panel),
    Color.alphaBlend(p.selection, p.bg),
  ];
  Color ink(Color c) {
    for (var i = 0; i < 2; i++) {
      for (final ground in grounds) {
        c = tuiContrasted(c, ground, 4.5);
      }
    }
    return c;
  }

  return TermulPalette(
    bg: p.bg,
    panel: p.panel,
    sidebar: p.sidebar,
    surface: p.surface,
    border: p.border,
    text: ink(p.text),
    muted: ink(p.muted),
    dim: ink(p.dim),
    accent: ink(p.accent),
    deep: ink(p.deep),
    green: ink(p.green),
    yellow: ink(p.yellow),
    red: ink(p.red),
    blue: ink(p.blue),
    cyan: ink(p.cyan),
    magenta: ink(p.magenta),
    selection: p.selection,
  );
}

/// Material's roles filled from [p], for the widgets termul has no
/// component for yet (see the `TODO(termul)` comments), so they sit in the
/// same colours.
ColorScheme termulColorScheme(TermulPalette p) {
  final brightness = p.isLight ? Brightness.light : Brightness.dark;
  Color wash(Color c) => Color.lerp(p.panel, c, .2)!;
  // The ink on a wash, kept at 4.5:1 on it as every ink is on the layers.
  Color on(Color c) => tuiContrasted(p.text, wash(c), 4.5);
  final onAccent = p.isLight ? p.panel : p.bg;
  return ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: onAccent,
    primaryContainer: wash(p.accent),
    onPrimaryContainer: on(p.accent),
    secondary: p.deep,
    onSecondary: p.isLight ? p.panel : p.bg,
    secondaryContainer: Color.alphaBlend(p.selection, p.panel),
    onSecondaryContainer: p.text,
    tertiary: p.magenta,
    onTertiary: onAccent,
    tertiaryContainer: wash(p.magenta),
    onTertiaryContainer: on(p.magenta),
    error: p.red,
    onError: onAccent,
    errorContainer: wash(p.red),
    onErrorContainer: on(p.red),
    surface: p.bg,
    onSurface: p.text,
    surfaceDim: p.bg,
    surfaceBright: p.panel,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.sidebar,
    surfaceContainer: p.panel,
    surfaceContainerHigh: p.surface,
    surfaceContainerHighest: p.surface,
    onSurfaceVariant: p.muted,
    outline: p.border,
    outlineVariant: p.border,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: p.text,
    onInverseSurface: p.bg,
    inversePrimary: Color.lerp(p.accent, p.bg, .5)!,
    surfaceTint: Colors.transparent,
  );
}

/// The app's theme: termul's own ([TermulTheme.of]), with Material's
/// widgets that termul has no component for yet drawn flat, square and in
/// its colours.
ThemeData jeanshTheme(TermulPalette p) {
  final base = TermulTheme.of(p);
  final text = base.textTheme;
  const square = RoundedRectangleBorder();
  final edged = RoundedRectangleBorder(side: BorderSide(color: p.border));
  OutlineInputBorder hairline([Color? color]) => OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: color ?? p.border),
  );
  final label = text.labelSmall!.copyWith(
    fontWeight: FontWeight.w500,
    letterSpacing: 0.4,
  );
  const buttonPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 6);

  return base.copyWith(
    colorScheme: termulColorScheme(p),
    canvasColor: p.bg,
    highlightColor: p.selection,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.accent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      titleTextStyle: text.titleMedium!.copyWith(color: p.accent),
      iconTheme: IconThemeData(color: p.accent, size: 20),
      actionsIconTheme: IconThemeData(color: p.accent, size: 20),
      shape: Border(bottom: BorderSide(color: p.border)),
    ),
    iconTheme: IconThemeData(color: p.accent),
    cardTheme: CardThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: edged,
    ),
    // TODO(termul): dialogs termul has no TuiDialog shape for yet keep
    // Material's, in TuiDialog's colours.
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: square,
      titleTextStyle: text.labelSmall!.copyWith(
        color: p.accent,
        letterSpacing: 0.4,
      ),
      contentTextStyle: text.bodyMedium,
    ),
    // TODO(termul): bottom sheet (gap 2).
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      modalBackgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: Border(top: BorderSide(color: p.border)),
      dragHandleColor: p.dim,
      dragHandleSize: const Size(28, 3),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: square,
      endShape: Border(left: BorderSide(color: p.border)),
    ),
    // TODO(termul): popup / context menu (gap 3).
    popupMenuTheme: PopupMenuThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: edged,
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(edged),
      ),
    ),
    // TODO(termul): tooltip (gap 4).
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
      ),
      textStyle: text.bodySmall,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: square,
        padding: buttonPadding,
        textStyle: label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: square,
        padding: buttonPadding,
        textStyle: label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: square,
        side: BorderSide(color: p.border),
        padding: buttonPadding,
        textStyle: label,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: square, foregroundColor: p.accent),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.isLight ? p.panel : p.bg,
      elevation: 0,
      shape: square,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: square,
        side: BorderSide(color: p.border),
        selectedBackgroundColor: p.accent,
        selectedForegroundColor: p.isLight ? p.panel : p.bg,
        textStyle: label,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: edged,
      side: BorderSide(color: p.border),
      backgroundColor: p.surface,
      selectedColor: Color.alphaBlend(p.selection, p.panel),
      labelStyle: text.bodySmall,
    ),
    // TuiField's box, for the fields not yet moved to it.
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: p.panel,
      border: hairline(),
      enabledBorder: hairline(),
      focusedBorder: hairline(p.accent),
      errorBorder: hairline(p.deep),
      focusedErrorBorder: hairline(p.deep),
      disabledBorder: hairline(),
      labelStyle: TextStyle(color: p.muted),
      floatingLabelStyle: TextStyle(color: p.accent),
      hintStyle: TextStyle(color: p.dim),
      helperStyle: text.bodySmall!.copyWith(color: p.muted),
      errorStyle: text.bodySmall!.copyWith(color: p.deep),
    ),
    listTileTheme: ListTileThemeData(
      shape: square,
      selectedColor: p.accent,
      selectedTileColor: p.selection,
      iconColor: p.accent,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall!.copyWith(color: p.muted),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: square,
      collapsedShape: square,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: square,
      side: BorderSide(color: p.dim, width: 1.5),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.border,
      circularTrackColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.accent,
      unselectedLabelColor: p.muted,
      indicatorColor: p.accent,
      dividerColor: p.border,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: .3),
      selectionHandleColor: p.accent,
    ),
  );
}

/// A word along the top of termul's pages — ← BACK, SAVE — with the name a
/// finder or a screen reader knows it by, [label], as written.
class TermulTextAction extends StatelessWidget {
  const TermulTextAction({
    super.key,
    required this.label,
    required this.text,
    required this.onTap,
    this.color,
  });

  /// The page's own back, as termul's pages have it.
  factory TermulTextAction.back(BuildContext context) => TermulTextAction(
    label: 'Back',
    text: '← BACK',
    color: TermulThemeData.of(context).palette.dim,
    onTap: () => Navigator.of(context).maybePop(),
  );

  final String label;
  final String text;
  final VoidCallback? onTap;

  /// The accent when left out.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    // TODO(termul): tooltip (gap 4).
    return Tooltip(
      message: label,
      child: Semantics(
        container: true,
        button: true,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelSmall!.copyWith(
                color: onTap == null ? p.dim : color ?? p.accent,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
