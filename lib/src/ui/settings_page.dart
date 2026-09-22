import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import '../notifications/notify_key.dart';
import '../platform.dart';
import '../system_fonts.dart';
import '../telemetry/crash_reporting.dart';
import '../telemetry/telemetry.dart';
import 'bug_report.dart';
import 'key_bar.dart';
import 'update_dialog.dart';
import 'terminal_schemes.dart';
import 'tmux_panes.dart';
import 'toast.dart';

/// Where a Nerd Font glyph comes from, whichever font is picked.
///
/// A prompt like spaceship draws powerline arrows and a git branch from the
/// Private Use Area, which no ordinary font has: Cascadia, JetBrains Mono and
/// Android's own monospace all show boxes there. The patched Cascadia has
/// them, drawn a cell wide, so every family falls back to it first.
const nerdFontFamily = 'CaskaydiaCove Nerd Font Mono';

/// Where a symbol none of the code fonts has comes from.
///
/// Claude Code's status line writes `⏵⏵ auto mode on` with U+23F5, which no
/// bundled font carries — and neither does the tablet, since Android ships
/// Noto Sans Symbols subsetted and this codepoint was dropped, so both
/// triangles came out as boxes. A subset of Noto Sans Symbols 2 stands behind
/// the Nerd Font for it, and for the dingbats and braille a TUI draws.
const symbolFontFamily = 'Noto Sans Symbols 2';

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

/// What a terminal draws with in [family] at [size]. The Nerd Font comes
/// first and the symbols font behind it, with xterm2's own fallbacks last, so
/// emoji and CJK go where they always went.
TerminalStyle terminalStyleOf(String family, double size) => TerminalStyle(
  fontFamily: family,
  fontSize: size,
  fontFamilyFallback: [
    nerdFontFamily,
    symbolFontFamily,
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

  /// The font the saved choice named that this computer no longer has,
  /// until [sayIfMissing] has said so.
  String? missing;

  /// Reads the saved choice. A family no longer bundled — or on a desktop no
  /// longer installed — or a size out of range, gives way to the default
  /// rather than to a font that is not there.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final family = prefs.getString(_familyKey);
    final size = prefs.getDouble(_sizeKey);
    value = terminalStyleOf(
      await _usable(family) ? family! : defaultStyle.fontFamily,
      (size ?? defaultStyle.fontSize).clamp(minFontSize, maxFontSize),
    );
  }

  /// Whether [family] can be drawn: one bundled, or on a desktop one it has
  /// installed. Only a system font costs a look at the computer's fonts, and
  /// one whose list cannot be read is trusted, as it was when it was picked.
  Future<bool> _usable(String? family) async {
    if (family == null) return false;
    if (terminalFonts.any((font) => font.family == family)) return true;
    if (!isDesktop) return false;
    final installed = await systemFonts();
    if (installed == null || installed.any((font) => font.family == family)) {
      return true;
    }
    missing = family;
    return false;
  }

  /// Says, once, that the saved font has gone and what the terminal draws in
  /// instead, rather than leaving a fallback to draw it without a word. The
  /// choice stays saved, so the font coming back brings it back.
  void sayIfMissing(BuildContext context) {
    final family = missing;
    if (family == null) return;
    missing = null;
    final instead = terminalFonts
        .firstWhere((font) => font.family == defaultStyle.fontFamily)
        .label;
    showToast(
      context,
      '$family is not installed\nThe terminal draws in $instead until it is '
      'back, or until Settings picks another font.',
      type: ToastificationType.warning,
      duration: const Duration(seconds: 8),
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

/// One of the terminal key bar's items, in the place Settings put it: a key
/// from [terminalKeys] by its id, or one the user made, under an id of its
/// own that starts with [customKeyPrefix].
typedef KeyBarItem = ({String id, CustomKey? custom});

/// How the id of every key the user makes starts, and no built-in one's.
const customKeyPrefix = 'custom:';

/// The terminal's key bar as arranged in Settings: the items it shows, in
/// order. A built-in key taken off it waits in Add key to go back on; a
/// custom one is deleted. Every terminal page's bar listens, so a change
/// reaches each open shell at once.
class KeyBarSettings extends ValueNotifier<List<KeyBarItem>> {
  KeyBarSettings() : super(defaults);

  /// The bar as it has always been.
  static final defaults = List<KeyBarItem>.unmodifiable([
    for (final id in terminalKeyBarDefault) (id: id, custom: null),
  ]);

  /// Still v1's JSON list: `{"id": "esc", "shown": true}` for each item on the
  /// bar, in order, a custom key's with its `label`, its `send` and its
  /// `combo` as [keyComboName] writes it, `Ctrl+Alt+R`, and `"layout": "mac"`
  /// for one picked on the macOS layout; `send` is all an earlier version
  /// reads, and all a key made before the picker has. Then
  /// `{"id": "tab", "shown": false}` for each built-in key off it. Those
  /// tell a key taken off from one a later version adds, which joins the bar.
  /// v1 hid a key in the same words, so a key hidden then is off the bar now.
  static const _key = 'sshbox.keyBar.v1';

  /// `mac` or `pc`: the layout the custom key picker was last switched to.
  static const _layoutKey = 'sshbox.keyBar.layout';

  /// Whether the custom key picker opens a new key on the macOS layout.
  bool macLayout = false;

  /// Saved for the next key, and the next start.
  Future<void> chooseLayout({required bool mac}) async {
    macLayout = mac;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layoutKey, mac ? 'mac' : 'pc');
  }

  /// The ids the bar shows, in order.
  List<String> get keys => [for (final item in value) item.id];

  /// The keys the user made, by their ids.
  Map<String, CustomKey> get customKeys => {
    for (final item in value) item.id: ?item.custom,
  };

  /// Reads the saved arrangement. Nothing saved, or a list this build cannot
  /// read, is the bar as it has always been. An id this build does not know
  /// is dropped, and a key the list never mentions, one a later version
  /// added, joins at the end.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    macLayout = prefs.getString(_layoutKey) == 'mac';
    Object? saved;
    try {
      saved = jsonDecode(prefs.getString(_key) ?? 'null');
    } on FormatException {
      saved = null;
    }
    if (saved is! List) {
      value = defaults;
      return;
    }

    final items = <KeyBarItem>[];
    // Every key the list mentions, on the bar or off it.
    final mentioned = <String>{};
    for (final entry in saved) {
      if (entry is! Map) continue;
      final id = entry['id'];
      // Only the divider may come twice; a key saved twice keeps its first
      // entry.
      if (id is! String || (id != keyBarDivider && !mentioned.add(id))) {
        continue;
      }
      if (entry['shown'] == false) continue;
      if (terminalKeys.containsKey(id)) {
        items.add((id: id, custom: null));
      } else if (entry
          case {'label': final String label, 'send': final String send}
          when id.startsWith(customKeyPrefix)) {
        items.add((
          id: id,
          custom: (
            label: label,
            send: send,
            // A key a later version has and this one does not types its text.
            combo: switch (entry['combo']) {
              final String saved => parseKeyCombo(
                saved,
                mac: entry['layout'] == 'mac',
              ),
              _ => null,
            },
          ),
        ));
      }
    }
    for (final id in terminalKeyBarDefault) {
      if (id != keyBarDivider && !mentioned.contains(id)) {
        items.add((id: id, custom: null));
      }
    }
    value = items;
  }

  /// Applies at once, and is saved for the next start.
  Future<void> choose(List<KeyBarItem> items) async {
    value = items;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([
        for (final item in items)
          {
            'id': item.id,
            'shown': true,
            if (item.custom case final key?) ...{
              'label': key.label,
              'send': key.send,
              if (key.combo case final combo?) ...{
                'combo': keyComboName(combo),
                if (combo.mac) 'layout': 'mac',
              },
            },
          },
        for (final id in terminalKeys.keys)
          if (id != keyBarDivider && !items.any((item) => item.id == id))
            {'id': id, 'shown': false},
      ]),
    );
  }

  /// The bar as it ships. Nothing is left saved, so a later version's own
  /// arrangement is the one it gets.
  Future<void> reset() async {
    value = defaults;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// The app's one; `main` reads the saved arrangement into it.
final keyBarSettings = KeyBarSettings();

/// Where the key bar's git button opens the repositories: in a tab beside the
/// shell, as it always has, or in the terminal's own drawer over it.
///
/// Read at the tap rather than watched, so a change here reaches the next tap
/// and leaves whatever is already open alone.
class GitPanelSetting extends ValueNotifier<bool> {
  GitPanelSetting() : super(false);

  static const _key = 'sshbox.git.drawer';

  /// Reads the saved choice. Nothing saved is a tab, which is what the git
  /// button did before there was a choice.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getBool(_key) ?? false;
  }

  /// Applies to the next tap, and is saved for the next start.
  Future<void> choose(bool drawer) async {
    value = drawer;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, drawer);
  }
}

/// The app's one; `main` reads the saved choice into it. True is the drawer.
final gitInDrawer = GitPanelSetting();

/// Whether the files tree lists dotfiles. One choice for the whole app, as
/// VS Code's is, and kept: the drawer builds its tree anew each time it opens,
/// so a choice held by the tree itself went back to hidden every time it shut.
class DotfilesSetting extends ValueNotifier<bool> {
  DotfilesSetting() : super(false);

  static const _key = 'sshbox.files.dotfiles';

  /// Reads the saved choice. Nothing saved is hidden, as the tree always was.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getBool(_key) ?? false;
  }

  /// Shows or hides them at once, and is saved for the next start.
  Future<void> choose(bool show) async {
    value = show;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, show);
  }
}

/// The app's one; `main` reads the saved choice into it. True shows them.
final showDotfiles = DotfilesSetting();

/// Whether a desktop terminal copies what the mouse selects the moment the
/// button comes up, as iTerm2 and Claude Code's own fullscreen view do.
/// Desktop alone: a phone's selection has its handles and its Copy.
class CopyOnSelectSetting extends ValueNotifier<bool> {
  CopyOnSelectSetting() : super(true);

  static const _key = 'sshbox.terminal.copyOnSelect';

  /// Reads the saved choice. Nothing saved is on.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getBool(_key) ?? true;
  }

  /// Applies to the next selection, and is saved for the next start.
  Future<void> choose(bool on) async {
    value = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, on);
  }
}

/// The app's one; `main` reads the saved choice into it.
final copyOnSelect = CopyOnSelectSetting();

/// The Settings route open on each navigator, for [openSettings] to find.
final _openSettings = Expando<Route<void>>();

/// Settings, pushed on [navigator] — unless it is open there already, when
/// asking again does nothing rather than stack a second copy. Home's ⚙, the
/// first run's toast and a Mac's ⌘, all come here, so each finds the others'.
void openSettings(NavigatorState navigator, {NotifyKeys? notifyKeys}) {
  if (_openSettings[navigator]?.isActive ?? false) return;
  final route = MaterialPageRoute<void>(
    builder: (_) => SettingsPage(notifyKeys: notifyKeys),
  );
  _openSettings[navigator] = route;
  navigator.push(route);
}

/// Jeansh's settings: a list of sections, each a header and its rows.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.notifyKeys});

  /// The relay keys, one per host, for Notifications to reset. Left out,
  /// there are none.
  final NotifyKeys? notifyKeys;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _ThemeSection(),
          const _TerminalSection(),
          const _SectionHeader('Keyboard'),
          ListTile(
            leading: const Icon(Icons.keyboard_outlined),
            title: const Text('Key bar'),
            subtitle: const Text(
              'The keys above the keyboard in a terminal: which ones, and in '
              'what order',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const KeyBarSettingsPage(),
              ),
            ),
          ),
          const _GitSection(),
          _NotificationsSection(notifyKeys),
          const _PrivacySection(),
          // Desktop alone: Android updates through Play, and there is no
          // desktop build to offer anywhere else.
          if (isDesktop) ...[
            const _SectionHeader('Updates'),
            const UpdateTile(),
          ],
        ],
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

  /// This computer's own fonts, on a desktop: read once, when the section is
  /// first shown.
  late final _installed = isDesktop ? systemFonts() : null;

  /// A desktop's way to a font installed on the computer: the one in use, if
  /// it is not bundled, with a word when it is proportional, and a tap for the
  /// computer's list.
  Widget _installedFont(
    BuildContext context,
    TerminalStyle style,
    AsyncSnapshot<List<SystemFont>?> fonts,
  ) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final family = style.fontFamily;
    final chosen = !terminalFonts.any((font) => font.family == family);
    final listed = fonts.data;
    final done = fonts.connectionState == ConnectionState.done;
    final proportional =
        chosen &&
        (listed?.any((font) => font.family == family && !font.mono) ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          selected: chosen,
          title: Text.rich(
            TextSpan(
              children: [
                if (chosen) ...[
                  TextSpan(
                    text: family,
                    style: TextStyle(fontFamily: family),
                  ),
                  TextSpan(text: '  on this computer', style: muted),
                ] else
                  const TextSpan(text: 'Installed on this computer…'),
              ],
            ),
          ),
          subtitle: chosen
              ? Text(
                  _sample,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: terminalStyleOf(family, 14).toTextStyle(),
                )
              : Text(switch (listed) {
                  _ when !done => 'Reading this computer\'s fonts…',
                  null => 'Its fonts could not be listed: type a name',
                  final listed => '${listed.length} families, monospaced first',
                }),
          trailing: Icon(chosen ? Icons.check : Icons.chevron_right),
          onTap: done
              ? () async {
                  final picked = await showDialog<String>(
                    context: context,
                    builder: (_) => _InstalledFontPicker(
                      listed,
                      chosen: family,
                      sample: _sample,
                    ),
                  );
                  if (picked != null) {
                    await terminalSettings.choose(family: picked);
                  }
                }
              : null,
        ),
        if (proportional)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$family is proportional, so the terminal\'s columns '
                    'will not line up.',
                    style: muted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

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
                'a font lacks comes from $nerdFontFamily — a prompt\'s '
                'powerline arrows — or from $symbolFontFamily, for symbols '
                'like ⏵⏵ that no code font draws.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // Below what is said of the bundled fonts, which is not true of it.
            if (_installed case final installed?)
              FutureBuilder(
                future: installed,
                builder: (context, fonts) =>
                    _installedFont(context, style, fonts),
              ),
            if (isDesktop)
              ValueListenableBuilder(
                valueListenable: copyOnSelect,
                builder: (context, on, _) => SwitchListTile(
                  title: const Text('Copy on select'),
                  subtitle: const Text(
                    'Text selected with the mouse goes to the clipboard as '
                    'the button comes up',
                  ),
                  value: on,
                  onChanged: copyOnSelect.choose,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The computer's fonts to pick one from, monospaced first and marked, with a
/// filter over them. Where they could not be listed, the field takes the name
/// of one instead, as it is.
class _InstalledFontPicker extends StatefulWidget {
  const _InstalledFontPicker(
    this.fonts, {
    required this.chosen,
    required this.sample,
  });

  final List<SystemFont>? fonts;
  final String chosen;
  final String sample;

  @override
  State<_InstalledFontPicker> createState() => _InstalledFontPickerState();
}

class _InstalledFontPickerState extends State<_InstalledFontPicker> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fonts = widget.fonts;
    final typed = _field.text.trim();
    final shown = [
      for (final font in fonts ?? const <SystemFont>[])
        if (font.family.toLowerCase().contains(typed.toLowerCase())) font,
    ];
    void pick(String family) => Navigator.of(context).pop(family);

    return AlertDialog(
      title: const Text('Installed fonts'),
      content: SizedBox(
        width: 480,
        height: fonts == null ? null : 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _field,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: fonts == null ? null : const Icon(Icons.search),
                hintText: fonts == null ? 'Family name' : 'Filter',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: fonts == null && typed.isNotEmpty
                  ? (_) => pick(typed)
                  : null,
            ),
            const SizedBox(height: 8),
            if (fonts == null)
              Text(
                'This computer\'s fonts could not be listed. Type the family '
                'name of one installed here.',
                style: theme.textTheme.bodySmall,
              )
            else if (shown.isEmpty)
              const Expanded(
                child: Center(child: Text('No installed font matches.')),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final font = shown[index];
                    return ListTile(
                      selected: font.family == widget.chosen,
                      title: Text(font.family),
                      // In the font itself, as the terminal would draw it: a
                      // symbols font's name alone could not be read in it.
                      subtitle: Text(
                        widget.sample,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: terminalStyleOf(font.family, 14).toTextStyle(),
                      ),
                      trailing: font.mono
                          ? Text('monospaced', style: theme.textTheme.bodySmall)
                          : null,
                      onTap: () => pick(font.family),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (fonts == null)
          FilledButton(
            onPressed: typed.isEmpty ? null : () => pick(typed),
            child: const Text('Use'),
          ),
      ],
    );
  }
}

/// The terminal's key bar item by item, each with a handle to drag it to a
/// new place and a button to take it off, under the bar as a terminal will
/// draw it. Add key puts a key back on, adds a divider, or makes a key of the
/// user's own, which a tap on its row changes.
class KeyBarSettingsPage extends StatefulWidget {
  const KeyBarSettingsPage({super.key});

  @override
  State<KeyBarSettingsPage> createState() => _KeyBarSettingsPageState();
}

class _KeyBarSettingsPageState extends State<KeyBarSettingsPage> {
  /// The preview's own, with no shell behind it: its keys light up and
  /// scroll, and send nothing anywhere.
  final _previewKeys = KeyBarController();
  final _previewTerminal = Terminal();

  @override
  void dispose() {
    _previewKeys.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset the key bar?'),
        content: const Text(
          'The keys it came with go back in their first places, and custom '
          'keys are deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) await keyBarSettings.reset();
  }

  static String _label(KeyBarItem item) =>
      item.custom?.label ?? terminalKeys[item.id]!.label;

  /// Takes the item at [index] off the bar. A built-in key waits in Add key
  /// to go back on, but a custom one is deleted with it, so that gets an Undo.
  void _remove(int index) {
    final items = keyBarSettings.value;
    final item = items[index];
    keyBarSettings.choose([...items]..removeAt(index));

    final key = item.custom;
    if (key == null) return;
    showToast(
      context,
      'Deleted ${key.label}',
      duration: const Duration(seconds: 5),
      action: (
        label: 'Undo',
        onPressed: () {
          final now = keyBarSettings.value;
          keyBarSettings.choose(
            [...now]..insert(index.clamp(0, now.length), item),
          );
        },
      ),
    );
  }

  /// A key of the user's own, from the form: a new one, or [key] changed.
  /// Null if the form was cancelled.
  Future<CustomKey?> _customKey([CustomKey? key]) => showDialog<CustomKey>(
    context: context,
    builder: (_) => _CustomKeyDialog(key),
  );

  /// Offers what the bar has not got: each built-in key taken off it, drawn
  /// as the bar draws it, a divider, which may go on any number of times, and
  /// a key of the user's own. What is picked goes on the end.
  Future<void> _add() async {
    final items = keyBarSettings.value;
    final off = [
      for (final id in terminalKeys.keys)
        if (id != keyBarDivider && !items.any((item) => item.id == id)) id,
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        void pick(String id) => Navigator.of(context).pop(id);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (off.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  child: Wrap(
                    children: [
                      for (final id in off)
                        KeyButton(
                          label: terminalKeys[id]!.label,
                          onTap: () => pick(id),
                        ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.more_vert),
                title: const Text('Divider'),
                onTap: () => pick(keyBarDivider),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Custom key…'),
                subtitle: const Text(
                  'Any key, with Ctrl, Alt, Shift or Super, on a PC or '
                  'macOS layout',
                ),
                onTap: () => pick(customKeyPrefix),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;

    final KeyBarItem item;
    if (picked == customKeyPrefix) {
      final key = await _customKey();
      if (key == null) return;
      final made = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      item = (id: '$customKeyPrefix$made', custom: key);
    } else {
      item = (id: picked, custom: null);
    }
    await keyBarSettings.choose([...keyBarSettings.value, item]);
    // The end of the list is usually out of sight.
    if (mounted) showToast(context, '${_label(item)} added at the end');
  }

  Future<void> _edit(KeyBarItem item) async {
    final key = await _customKey(item.custom);
    if (key == null) return;
    await keyBarSettings.choose([
      for (final other in keyBarSettings.value)
        other.id == item.id ? (id: other.id, custom: key) : other,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Key bar'),
        actions: [
          IconButton(
            tooltip: 'Reset to default',
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add key'),
      ),
      body: ValueListenableBuilder(
        valueListenable: keyBarSettings,
        builder: (context, items, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // At the top of the page rather than the foot of the screen, so
            // the system's inset down there is not the bar's to pad.
            MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: TerminalKeyBar(
                controller: _previewKeys,
                terminal: _previewTerminal,
                onEmit: (_) {},
                keys: keyBarSettings.keys,
                customKeys: keyBarSettings.customKeys,
                // Files and upload, as a terminal has them: the page's own,
                // so always first and not the bar's to move.
                leading: const [
                  IconButton(
                    onPressed: null,
                    icon: Icon(Icons.folder_outlined),
                  ),
                  IconButton(onPressed: null, icon: Icon(Icons.attach_file)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Files and upload always come first. Drag a key by its handle '
                'to move it, and tap a key of your own to change it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                // Clear of Add key, so the last row's button is not under it.
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: items.length,
                onReorderItem: (from, to) => keyBarSettings.choose(
                  [...items]
                    ..removeAt(from)
                    ..insert(to, items[from]),
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final custom = item.custom;
                  return ListTile(
                    // Dividers repeat, so each is known by how many came
                    // before it.
                    key: ValueKey((
                      item.id,
                      items.take(index).where((i) => i.id == item.id).length,
                    )),
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text(
                      _label(item),
                      style: item.id == keyBarDivider
                          ? null
                          : const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                    // What a key of the user's own stands for, `Ctrl+Alt+R`
                    // or `⌥⌫`, or for one made before the picker, its text as
                    // written.
                    subtitle: custom == null
                        ? null
                        : Text(
                            switch (custom.combo) {
                              final combo? => keyComboText(combo),
                              null => custom.send,
                            },
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                    onTap: custom == null ? null : () => _edit(item),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      onPressed: () => _remove(index),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picker for a key of the user's own: a PC or macOS layout, Ctrl, Alt,
/// Shift and Super to hold, or on a Mac ⌃ ⌥ ⇧ ⌘, a keyboard to tap the key
/// on, the combination as it is built, and the label the key shows, filled in
/// from the combination until the user writes one. Clear starts it over.
/// Pops with the key, or with nothing on Cancel.
class _CustomKeyDialog extends StatefulWidget {
  const _CustomKeyDialog(this.initial);

  /// The key being changed, or null for a new one. One made before the
  /// picker, with only the text it types, opens with no key picked and its
  /// label kept.
  final CustomKey? initial;

  @override
  State<_CustomKeyDialog> createState() => _CustomKeyDialogState();
}

class _CustomKeyDialogState extends State<_CustomKeyDialog> {
  late final _label = TextEditingController(text: widget.initial?.label);
  late String? _key = widget.initial?.combo?.key;
  late bool _ctrl = widget.initial?.combo?.ctrl ?? false;
  late bool _alt = widget.initial?.combo?.alt ?? false;
  late bool _shift = widget.initial?.combo?.shift ?? false;
  late bool _super = widget.initial?.combo?.superKey ?? false;

  /// A key's own layout, or for a new one the layout last picked.
  late bool _mac = widget.initial?.combo?.mac ?? keyBarSettings.macLayout;

  /// The label the combination last filled in, so one the user wrote is left
  /// alone.
  late String? _filled = switch (widget.initial?.combo) {
    final combo? => keyComboLabel(combo),
    null => null,
  };

  /// The combination so far, `…` standing in for a key not picked yet.
  KeyCombo get _shown => (
    key: _key ?? '…',
    ctrl: _ctrl,
    alt: _alt,
    shift: _shift,
    superKey: _super,
    mac: _mac,
  );

  KeyCombo? get _combo => _key == null ? null : _shown;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  /// Makes [change] to the combination, and fills the label in from it.
  void _change(VoidCallback change) => setState(() {
    change();
    if (_combo case final combo?) {
      final label = keyComboLabel(combo);
      if (_label.text.trim().isEmpty || _label.text == _filled) {
        _label.text = label;
      }
      _filled = label;
    }
  });

  /// No key, no modifier, and a label the next key fills in. The layout stays.
  void _clear() => setState(() {
    _key = null;
    _ctrl = _alt = _shift = _super = false;
    _label.clear();
    _filled = null;
  });

  void _save() {
    final combo = _combo!;
    final label = _label.text.trim();
    Navigator.of(context).pop((
      label: label.isEmpty ? keyComboLabel(combo) : label,
      // What an earlier version, which knows no combinations, types for it:
      // xterm's sequence as a fresh terminal has it, with each backslash
      // escaped for decodeKeyText.
      send: encodeKeyCombo(Terminal(), combo).replaceAll(r'\', r'\\'),
      combo: combo,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.initial == null;
    final blank = _key == null && !_ctrl && !_alt && !_shift && !_super;
    // In the same places on both: Ctrl is Control, Alt is Option and Super
    // is Command, and that is the Mac's own order.
    final names = _mac
        ? const ['⌃ Control', '⌥ Option', '⇧ Shift', '⌘ Command']
        : const ['Ctrl', 'Alt', 'Shift', 'Super'];
    Widget modifier(int index, bool held, void Function(bool) hold) =>
        FilterChip(
          label: Text(names[index]),
          selected: held,
          onSelected: (held) => _change(() => hold(held)),
        );
    // A Mac's line-editing combinations are plain control characters, which
    // any shell reads.
    final extended =
        _super && !(_mac && macTextEditing.containsKey(keyComboName(_shown)));

    return Dialog(
      // Close to the edges on a phone, where a keyboard needs the width; a
      // card of its own on a tablet.
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isNew ? 'New custom key' : 'Change custom key',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Center(
                child: SegmentedButton(
                  segments: const [
                    ButtonSegment(value: false, label: Text('PC')),
                    ButtonSegment(value: true, label: Text('macOS')),
                  ],
                  selected: {_mac},
                  onSelectionChanged: (picked) {
                    _change(() => _mac = picked.single);
                    keyBarSettings.chooseLayout(mac: _mac);
                  },
                ),
              ),
              const SizedBox(height: 12),
              // The combination as it is built, in sight while the keys
              // below scroll.
              Text(
                blank
                    ? 'Pick a key, with ${names.take(3).join(', ')} or '
                          '${names.last} if you like'
                    : keyComboText(_shown),
                textAlign: TextAlign.center,
                style: blank
                    ? theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : theme.textTheme.titleLarge?.copyWith(
                        fontFamily: 'monospace',
                      ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  modifier(0, _ctrl, (held) => _ctrl = held),
                  modifier(1, _alt, (held) => _alt = held),
                  modifier(2, _shift, (held) => _shift = held),
                  modifier(3, _super, (held) => _super = held),
                ],
              ),
              if (extended)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Only apps that read extended keys act on '
                    '${_mac ? '⌘' : 'Super'}: tmux with extended-keys on, '
                    'neovim, and apps that speak the kitty keyboard protocol.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final row in keyComboRows)
                        SizedBox(
                          height: 44,
                          child: Row(
                            children: [
                              for (final key in row)
                                Expanded(
                                  child: KeyButton(
                                    // With Shift held, what Shift types.
                                    label: keyCapOf(
                                      key,
                                      shift: _shift,
                                      mac: _mac,
                                    ),
                                    active: key == _key,
                                    minWidth: 0,
                                    onTap: () => _change(() => _key = key),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              TextField(
                controller: _label,
                maxLength: customKeyLabelMax,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  helperText: 'What the key shows',
                ),
              ),
              Row(
                children: [
                  TextButton(onPressed: _clear, child: const Text('Clear')),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _key == null ? null : _save,
                    child: Text(isNew ? 'Add' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the git button puts the repositories: a tab of their own, or a
/// drawer over the terminal. The panel itself is the same either way.
class _GitSection extends StatelessWidget {
  const _GitSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Git'),
        ValueListenableBuilder(
          valueListenable: gitInDrawer,
          builder: (context, drawer, _) => ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('Open the git panel as'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Tab'),
                      icon: Icon(Icons.tab_outlined),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Drawer'),
                      icon: Icon(Icons.vertical_split_outlined),
                    ),
                  ],
                  selected: {drawer},
                  showSelectedIcon: false,
                  onSelectionChanged: (picked) =>
                      gitInDrawer.choose(picked.first),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'A tab sits beside the shell and stays until you close it; a '
            'drawer slides over the terminal and goes when you tap away. A '
            'git tab already open stays a tab.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// What leaves this device, and the one switch that stops it.
///
/// Called Privacy rather than Telemetry because that is the question the
/// section answers — what Jeansh sends about you — and because Report a bug
/// belongs beside the switch: they are the two ways anything goes out, and a
/// user looking for either is looking for the same thing.
class _PrivacySection extends StatelessWidget {
  const _PrivacySection();

  /// The plain truth, which is short enough to say in full: a count and
  /// crashes, and none of the things an SSH client knows.
  static const _what =
      'Counts this install once a day, and sends crashes so they can be '
      'fixed. No hostname, username, path or command ever leaves this '
      'device.';

  static const _off =
      'Nothing is sent. Report a bug below still works — that one is yours '
      'to press.';

  Future<void> _choose(BuildContext context, bool on) async {
    await telemetryOn.choose(on);
    if (!on) await stopCrashReporting();
    if (!context.mounted) return;
    if (!on && crashReportingStarted) {
      // Honest rather than tidy: Sentry was started at launch, so its native
      // crash handler is in the process until the app is started again.
      // Nothing more is sent either way — see `scrubEvent`.
      showToast(
        context,
        'Telemetry off\nNothing more is sent. Restart Jeansh to unload the '
        'crash handler as well.',
        duration: const Duration(seconds: 5),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionHeader('Privacy'),
      ValueListenableBuilder<bool>(
        valueListenable: telemetryOn,
        builder: (context, on, _) => SwitchListTile(
          secondary: const Icon(Icons.insights_outlined),
          title: const Text('Telemetry'),
          subtitle: Text(
            on
                ? (crashReportingConfigured
                      ? _what
                      : '$_what\n\nThis build has no crash reporting built '
                            'in, so only the count is sent.')
                : _off,
          ),
          isThreeLine: true,
          value: on,
          onChanged: (want) => _choose(context, want),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Report a bug'),
        subtitle: const Text(
          'Opens an issue on GitHub under your own name, or sends it '
          'anonymously through Jeansh. You read what goes before it goes.',
        ),
        onTap: () => showBugReport(context),
      ),
    ],
  );
}

/// The relay keys, one per host, that its shells get as `LC_SSHBOX_KEY` (see
/// `LiveSession.connect`): reset, every one, when one has got out. A host's
/// own is copied from its edit page.
class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection(this.notifyKeys);

  final NotifyKeys? notifyKeys;

  Future<void> _reset(BuildContext context, NotifyKeys notifyKeys) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset notification keys?'),
        content: const Text(
          "Every host's key is revoked. Servers holding an old key stop "
          'notifying this device until their host reconnects and gets a new '
          'one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await notifyKeys.reset();
    } catch (_) {
      if (context.mounted) {
        showToast(
          context,
          'Some old keys are not revoked yet\nNo host gets them again, and '
          'Jeansh tries again when it next starts.',
          type: ToastificationType.warning,
          duration: const Duration(seconds: 3),
        );
      }
      return;
    }
    if (context.mounted) {
      showToast(
        context,
        'Notification keys reset\nEach host gets a new one when it next '
        'connects.',
        type: ToastificationType.success,
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifyKeys = this.notifyKeys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Notifications'),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Reset notification keys'),
          subtitle: const Text(
            "Revoke every host's key, for when one has got out. A host's own "
            'is copied from its edit page.',
          ),
          enabled: notifyKeys != null,
          onTap: notifyKeys == null ? null : () => _reset(context, notifyKeys),
        ),
      ],
    );
  }
}
