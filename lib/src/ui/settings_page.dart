import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import '../notifications/notify_key.dart';
import '../platform.dart';
import '../system_fonts.dart';
import '../telemetry/crash_reporting.dart';
import '../telemetry/telemetry.dart';
import 'bug_report.dart';
import 'key_bar.dart';
import 'terminal_page.dart' show openUrl;
import 'update_dialog.dart';
import 'terminal_schemes.dart';
import 'tmux_panes.dart';
import 'toast.dart';
import 'tui.dart';

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
      type: TuiToastType.warning,
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

/// Whether this machine's own shells run in tmux, and which tmux. The Local
/// shell is saved nowhere, so its choice cannot live on a host, as a saved
/// host's `useTmux` does.
///
/// On to begin with: a shell where no tmux is found is a plain login shell,
/// as it always was. An empty [path] finds tmux the way an SSH host's is
/// found; anything else is that binary and no other.
///
/// Read when a shell opens, so a change reaches the next one and leaves what
/// is open alone.
class LocalTmuxSetting extends ValueNotifier<({bool on, String path})> {
  LocalTmuxSetting() : super((on: true, path: ''));

  static const _onKey = 'sshbox.local.tmux';
  static const _pathKey = 'sshbox.local.tmuxPath';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = (
      on: prefs.getBool(_onKey) ?? true,
      path: prefs.getString(_pathKey) ?? '',
    );
  }

  /// Applies to the next shell opened, and is saved for the next start. A
  /// [path] [tmuxPathProblem] turns down is not taken, and what it said is
  /// handed back.
  Future<String?> choose({bool? on, String? path}) async {
    final problem = path == null ? null : tmuxPathProblem(path);
    if (problem != null) return problem;
    value = (on: on ?? value.on, path: path ?? value.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onKey, value.on);
    await prefs.setString(_pathKey, value.path);
    return null;
  }
}

/// The app's one; `main` reads the saved choice into it.
final localTmux = LocalTmuxSetting();

/// Why [path] cannot be the Local shell's tmux, or null when it can: empty,
/// which finds one, or an absolute path to a file that can be run, links
/// followed, as Homebrew's is one.
String? tmuxPathProblem(String path) {
  if (path.isEmpty) return null;
  if (!path.startsWith('/')) return 'Give the whole path, from /.';
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return 'No file is at $path.';
  // Any of the three execute bits: whose they are, the shell asks at use.
  if (stat.mode & 0x49 == 0) return '$path is not executable.';
  return null;
}

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

/// A key a hardware keyboard holds down to make a click on the terminal open
/// the link under it: see [LinkModifierSetting].
enum LinkModifier {
  control('Ctrl'),
  command('⌘ Cmd'),
  alt('Alt');

  const LinkModifier(this.label);

  /// What Settings and the hint under it call the key.
  final String label;

  /// Whether the key is down now, on either side of the keyboard.
  bool get isPressed => switch (this) {
    control => HardwareKeyboard.instance.isControlPressed,
    command => HardwareKeyboard.instance.isMetaPressed,
    alt => HardwareKeyboard.instance.isAltPressed,
  };
}

/// Which key, held with a click, opens a link in the terminal: ⌘ or Ctrl on
/// a Mac, Ctrl or Alt on Linux and Windows. A phone or a tablet has only
/// Ctrl, a hardware keyboard's or the key bar's CTRL, which is not a choice
/// and is not offered.
///
/// ⌘ is a Mac's own: iTerm2, Terminal and VS Code all open a link on ⌘-click,
/// and elsewhere on a Mac Ctrl+click is a right click. Everywhere else Ctrl
/// is what it has always been. Whichever is picked, the other one no longer
/// opens anything: its click goes to the program in the terminal, as a click.
///
/// Read at the key and at the tap rather than watched, so a change reaches
/// the next click in every open terminal.
class LinkModifierSetting extends ValueNotifier<LinkModifier?> {
  LinkModifierSetting() : super(null);

  static const _key = 'sshbox.terminal.linkModifier';

  /// The keys this platform offers, its default first.
  static List<LinkModifier> get offered => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => const [LinkModifier.command, LinkModifier.control],
    TargetPlatform.linux ||
    TargetPlatform.windows => const [LinkModifier.control, LinkModifier.alt],
    _ => const [LinkModifier.control],
  };

  /// The key in use: the one picked, or the platform's default when none was
  /// or the one picked is not offered here.
  LinkModifier get chosen => offered.contains(value) ? value! : offered.first;

  /// Reads the saved choice. Nothing saved is the platform's default.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = LinkModifier.values.asNameMap()[prefs.getString(_key)];
  }

  /// Applies to the next click, and is saved for the next start.
  Future<void> choose(LinkModifier key) async {
    value = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, key.name);
  }
}

/// The app's one; `main` reads the saved choice into it.
final linkModifier = LinkModifierSetting();

/// Jeansh's settings, as termul's settings screen draws them: a back word
/// and the settings mark along the top, the page's name large, and each
/// section under a hairline and a label in capitals.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.notifyKeys});

  /// The relay keys, one per host, for Notifications to reset. Left out,
  /// there are none.
  final NotifyKeys? notifyKeys;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(
                children: [
                  TermulTextAction.back(context),
                  const Spacer(),
                  Icon(Icons.settings_outlined, size: 18, color: p.accent),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Settings',
                      style: text.displayMedium!.copyWith(
                        color: p.accent,
                        fontSize: 36,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'LOOK · TERMINAL · KEYBOARD · PRIVACY',
                    style: text.labelSmall!.copyWith(
                      color: p.dim,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const _ThemeSection(),
                  const _TerminalSection(),
                  const _SectionHeader('Keyboard'),
                  _Action(
                    label: 'Key bar',
                    prefix: '→',
                    note:
                        'The keys above the keyboard in a terminal: which '
                        'ones, and in what order.',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const KeyBarSettingsPage(),
                      ),
                    ),
                  ),
                  if (LinkModifierSetting.offered.length > 1)
                    const _LinkModifierTile(),
                  const _GitSection(),
                  // Desktop alone: only a desktop has a shell of its own to
                  // run.
                  if (isDesktop) const _LocalShellSection(),
                  _NotificationsSection(notifyKeys),
                  const _PrivacySection(),
                  // Desktop alone: Android updates through Play, and there is
                  // no desktop build to offer anywhere else.
                  if (isDesktop) ...[
                    const _SectionHeader('Updates'),
                    // TODO(termul): an action row with a spinner and a
                    // result line, until termul has one.
                    const UpdateTile(),
                  ],
                  const _AboutSection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// termul's break between two settings: a hairline, and the section's name
/// in capitals under it.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 28),
      const TuiDivider(),
      const SizedBox(height: 28),
      TuiSectionLabel(title),
      const SizedBox(height: 12),
    ],
  );
}

/// A label for one setting inside a section, as termul's `terminal font`.
class _Label extends StatelessWidget {
  const _Label(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 12),
    child: TuiSectionLabel(title),
  );
}

/// termul's line of small print under a setting.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall!.copyWith(
        color: TermulThemeData.of(context).palette.muted,
        height: 1.4,
      ),
    ),
  );
}

/// A setting that is something to do rather than a choice, as termul's
/// `report a bug`: a button with its small print under it.
class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.note,
    required this.onTap,
    this.prefix,
    this.variant = TuiButtonVariant.ghost,
  });

  final String label;
  final String note;
  final VoidCallback? onTap;
  final String? prefix;
  final TuiButtonVariant variant;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TuiButton(
            label: label,
            prefix: prefix,
            variant: variant,
            onPressed: onTap,
          ),
        ),
        _Note(note),
      ],
    ),
  );
}

/// Light, dark or the system's, and the theme, over a few lines of a shell
/// in the chosen theme's colours: termul's `system theme` and `terminal
/// theme`.
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
          TuiSelect<ThemeMode>(
            options: const [
              (ThemeMode.system, 'System'),
              (ThemeMode.light, 'Light'),
              (ThemeMode.dark, 'Dark'),
            ],
            value: look.mode,
            onChanged: (mode) => appTheme.choose(mode: mode),
          ),
          const _Label('Colours'),
          TuiSelect<TerminalScheme>(
            options: [
              for (final scheme in terminalSchemes) (scheme, scheme.name),
            ],
            value: look.scheme,
            onChanged: (scheme) => appTheme.choose(scheme: scheme),
          ),
          const SizedBox(height: 12),
          _SchemePreview(look.scheme),
        ],
      ),
    );
  }
}

/// termul's theme preview: a few lines of a shell in [scheme]'s colours, as
/// the terminal would draw them in the brightness in use — a prompt, a
/// listing and a commit, in green, cyan, magenta, blue, red and yellow.
class _SchemePreview extends StatelessWidget {
  const _SchemePreview(this.scheme);

  final TerminalScheme scheme;

  @override
  Widget build(BuildContext context) {
    final colors = scheme.terminal(Theme.of(context).brightness);
    TextSpan token(String text, Color color) => TextSpan(
      text: text,
      style: TextStyle(color: color),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      color: colors.background,
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            color: colors.foreground,
            fontFamily: TermulFonts.mono,
            fontSize: 13,
            height: 1.45,
          ),
          children: [
            token('➜ ', colors.green),
            token('~/src ', colors.cyan),
            token('main\n', colors.magenta),
            token('lib ', colors.blue),
            token('.env ', colors.red),
            const TextSpan(text: 'README.md\n'),
            token('a1b2c3d ', colors.yellow),
            const TextSpan(text: 'fix the key bar'),
          ],
        ),
        maxLines: 3,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    );
  }
}

/// termul's font row: the name in the font itself, USE or SELECTED at its
/// right, and under the name a line in the terminal's own style, so what the
/// row shows is what a shell gets: no ligatures, and the Nerd Font behind it.
class _FontOption extends StatelessWidget {
  const _FontOption({
    required this.title,
    required this.family,
    required this.sample,
    required this.selected,
    required this.onTap,
    this.note,
    this.action,
  });

  final String title;
  final String family;
  final String? sample;
  final bool selected;
  final VoidCallback? onTap;

  /// A word after the name, dim, as `on this computer`.
  final String? note;

  /// In place of USE and SELECTED.
  final String? action;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final small = Theme.of(context).textTheme.labelSmall!;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: title,
                            style: TextStyle(
                              fontFamily: family,
                              fontSize: 16,
                              color: selected ? p.accent : p.text,
                              fontWeight: selected
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                          ),
                          if (note != null)
                            TextSpan(
                              text: '  $note',
                              style: small.copyWith(color: p.dim),
                            ),
                        ],
                      ),
                    ),
                    if (sample case final sample?) ...[
                      const SizedBox(height: 6),
                      Text(
                        sample,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: terminalStyleOf(
                          family,
                          14,
                        ).toTextStyle().copyWith(color: p.muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                action ?? (selected ? 'SELECTED' : 'USE'),
                style: small.copyWith(
                  color: selected ? p.accent : p.dim,
                  letterSpacing: 0.4,
                ),
              ),
            ],
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
    final p = TermulThemeData.of(context).palette;
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
        _FontOption(
          title: chosen ? family : 'Installed on this computer…',
          family: chosen ? family : TermulFonts.mono,
          note: chosen ? 'on this computer' : null,
          sample: chosen
              ? _sample
              : switch (listed) {
                  _ when !done => 'Reading this computer\'s fonts…',
                  null => 'Its fonts could not be listed: type a name',
                  final listed => '${listed.length} families, monospaced first',
                },
          selected: chosen,
          action: chosen ? 'CHANGE' : 'PICK',
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
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: p.deep),
                const SizedBox(width: 8),
                Expanded(
                  child: TuiText(
                    '$family is proportional, so the terminal\'s columns '
                    'will not line up.',
                    tone: TuiTextTone.muted,
                    size: 11,
                  ),
                ),
              ],
            ),
          ),
        const TuiDivider(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, style, _) {
        final cell = terminalCellSize(style, MediaQuery.textScalerOf(context));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader('Terminal'),
            SizedBox(
              height: _previewRows * cell.height + _previewPadding.vertical,
              // Only to look at: a tap would take focus for a terminal that
              // has nothing behind it.
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
            const _Label('Font size'),
            TuiSelect<double>(
              options: [
                for (
                  var size = minFontSize.round();
                  size <= maxFontSize.round();
                  size++
                )
                  (size.toDouble(), '${size}px'),
              ],
              value: style.fontSize.roundToDouble(),
              onChanged: (size) => terminalSettings.choose(size: size),
            ),
            const _Label('Font'),
            for (final font in terminalFonts) ...[
              _FontOption(
                title: font.label,
                family: font.family,
                note: font.note,
                sample: _sample,
                selected: font.family == style.fontFamily,
                onTap: () => terminalSettings.choose(family: font.family),
              ),
              const TuiDivider(),
            ],
            // Below the bundled fonts, since what the note says of them is
            // not true of it.
            if (_installed case final installed?)
              FutureBuilder(
                future: installed,
                builder: (context, fonts) =>
                    _installedFont(context, style, fonts),
              ),
            const _Note(
              'The fonts listed first ship inside Jeansh, so they work '
              'offline. A glyph a font lacks comes from $nerdFontFamily (a '
              'prompt\'s powerline arrows) or from $symbolFontFamily, for '
              'symbols like ⏵⏵ that no code font draws.',
            ),
            if (isDesktop) ...[
              const SizedBox(height: 28),
              ValueListenableBuilder(
                valueListenable: copyOnSelect,
                builder: (context, on, _) => TuiSwitch(
                  label: 'Copy on select',
                  value: on,
                  onChanged: copyOnSelect.choose,
                ),
              ),
              const _Note(
                'Text selected with the mouse goes to the clipboard as the '
                'button comes up.',
              ),
            ],
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
  // Heard here rather than through the field, which has no onChanged: the
  // list narrows as the filter is typed.
  late final _field = TextEditingController()
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fonts = widget.fonts;
    final typed = _field.text.trim();
    final shown = [
      for (final font in fonts ?? const <SystemFont>[])
        if (font.family.toLowerCase().contains(typed.toLowerCase())) font,
    ];
    void pick(String family) => Navigator.of(context).pop(family);

    final p = TermulThemeData.of(context).palette;
    return TuiDialog(
      title: 'Installed fonts',
      maxWidth: 520,
      actions: [
        TuiButton(
          label: 'Cancel',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (fonts == null)
          TuiButton(
            label: 'Use',
            onPressed: typed.isEmpty ? null : () => pick(typed),
          ),
      ],
      child: SizedBox(
        height: fonts == null ? null : 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TuiInput(
              controller: _field,
              autofocus: true,
              prompt: fonts == null ? '❯' : '/',
              hint: fonts == null ? 'Family name' : 'Filter',
              textInputAction: TextInputAction.done,
              onSubmitted: fonts == null && typed.isNotEmpty
                  ? (_) => pick(typed)
                  : null,
            ),
            const SizedBox(height: 8),
            if (fonts == null)
              TuiText(
                'This computer\'s fonts could not be listed. Type the family '
                'name of one installed here.',
                tone: TuiTextTone.muted,
                size: 11,
              )
            else if (shown.isEmpty)
              const Expanded(
                child: Center(
                  child: TuiText(
                    'No installed font matches.',
                    tone: TuiTextTone.muted,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const TuiDivider(),
                  itemBuilder: (context, index) {
                    final font = shown[index];
                    final chosen = font.family == widget.chosen;
                    return InkWell(
                      onTap: () => pick(font.family),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    font.family,
                                    style: TextStyle(
                                      fontFamily: TermulFonts.mono,
                                      fontSize: 14,
                                      color: chosen ? p.accent : p.text,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  // In the font itself, as the terminal would
                                  // draw it: a symbols font's name alone could
                                  // not be read in it.
                                  Text(
                                    widget.sample,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.fade,
                                    style: terminalStyleOf(
                                      font.family,
                                      14,
                                    ).toTextStyle().copyWith(color: p.muted),
                                  ),
                                ],
                              ),
                            ),
                            if (font.mono)
                              const TuiText(
                                'monospaced',
                                tone: TuiTextTone.dim,
                                size: 10,
                              ),
                          ],
                        ),
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
    final confirmed = await showTuiConfirmDialog(
      context,
      title: 'key bar',
      message: 'Reset the key bar?',
      detail:
          'The keys it came with go back in their first places, and custom '
          'keys are deleted.',
      confirmLabel: 'Reset',
      cancelLabel: 'Cancel',
    );

    if (confirmed) await keyBarSettings.reset();
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
    final picked = await showTuiSheet<String>(
      context,
      builder: (context) {
        void pick(String id) => Navigator.of(context).pop(id);
        return Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: TuiSectionLabel('Add key'),
              ),
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
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TuiButton(
                      label: 'Divider',
                      prefix: '│',
                      variant: TuiButtonVariant.ghost,
                      onPressed: () => pick(keyBarDivider),
                    ),
                    TuiButton(
                      label: 'Custom key…',
                      prefix: '+',
                      onPressed: () => pick(customKeyPrefix),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: TuiText(
                  'A custom key is any key, with Ctrl, Alt, Shift or Super, '
                  'on a PC or macOS layout.',
                  tone: TuiTextTone.muted,
                  size: 11,
                ),
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
    final p = TermulThemeData.of(context).palette;

    return Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: keyBarSettings,
          builder: (context, items, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Row(
                  children: [
                    TermulTextAction.back(context),
                    const Spacer(),
                    TermulTextAction(
                      label: 'Reset to default',
                      text: 'RESET',
                      color: p.dim,
                      onTap: _reset,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Key bar',
                          style: Theme.of(context).textTheme.displayMedium!
                              .copyWith(color: p.accent, fontSize: 36),
                        ),
                      ),
                    ),
                    TuiButton(label: 'Add key', prefix: '+', onPressed: _add),
                  ],
                ),
              ),
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
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: TuiText(
                  'Files and upload always come first. Drag a key by its handle '
                  'to move it, and tap a key of your own to change it.',
                  tone: TuiTextTone.muted,
                  size: 11,
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  itemCount: items.length,
                  onReorderItem: (from, to) => keyBarSettings.choose(
                    [...items]
                      ..removeAt(from)
                      ..insert(to, items[from]),
                  ),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final custom = item.custom;
                    return Container(
                      // Dividers repeat, so each is known by how many came
                      // before it.
                      key: ValueKey((
                        item.id,
                        items.take(index).where((i) => i.id == item.id).length,
                      )),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: p.border)),
                      ),
                      child: InkWell(
                        onTap: custom == null ? null : () => _edit(item),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                index: index,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Icon(
                                    Icons.drag_handle,
                                    size: 18,
                                    color: p.dim,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _label(item),
                                      style: TextStyle(
                                        fontFamily: TermulFonts.mono,
                                        fontSize: 14,
                                        fontWeight: item.id == keyBarDivider
                                            ? FontWeight.w400
                                            : FontWeight.w500,
                                        color: item.id == keyBarDivider
                                            ? p.muted
                                            : p.text,
                                      ),
                                    ),
                                    // What a key of the user's own stands for,
                                    // `Ctrl+Alt+R` or `⌥⌫`, or for one made
                                    // before the picker, its text as written.
                                    if (custom != null)
                                      TuiText(
                                        switch (custom.combo) {
                                          final combo? => keyComboText(combo),
                                          null => custom.send,
                                        },
                                        tone: TuiTextTone.dim,
                                        size: 11,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                onPressed: () => _remove(index),
                                icon: Icon(
                                  Icons.remove_circle_outline,
                                  size: 18,
                                  color: p.dim,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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

    final p = TermulThemeData.of(context).palette;
    return Dialog(
      // Close to the edges on a phone, where a keyboard needs the width; a
      // card of its own on a tablet.
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: p.panel,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // termul's dialog head: a label in capitals, then the question.
              Semantics(
                header: true,
                child: Text(
                  isNew ? 'New custom key' : 'Change custom key',
                  style: theme.textTheme.headlineMedium!.copyWith(
                    color: p.text,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TuiSelect<bool>(
                  options: const [(false, 'PC'), (true, 'macOS')],
                  value: _mac,
                  onChanged: (mac) {
                    _change(() => _mac = mac);
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
                        fontFamily: TermulFonts.mono,
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
              const SizedBox(height: 12),
              TuiField(
                label: 'Label',
                controller: _label,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(customKeyLabelMax),
                ],
                helper: 'What the key shows',
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    TuiButton(
                      label: 'Clear',
                      variant: TuiButtonVariant.ghost,
                      onPressed: _clear,
                    ),
                    const Spacer(),
                    TuiButton(
                      label: 'Cancel',
                      variant: TuiButtonVariant.ghost,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    TuiButton(
                      label: isNew ? 'Add' : 'Save',
                      onPressed: _key == null ? null : _save,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which key a click holds to open a link, on a desktop, where there are two
/// to pick from; with the hint under it naming the one in use.
class _LinkModifierTile extends StatelessWidget {
  const _LinkModifierTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: linkModifier,
      builder: (context, _, _) {
        final chosen = linkModifier.chosen;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Label('Open links with'),
            TuiSelect<LinkModifier>(
              options: [
                for (final key in LinkModifierSetting.offered) (key, key.label),
              ],
              value: chosen,
              onChanged: linkModifier.choose,
            ),
            _Note(
              'Hold ${chosen.label} and click a URL, a path or a link a '
              'program printed in the terminal to open it. A click without '
              'it focuses and selects as it always has.',
            ),
          ],
        );
      },
    );
  }
}

/// Where the git button puts the repositories: a tab of their own, or a
/// drawer over the terminal. The panel itself is the same either way.
class _GitSection extends StatelessWidget {
  const _GitSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Git'),
        const _Label('Open the git panel as'),
        ValueListenableBuilder(
          valueListenable: gitInDrawer,
          builder: (context, drawer, _) => TuiSelect<bool>(
            options: const [(false, 'Tab'), (true, 'Drawer')],
            value: drawer,
            onChanged: gitInDrawer.choose,
          ),
        ),
        const _Note(
          'A tab sits beside the shell and stays until you close it; a '
          'drawer slides over the terminal and goes when you tap away. A '
          'git tab already open stays a tab.',
        ),
      ],
    );
  }
}

/// This machine's own shells in tmux: see [localTmux]. On Windows the Local
/// shell is PowerShell, which has no tmux, so the switch is for the WSL
/// shells there, and each distro finds its own tmux, so there is no path to
/// give.
class _LocalShellSection extends StatefulWidget {
  const _LocalShellSection();

  @override
  State<_LocalShellSection> createState() => _LocalShellSectionState();
}

class _LocalShellSectionState extends State<_LocalShellSection> {
  late final _path = TextEditingController(text: localTmux.value.path);
  final _focus = FocusNode();

  /// Why the path typed was not taken, until it is typed again.
  String? _problem;

  @override
  void initState() {
    super.initState();
    // Taken when the field is left as well as on Enter: a path typed and
    // clicked away from is a path meant.
    _focus.addListener(() {
      if (!_focus.hasFocus) _apply();
    });
  }

  @override
  void dispose() {
    _path.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final problem = await localTmux.choose(path: _path.text.trim());
    if (mounted) setState(() => _problem = problem);
  }

  @override
  Widget build(BuildContext context) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    return ValueListenableBuilder(
      valueListenable: localTmux,
      builder: (context, setting, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader('Local shell'),
          TuiSwitch(
            label: windows
                ? 'Use tmux in WSL shells'
                : 'Use tmux in the Local shell',
            value: setting.on,
            onChanged: (on) => localTmux.choose(on: on),
          ),
          const _Note(
            'Where tmux is found: panes split, and sessions outlive the '
            'app. Where it is not, a plain login shell. Applies to the next '
            'shell opened.',
          ),
          if (!windows) ...[
            const SizedBox(height: 20),
            TuiField(
              label: 'tmux binary',
              controller: _path,
              focusNode: _focus,
              enabled: setting.on,
              autocorrect: false,
              hint: 'Found by itself',
              helper:
                  'Empty looks on PATH, in Homebrew and the other usual '
                  'places. A path is used instead.',
              errorText: _problem,
              onChanged: (_) {
                if (_problem != null) setState(() => _problem = null);
              },
              onSubmitted: (_) => _apply(),
            ),
          ],
        ],
      ),
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
        builder: (context, on, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TuiSwitch(
              label: 'Telemetry',
              value: on,
              onChanged: (want) => _choose(context, want),
            ),
            _Note(
              on
                  ? (crashReportingConfigured
                        ? _what
                        : '$_what\n\nThis build has no crash reporting built '
                              'in, so only the count is sent.')
                  : _off,
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      _Action(
        label: 'Report a bug',
        prefix: '!',
        note:
            'Opens an issue on GitHub under your own name, or sends it '
            'anonymously through Jeansh. You read what goes before it goes.',
        onTap: () => showBugReport(context),
      ),
    ],
  );
}

/// Who made what Jeansh is built from: the credit its look owes termul and
/// the kit's author, and every package's licence, on Flutter's own page,
/// termul's among them.
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionHeader('About'),
      _Action(
        label: 'Design based on termul by Iyan Qalbi',
        prefix: '→',
        note:
            'A Flutter kit for terminal-style apps, MIT licensed. Opens its '
            'GitHub page.',
        onTap: () => openUrl(context, Uri.parse(termulUrl)),
      ),
      _Action(
        label: 'Iyan Qalbi on GitHub',
        prefix: '→',
        note: 'The author of termul.',
        onTap: () => openUrl(context, Uri.parse(termulAuthorUrl)),
      ),
      _Action(
        label: 'Open-source licences',
        prefix: '→',
        note: 'The licence of every package and font Jeansh ships.',
        onTap: () =>
            showLicensePage(context: context, applicationName: 'Jeansh'),
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
    final confirmed = await showTuiConfirmDialog(
      context,
      title: 'reset keys',
      message: 'Reset notification keys?',
      detail:
          "Every host's key is revoked. Servers holding an old key stop "
          'notifying this device until their host reconnects and gets a new '
          'one.',
      confirmLabel: 'Reset',
      cancelLabel: 'Cancel',
    );
    if (!confirmed) return;

    try {
      await notifyKeys.reset();
    } catch (_) {
      if (context.mounted) {
        showToast(
          context,
          'Some old keys are not revoked yet\nNo host gets them again, and '
          'Jeansh tries again when it next starts.',
          type: TuiToastType.warning,
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
        type: TuiToastType.success,
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
        _Action(
          label: 'Reset notification keys',
          prefix: '↺',
          variant: TuiButtonVariant.danger,
          note:
              "Revoke every host's key, for when one has got out. A host's "
              'own is copied from its edit page.',
          onTap: notifyKeys == null ? null : () => _reset(context, notifyKeys),
        ),
      ],
    );
  }
}
