// Jeansh's look, taken from Termul, a Flutter TUI component kit:
// https://github.com/TUI-Termul/termul at 17107128dfd15089570ea49aa1b10986133d30c7
// (lib/theme/termul_palette.dart, lib/theme/termul_theme.dart,
// lib/components/tui_badge.dart, tui_button.dart's TuiKeyHint and tui_tabs.dart),
// and its Paper, Paper Dark and Phosphor palettes at
// df2cacf9d140f8c74220f2879bc7ee53b2b6a758 (lib/theme/termul_palette.dart),
// which are two of the themes in terminal_schemes.dart,
// adapted: the palette grows from each of Jeansh's own themes, light and dark,
// instead of Termul's three fixed dark ones, every colour meant for text is
// pushed to 4.5:1, the font is the bundled JetBrains Mono rather than
// google_fonts, and the Material widgets the app already uses are themed to
// match rather than replaced.
//
// Its MIT notice is [termulLicense] below: kept with the code, and shipped in
// every build on the licences page by [registerTermulLicense].

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

import 'terminal_schemes.dart';

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

/// The app's font: monospaced everywhere, as a terminal's own chrome is.
/// Bundled, so every platform draws the same. The symbols it lacks come from
/// the bundled Noto Sans Symbols 2, as in the terminal.
const tuiFontFamily = 'JetBrains Mono';
const _tuiFallback = ['Noto Sans Symbols 2'];

/// The layers a theme draws itself, where it has them — termul's own
/// palettes do — instead of the steps between the background and the text
/// that [TuiPalette.of] makes for the rest.
typedef TuiLayers = ({Color sidebar, Color panel, Color surface});

/// Termul's tokens, grown from one of Jeansh's themes in one brightness: the
/// terminal's own background and text, and layers between them, so the
/// chrome around a shell is the shell's own colour.
@immutable
class TuiPalette {
  const TuiPalette({
    required this.brightness,
    required this.bg,
    required this.sidebar,
    required this.panel,
    required this.surface,
    required this.raised,
    required this.border,
    required this.strongBorder,
    required this.text,
    required this.muted,
    required this.accent,
    required this.selection,
    required this.green,
    required this.yellow,
    required this.red,
    required this.blue,
    required this.cyan,
    required this.magenta,
  });

  /// From [theme], the terminal's colours, and [accent], the theme's own.
  ///
  /// Each layer is the background moved a little towards the text, so light
  /// and dark themes step the same way. Every colour that is read as text —
  /// the accent, the muted grey, the ANSI ones — is moved away from the
  /// background, hue kept, until it reads at 4.5:1 on the layer nearest to
  /// it; the terminal's text is already 7:1.
  factory TuiPalette.of(
    TerminalTheme theme,
    Color accent,
    Brightness brightness, [
    TuiLayers? layers,
  ]) {
    final bg = theme.background;
    final fg = theme.foreground;
    Color mix(double t) => Color.lerp(bg, fg, t)!;
    final raised = mix(.13);
    // A selected row is washed with the accent, so it is the other layer
    // text must read on; both lie on the same side of the text.
    final selection = Color.lerp(bg, tuiContrasted(accent, raised, 4.5), .14)!;
    Color readable(Color c) =>
        tuiContrasted(tuiContrasted(c, raised, 4.5), selection, 4.5);
    final ink = readable(accent);
    return TuiPalette(
      brightness: brightness,
      bg: bg,
      sidebar: layers?.sidebar ?? mix(.035),
      panel: layers?.panel ?? mix(.06),
      surface: layers?.surface ?? mix(.09),
      raised: raised,
      border: mix(.2),
      strongBorder: tuiContrasted(mix(.4), bg, 3),
      text: fg,
      muted: readable(mix(.68)),
      accent: ink,
      selection: selection,
      green: readable(theme.green),
      yellow: readable(theme.yellow),
      red: readable(theme.red),
      blue: readable(theme.blue),
      cyan: readable(theme.cyan),
      magenta: readable(theme.magenta),
    );
  }

  final Brightness brightness;

  /// The page, the terminal's own background.
  final Color bg;

  /// The strip, the app bar and the key bar.
  final Color sidebar;

  /// Cards, sheets and dialogs.
  final Color panel;

  /// A layer up from a panel: toasts, menus.
  final Color surface;

  /// The highest: a key on the bar, a badge.
  final Color raised;

  /// Card edges and dividers.
  final Color border;

  /// A field's edge: 3:1 on the page, as anything to be found must be.
  final Color strongBorder;
  final Color text;

  /// Secondary text, 4.5:1 on every layer.
  final Color muted;

  /// The theme's accent as text: 4.5:1 on every layer.
  final Color accent;

  /// A selected row, and the accent's faint wash.
  final Color selection;
  final Color green;
  final Color yellow;
  final Color red;
  final Color blue;
  final Color cyan;
  final Color magenta;

  /// Material's roles, filled from the tokens, so every stock widget the app
  /// uses picks them up.
  ColorScheme get colorScheme {
    Color wash(Color c) => Color.lerp(bg, c, .2)!;
    return ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: bg,
      primaryContainer: wash(accent),
      onPrimaryContainer: text,
      secondary: blue,
      onSecondary: bg,
      secondaryContainer: selection,
      onSecondaryContainer: text,
      tertiary: magenta,
      onTertiary: bg,
      tertiaryContainer: wash(magenta),
      onTertiaryContainer: text,
      error: red,
      onError: bg,
      errorContainer: wash(red),
      onErrorContainer: text,
      surface: bg,
      onSurface: text,
      surfaceDim: bg,
      surfaceBright: raised,
      surfaceContainerLowest: bg,
      surfaceContainerLow: sidebar,
      surfaceContainer: panel,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: raised,
      onSurfaceVariant: muted,
      outline: strongBorder,
      outlineVariant: border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: text,
      onInverseSurface: bg,
      inversePrimary: Color.lerp(accent, bg, .5)!,
      // Flat, as a terminal is: no layer tinted by how high it sits.
      surfaceTint: Colors.transparent,
    );
  }
}

/// WCAG's contrast ratio between two colours.
double tuiContrast(Color a, Color b) {
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

/// The palette for pages to reach: `Tui.of(context).palette`.
@immutable
class Tui extends ThemeExtension<Tui> {
  const Tui(this.palette);

  final TuiPalette palette;

  /// Jeansh's own theme where a page is shown without the app's, as in a
  /// test of one page.
  static TuiPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<Tui>()?.palette ??
        terminalSchemes.first.palette(theme.brightness);
  }

  @override
  Tui copyWith({TuiPalette? palette}) => Tui(palette ?? this.palette);

  @override
  Tui lerp(Tui? other, double t) => t < .5 || other == null ? this : other;
}

/// A form's or a settings list's padding in a page [width] wide: 16 either
/// side on a phone, and on anything wider a column no more than 720 across in
/// the middle, so a line of help text stays short enough to read.
EdgeInsets tuiFormPadding(
  double width, {
  double top = 16,
  double bottom = 32,
  double least = 16,
}) {
  final side = math.max(least, (width - 720) / 2);
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

/// Square, one line wide: every edge in the app.
OutlinedBorder tuiShape([Color? side]) => RoundedRectangleBorder(
  side: side == null ? BorderSide.none : BorderSide(color: side),
);

/// The whole app's theme from [p]: square corners, one-pixel edges, flat
/// layers, a monospaced face, and a press that shows as a flat highlight
/// rather than a ripple.
ThemeData tuiTheme(TuiPalette p) {
  final scheme = p.colorScheme;
  final base = ThemeData(brightness: p.brightness, useMaterial3: true);
  // Termul's sizes, a step under Material's, since a monospaced glyph is
  // wider; tracking off, which a fixed pitch does not want.
  TextStyle? size(TextStyle? s, double px, [FontWeight? w]) =>
      s?.copyWith(fontSize: px, fontWeight: w, letterSpacing: 0);
  final t = base.textTheme;
  final text =
      TextTheme(
        displayLarge: size(t.displayLarge, 44),
        displayMedium: size(t.displayMedium, 36),
        displaySmall: size(t.displaySmall, 30),
        headlineLarge: size(t.headlineLarge, 26, FontWeight.w700),
        headlineMedium: size(t.headlineMedium, 23, FontWeight.w700),
        headlineSmall: size(t.headlineSmall, 20, FontWeight.w700),
        titleLarge: size(t.titleLarge, 18, FontWeight.w700),
        titleMedium: size(t.titleMedium, 15, FontWeight.w700),
        titleSmall: size(t.titleSmall, 13, FontWeight.w700),
        bodyLarge: size(t.bodyLarge, 15),
        bodyMedium: size(t.bodyMedium, 13.5),
        bodySmall: size(t.bodySmall, 12),
        labelLarge: size(t.labelLarge, 13, FontWeight.w700),
        labelMedium: size(t.labelMedium, 12),
        labelSmall: size(t.labelSmall, 11),
      ).apply(
        fontFamily: tuiFontFamily,
        fontFamilyFallback: _tuiFallback,
        bodyColor: p.text,
        displayColor: p.text,
      );
  final label = text.labelLarge;
  final square = tuiShape();
  final edged = tuiShape(p.border);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
  OutlineInputBorder field(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    fontFamily: tuiFontFamily,
    fontFamilyFallback: _tuiFallback,
    textTheme: text,
    primaryTextTheme: text,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.selection,
    hoverColor: p.selection.withValues(alpha: .6),
    focusColor: p.selection,
    visualDensity: VisualDensity.standard,
    extensions: [Tui(p)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.sidebar,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      titleTextStyle: text.titleMedium,
      shape: Border(bottom: BorderSide(color: p.border)),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.all(6),
      shape: edged,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: tuiShape(p.strongBorder),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      modalBackgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: Border(top: BorderSide(color: p.strongBorder)),
      dragHandleColor: p.muted,
      dragHandleSize: const Size(28, 3),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: square,
      endShape: Border(left: BorderSide(color: p.border)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: tuiShape(p.strongBorder),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(2),
        shape: WidgetStatePropertyAll(tuiShape(p.strongBorder)),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        shape: WidgetStatePropertyAll(tuiShape(p.strongBorder)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.raised,
        border: Border.all(color: p.strongBorder),
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
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: square,
        elevation: 0,
        padding: buttonPadding,
        textStyle: label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: square,
        foregroundColor: p.text,
        side: BorderSide(color: p.strongBorder),
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
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: square),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.bg,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: square,
      extendedTextStyle: label,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: square,
        side: BorderSide(color: p.strongBorder),
        selectedBackgroundColor: p.accent,
        selectedForegroundColor: p.bg,
        textStyle: label,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: edged,
      side: BorderSide(color: p.border),
      backgroundColor: p.surface,
      selectedColor: p.selection,
      labelStyle: text.labelMedium,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: p.sidebar,
      border: field(p.strongBorder),
      enabledBorder: field(p.strongBorder),
      focusedBorder: field(p.accent, 2),
      errorBorder: field(p.red),
      focusedErrorBorder: field(p.red, 2),
      disabledBorder: field(p.border),
      labelStyle: TextStyle(color: p.muted),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.error)
              ? p.red
              : states.contains(WidgetState.focused)
              ? p.accent
              : p.muted,
        ),
      ),
      hintStyle: TextStyle(color: p.muted),
      helperStyle: text.bodySmall?.copyWith(color: p.muted),
    ),
    listTileTheme: ListTileThemeData(
      shape: square,
      selectedColor: p.text,
      selectedTileColor: p.selection,
      iconColor: p.muted,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodyMedium?.copyWith(color: p.muted),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: square,
      collapsedShape: square,
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? p.accent : p.strongBorder,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: square,
      side: BorderSide(color: p.strongBorder, width: 1.5),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.raised,
      circularTrackColor: Colors.transparent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.strongBorder),
      thickness: const WidgetStatePropertyAll(6),
      radius: Radius.zero,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.accent,
      unselectedLabelColor: p.muted,
      indicatorColor: p.accent,
      dividerColor: p.border,
      labelStyle: label,
      unselectedLabelStyle: label,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.sidebar,
      indicatorShape: square,
      indicatorColor: p.selection,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: .35),
      selectionHandleColor: p.accent,
    ),
  );
}

/// A section's heading, as Termul's gallery heads one: `# Hosts`. The hash
/// is the accent's and says nothing to a screen reader or a finder, which
/// read the title alone.
class TuiHeading extends StatelessWidget {
  const TuiHeading(
    this.title, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 8),
  });

  final String title;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = Tui.of(context);
    final style = Theme.of(context).textTheme.titleSmall;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          ExcludeSemantics(
            child: Text('# ', style: style?.copyWith(color: p.accent)),
          ),
          Flexible(
            child: Text(title, style: style?.copyWith(color: p.muted)),
          ),
        ],
      ),
    );
  }
}

/// A small label in a box: Termul's badge. [color] is its ink, muted when
/// left out. [live] puts Termul's lit status dot before it, in the theme's
/// green, for something running; the dot says nothing to a screen reader.
class TuiBadge extends StatelessWidget {
  const TuiBadge(this.label, {super.key, this.color, this.live = false});

  final String label;
  final Color? color;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final p = Tui.of(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: color ?? (live ? p.green : p.muted),
      fontWeight: FontWeight.w700,
      height: 1.3,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: p.raised,
        border: Border.all(color: p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ExcludeSemantics(child: Text('● ', style: style)),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// A key cap and what it does, as Termul's key hint: `[ Add ] add a host`.
class TuiKeyHint extends StatelessWidget {
  const TuiKeyHint({super.key, required this.keys, required this.label});

  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Tui.of(context);
    final small = Theme.of(context).textTheme.labelMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: p.raised,
            border: Border.all(color: p.strongBorder),
          ),
          child: Text(
            keys,
            style: small?.copyWith(
              color: p.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: small?.copyWith(color: p.muted)),
        ),
      ],
    );
  }
}

/// What a page shows with nothing in it yet: a boxed glyph, a line that says
/// so, and what to do about it. One for every list that starts empty, so they
/// all read alike.
class TuiEmptyState extends StatelessWidget {
  const TuiEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.hints = const [],
    this.action,
  });

  final IconData icon;
  final String title;
  final String? body;

  /// Key hints under it, as [TuiKeyHint]s: `(keys, label)`.
  final List<(String, String)> hints;

  /// A button under all of it: the one thing to do next.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = Tui.of(context);
    final theme = Theme.of(context);
    final body = this.body;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.panel,
                  border: Border.all(color: p.border),
                ),
                child: Icon(icon, size: 28, color: p.accent),
              ),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: p.muted,
                    height: 1.5,
                  ),
                ),
              ],
              if (hints.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final (keys, label) in hints)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TuiKeyHint(keys: keys, label: label),
                  ),
              ],
              if (action case final action?) ...[
                const SizedBox(height: 16),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
