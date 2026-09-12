import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'terminal_schemes.dart';
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

/// The terminal's colours as the app is now: the theme picked in Settings, in
/// its variant for the app's brightness.
///
/// Read through the app's theme, so every terminal repaints the moment either
/// changes, with no reconnect: each theme has its own accent, so a new pick
/// changes the app's theme too.
TerminalTheme terminalThemeOf(BuildContext context) =>
    appTheme.value.scheme.terminal(Theme.of(context).brightness);

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

/// Light, dark or the system's, and the theme, as picked in Settings.
/// `SshboxApp` builds its theme from this, so a change repaints every page at
/// once, every terminal included: see [terminalThemeOf].
class AppTheme
    extends ValueNotifier<({ThemeMode mode, TerminalScheme scheme})> {
  AppTheme() : super(defaults);

  /// Dark, in Jeansh's own colours: the way it looked before there was a
  /// choice.
  static final defaults = (mode: ThemeMode.dark, scheme: terminalSchemes.first);

  static const _modeKey = 'sshbox.theme.mode';
  static const _schemeKey = 'sshbox.theme.scheme';

  /// Reads the saved choice. No theme saved, or one no longer offered, gives
  /// Jeansh's; the palette an earlier version saved is not read.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_schemeKey);
    value = (
      mode:
          ThemeMode.values.asNameMap()[prefs.getString(_modeKey)] ??
          defaults.mode,
      scheme: terminalSchemes.firstWhere(
        (scheme) => scheme.id == id,
        orElse: () => defaults.scheme,
      ),
    );
  }

  /// Applies at once, and is saved for the next start.
  Future<void> choose({ThemeMode? mode, TerminalScheme? scheme}) async {
    value = (mode: mode ?? value.mode, scheme: scheme ?? value.scheme);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, value.mode.name);
    await prefs.setString(_schemeKey, value.scheme.id);
  }
}

/// The app's one; `main` reads the saved choice into it.
final appTheme = AppTheme();

/// Jeansh's settings: a list of sections, each a header and its rows.
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

/// Light, dark or the system's, over a card for each theme, with a tick on
/// the one in use.
class _ThemeSection extends StatelessWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            // Two to a row on a phone and four on a tablet, at the host
            // list's breakpoint.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth < 600 ? 2 : 4;
                final width =
                    ((constraints.maxWidth - 8 * (columns - 1)) / columns)
                        .floorToDouble();
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final scheme in terminalSchemes)
                      SizedBox(
                        width: width,
                        child: _SchemeCard(
                          scheme,
                          chosen: scheme == look.scheme,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A theme's name over a few lines of a shell in its colours, as the
/// terminal would draw them in the brightness in use: a prompt, a listing and
/// a commit, in green, cyan, magenta, blue, red and yellow.
class _SchemeCard extends StatelessWidget {
  const _SchemeCard(this.scheme, {required this.chosen});

  final TerminalScheme scheme;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = scheme.terminal(theme.brightness);
    TextSpan token(String text, Color color) =>
        TextSpan(text: text, style: TextStyle(color: color));

    return Semantics(
      selected: chosen,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: chosen
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          onTap: () => appTheme.choose(scheme: scheme),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        scheme.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (chosen)
                      Icon(
                        Icons.check_circle,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(
                          color: colors.foreground,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.3,
                        ),
                        children: [
                          token('➜ ', colors.green),
                          token('~/src ', colors.cyan),
                          token('main\n', colors.magenta),
                          token('lib ', colors.blue),
                          token('.env ', colors.red),
                          const TextSpan(text: 'a.md\n'),
                          token('a1b2c3d ', colors.yellow),
                          const TextSpan(text: 'fix'),
                        ],
                      ),
                      maxLines: 3,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                      theme: terminalThemeOf(context),
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
                'These fonts ship inside Jeansh, so they work offline. A glyph '
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
