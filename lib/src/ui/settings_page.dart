import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'key_bar.dart';
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
  /// bar, in order, a custom key's with its `label` and its `send` as typed,
  /// then `{"id": "tab", "shown": false}` for each built-in key off it. Those
  /// tell a key taken off from one a later version adds, which joins the bar.
  /// v1 hid a key in the same words, so a key hidden then is off the bar now.
  static const _key = 'sshbox.keyBar.v1';

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
        items.add((id: id, custom: (label: label, send: send)));
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

/// Jeansh's settings: a list of sections, each a header and its rows.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.pushToken});

  /// Reads the device's push token, for Notifications to copy. Left out,
  /// there is none to copy.
  final String? Function()? pushToken;

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
          _NotificationsSection(pushToken),
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
                subtitle: const Text('A label, and the text it types'),
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
                    // What a key of the user's own types, as written.
                    subtitle: custom == null
                        ? null
                        : Text(
                            custom.send,
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

/// The form for a key of the user's own: the label it shows, short enough
/// for a key, and the text it types, escapes and all. Pops with the key, or
/// with nothing on Cancel.
class _CustomKeyDialog extends StatefulWidget {
  const _CustomKeyDialog(this.initial);

  /// The key being changed, or null for a new one.
  final CustomKey? initial;

  @override
  State<_CustomKeyDialog> createState() => _CustomKeyDialogState();
}

class _CustomKeyDialogState extends State<_CustomKeyDialog> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.initial?.label);
  late final _send = TextEditingController(text: widget.initial?.send);

  @override
  void dispose() {
    _label.dispose();
    _send.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop((label: _label.text.trim(), send: _send.text));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initial == null;

    return AlertDialog(
      scrollable: true,
      title: Text(isNew ? 'New custom key' : 'Change custom key'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _label,
              autofocus: true,
              // Twice PGUP, the widest built-in key.
              maxLength: 8,
              decoration: const InputDecoration(
                labelText: 'Label',
                helperText: 'What the key shows',
              ),
              validator: (label) =>
                  label!.trim().isEmpty ? 'Give the key a label' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _send,
              style: const TextStyle(fontFamily: 'monospace'),
              // Commands and escapes rather than words, and nothing for the
              // keyboard to learn: a key may well type a password.
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(
                labelText: 'Sends',
                helperText:
                    r'\n Enter, \t Tab, \e Esc, \\ backslash, \xHH any code. '
                    r'For example git status\n, or \e[15~ for F5',
                helperMaxLines: 4,
              ),
              validator: (send) {
                if (send!.isEmpty) return 'Type what the key sends';
                try {
                  decodeKeyText(send);
                } on FormatException catch (error) {
                  return error.message;
                }
                return null;
              },
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: Text(isNew ? 'Add' : 'Save')),
      ],
    );
  }
}

/// The device's push token, to copy by hand for a host that will not take
/// it the usual way, as `LC_SSHBOX_TOKEN` with every shell: see
/// `LiveSession.connect`.
class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection(this.pushToken);

  final String? Function()? pushToken;

  Future<void> _copy(BuildContext context) async {
    final token = pushToken?.call();
    if (token == null) {
      showToast(
        context,
        'No FCM token yet — push is unavailable',
        type: ToastificationType.warning,
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: token));
    if (context.mounted) {
      showToast(context, 'FCM token copied', type: ToastificationType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Notifications'),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('Copy notification token'),
          subtitle: const Text(
            'Normally sent to hosts automatically as LC_SSHBOX_TOKEN. Copy '
            'it only for a server that does not accept it.',
          ),
          onTap: () => _copy(context),
        ),
      ],
    );
  }
}
