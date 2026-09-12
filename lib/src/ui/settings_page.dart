import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'tmux_panes.dart';

/// Where a Nerd Font glyph comes from, whichever font is picked.
///
/// A prompt like spaceship draws powerline arrows and a git branch from the
/// Private Use Area, which no ordinary font has: Cascadia, JetBrains Mono and
/// Android's own monospace all show boxes there. The patched Cascadia has
/// them, drawn a cell wide, so every family falls back to it first.
const nerdFontFamily = 'CaskaydiaCove Nerd Font Mono';

/// The fonts Settings offers: every one bundled under `assets/fonts/`, by the
/// family name `pubspec.yaml` declares, and Android's own monospace, which is
/// what the terminal drew with before there was a choice.
///
/// Cascadia Code is Cascadia Mono with ligatures, but xterm2 draws a cell at a
/// time with ligatures turned off, so in the terminal the two look alike, and
/// the row says nothing it would not show.
const terminalFonts = <({String family, String label, String? note})>[
  (
    family: 'Cascadia Mono',
    label: 'Cascadia Mono',
    note: 'PowerShell and Windows Terminal',
  ),
  (family: 'Cascadia Code', label: 'Cascadia Code', note: null),
  (family: nerdFontFamily, label: nerdFontFamily, note: 'prompt glyphs'),
  (family: 'JetBrains Mono', label: 'JetBrains Mono', note: null),
  (family: 'Fira Code', label: 'Fira Code', note: null),
  (family: 'monospace', label: 'System monospace', note: 'the default'),
];

const minFontSize = 9.0;
const maxFontSize = 24.0;

/// What a terminal draws with in [family] at [size]. xterm2's own fallbacks
/// stay behind the Nerd Font, so emoji and CJK go where they always went.
TerminalStyle terminalStyleOf(String family, double size) => TerminalStyle(
  fontFamily: family,
  fontSize: size,
  fontFamilyFallback: [
    nerdFontFamily,
    ...const TerminalStyle().fontFamilyFallback,
  ],
);

/// The terminal's font and size, as picked in Settings, in one value every
/// terminal page listens to: a change reaches each open shell and tmux pane at
/// once, and a page need not know where it came from.
class TerminalSettings extends ValueNotifier<TerminalStyle> {
  TerminalSettings() : super(defaultStyle);

  static final defaultStyle = terminalStyleOf('monospace', 13);

  static const _familyKey = 'sshbox.terminal.fontFamily';
  static const _sizeKey = 'sshbox.terminal.fontSize';

  /// Reads the saved choice. A family no longer bundled, or a size out of
  /// range, gives way to the default rather than to a font that is not there.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final family = prefs.getString(_familyKey);
    final size = prefs.getDouble(_sizeKey);
    value = terminalStyleOf(
      terminalFonts.any((font) => font.family == family)
          ? family!
          : defaultStyle.fontFamily,
      (size ?? defaultStyle.fontSize).clamp(minFontSize, maxFontSize),
    );
  }

  /// Applies at once, and is saved for the next start.
  Future<void> choose({String? family, double? size}) async {
    value = terminalStyleOf(family ?? value.fontFamily, size ?? value.fontSize);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_familyKey, value.fontFamily);
    await prefs.setDouble(_sizeKey, value.fontSize);
  }
}

/// The app's one; `main` reads the saved choice into it.
final terminalSettings = TerminalSettings();

/// The palettes Settings offers, each the seed a whole colour scheme grows
/// from. Only a seed's hue counts, so they sit apart round the colour wheel.
/// The first is Clode's green, the only one it had before there was a choice.
const appPalettes = <({String name, Color seed})>[
  (name: 'Green', seed: Color(0xFF4CC38A)),
  (name: 'Teal', seed: Color(0xFF26A69A)),
  (name: 'Blue', seed: Color(0xFF4A8FE7)),
  (name: 'Purple', seed: Color(0xFFA56CE0)),
  (name: 'Pink', seed: Color(0xFFE85D9A)),
  (name: 'Red', seed: Color(0xFFE5534B)),
  (name: 'Orange', seed: Color(0xFFF0883E)),
  (name: 'Yellow', seed: Color(0xFFD9B43A)),
];

/// Light, dark or the system's, and the palette, as picked in Settings.
/// `SshboxApp` builds its theme from this, so a change repaints every page at
/// once. The terminal keeps its own colours whatever is picked.
class AppTheme extends ValueNotifier<({ThemeMode mode, Color seed})> {
  AppTheme() : super(defaults);

  /// Dark and green, the way Clode looked before there was a choice: a
  /// terminal is a dark surface, and dark chrome does not fight it.
  static final defaults = (mode: ThemeMode.dark, seed: appPalettes.first.seed);

  static const _modeKey = 'sshbox.theme.mode';
  static const _seedKey = 'sshbox.theme.seed';

  /// Reads the saved choice. A palette no longer offered gives way to the
  /// default, the way a font no longer bundled does.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSeed = prefs.getInt(_seedKey);
    value = (
      mode:
          ThemeMode.values.asNameMap()[prefs.getString(_modeKey)] ??
          defaults.mode,
      seed: appPalettes
          .map((palette) => palette.seed)
          .firstWhere(
            (seed) => seed.toARGB32() == savedSeed,
            orElse: () => defaults.seed,
          ),
    );
  }

  /// Applies at once, and is saved for the next start.
  Future<void> choose({ThemeMode? mode, Color? seed}) async {
    value = (mode: mode ?? value.mode, seed: seed ?? value.seed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, value.mode.name);
    await prefs.setInt(_seedKey, value.seed.toARGB32());
  }
}

/// The app's one; `main` reads the saved choice into it.
final appTheme = AppTheme();

/// Clode's settings: a list of sections, each a header and its rows.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: const [_ThemeSection(), _TerminalSection()],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Light, dark or the system's, over a row of palettes, each drawn in the
/// colour it would give the app as it is now, with a tick on the one in use.
class _ThemeSection extends StatelessWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return ValueListenableBuilder(
      valueListenable: appTheme,
      builder: (context, look, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader('Theme'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {look.mode},
              onSelectionChanged: (modes) =>
                  appTheme.choose(mode: modes.single),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final palette in appPalettes)
                  _swatch(
                    palette,
                    brightness,
                    chosen: palette.seed == look.seed,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _swatch(
    ({String name, Color seed}) palette,
    Brightness brightness, {
    required bool chosen,
  }) {
    final colors = ColorScheme.fromSeed(
      seedColor: palette.seed,
      brightness: brightness,
    );
    return IconButton.filled(
      tooltip: palette.name,
      isSelected: chosen,
      onPressed: () => appTheme.choose(seed: palette.seed),
      style: IconButton.styleFrom(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
      ),
      icon: Icon(chosen ? Icons.check : null),
    );
  }
}

/// The terminal's font and size, over a preview drawn by the terminal's own
/// view: the cells, colours and fallback glyphs a shell would get.
class _TerminalSection extends StatefulWidget {
  const _TerminalSection();

  @override
  State<_TerminalSection> createState() => _TerminalSectionState();
}

class _TerminalSectionState extends State<_TerminalSection> {
  /// A short prompt, in spaceship's colours with its branch glyph, a command
  /// and what it printed — short enough for a phone at the largest size.
  static const _previewText =
      '\x1b[1;36m~/dev\x1b[0m on \x1b[1;35m\u{E0A0} main\x1b[0m\r\n'
      '\x1b[1;32m➜\x1b[0m ls -la\r\n'
      'drwxr-xr-x  lib\r\n'
      '-rw-r--r--  README.md\r\n'
      '\x1b[1;32m➜\x1b[0m ';
  static const _previewRows = 5;
  static const _previewPadding = EdgeInsets.all(8);

  /// Each font's row, drawn in that font: the digits and letters told apart
  /// by shape, an arrow, and two prompt glyphs from the Nerd Font.
  static const _sample = 'user@host ~ \$ ls -la  0O il1 →  \u{E0A0} \u{E0B0}';

  final _preview = Terminal()..write(_previewText);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, style, _) {
        final cell = terminalCellSize(style, MediaQuery.textScalerOf(context));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader('Terminal'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: _previewRows * cell.height + _previewPadding.vertical,
                  // Only to look at: a tap would take focus for a terminal
                  // that has nothing behind it.
                  child: IgnorePointer(
                    child: TerminalView(
                      _preview,
                      textStyle: style,
                      padding: _previewPadding,
                      readOnly: true,
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              title: const Text('Font size'),
              trailing: Text(
                '${style.fontSize.round()}',
                style: theme.textTheme.titleMedium,
              ),
              subtitle: Slider(
                value: style.fontSize,
                min: minFontSize,
                max: maxFontSize,
                divisions: (maxFontSize - minFontSize).round(),
                label: '${style.fontSize.round()}',
                onChanged: (size) => terminalSettings.choose(size: size),
              ),
            ),
            for (final font in terminalFonts)
              ListTile(
                selected: font.family == style.fontFamily,
                title: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: font.label,
                        style: TextStyle(fontFamily: font.family),
                      ),
                      if (font.note != null)
                        TextSpan(
                          text: '  ${font.note}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                // In the terminal's own style, so what the row shows is what
                // a shell gets: no ligatures, and the Nerd Font behind it.
                subtitle: Text(
                  _sample,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: terminalStyleOf(font.family, 14).toTextStyle(),
                ),
                trailing: font.family == style.fontFamily
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => terminalSettings.choose(family: font.family),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'These fonts ship inside Clode, so they work offline. A glyph '
                'a font lacks, such as a prompt\'s powerline arrows, comes '
                'from $nerdFontFamily.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
