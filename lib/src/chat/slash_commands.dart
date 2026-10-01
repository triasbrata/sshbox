import 'dart:convert';

/// Where a slash command comes from, in the order the list shows them.
enum SlashGroup {
  builtIn('Built-in'),
  yours('Your commands'),
  skills('Skills'),
  plugins('Plugins');

  const SlashGroup(this.label);
  final String label;
}

/// One command a Claude Code session on the host takes after a `/`, as the
/// CLI itself lists it: its answer to the SDK's `initialize` control request,
/// which carries every command with its description and argument hint, over
/// a pipe and with no terminal. Measured on 2.1.286: 282 commands, 1.5 s, and
/// no transcript left behind.
///
/// Everything here came from the host, and is shown as text and never run.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.description,
    required this.group,
    this.argumentHint = '',
    this.aliases = const [],
  });

  final String name;
  final String description;
  final String argumentHint;
  final SlashGroup group;
  final List<String> aliases;

  /// Whether chat offers it: anything but a built-in is a prompt Claude is
  /// given — a skill, a command file, a plugin's — and a built-in only when
  /// it is one of [_runs].
  bool get offered =>
      !_dialogs.contains(name) &&
      (group != SlashGroup.builtIn || _runs.contains(name));

  /// Built-ins, and their aliases, that open a dialog or may: measured, or
  /// terminal-only. Never offered or sent, whatever the row says, since a
  /// command file of the same name may still reach the built-in.
  static const _dialogs = {
    'model',
    'config',
    'settings',
    'mcp',
    'memory',
    'resume',
    'continue',
    'usage',
    'cost',
    'stats',
    'rewind',
    'checkpoint',
    'permissions',
    'allowed-tools',
    'agents',
    'hooks',
    'plugin',
    'plugins',
    'theme',
    'login',
    'logout',
    'status',
    'help',
    'ide',
    'export',
    'add-dir',
    'statusline',
    'privacy-settings',
    'terminal-setup',
    'vim',
    'upgrade',
    'feedback',
    'bug',
    'tasks',
    'todos',
    'skills',
    'output-style',
    'effort',
    'fast',
    'sandbox',
    'keybindings',
    'doctor',
    'exit',
    'quit',
  };

  /// The built-ins that run and print, or hand Claude a prompt, and never
  /// open a dialog. Chat types into a terminal it cannot see, where a dialog
  /// takes the next Enter as a choice — measured: text typed after /config
  /// landed in its search, and the Enter switched a setting — so a built-in
  /// is offered only when it is known to be one of these, and anything not
  /// known is refused. Measured on 2.1.286 in a terminal: /context and
  /// /color print and come back to the prompt; /model, /config, /mcp,
  /// /memory, /resume and /usage open a dialog. The rest are the CLI's
  /// prompt commands and its built-in skills, which hand Claude a prompt.
  static const _runs = {
    'compact',
    'clear',
    'context',
    'color',
    'init',
    'security-review',
    'code-review',
    'simplify',
    'debug',
    'verify',
    'batch',
    'recap',
  };

  /// A name the CLI could take as a command: no space and no control
  /// character, or it is left out of the list — a name is put into the box
  /// for sending, and a newline in one would send it.
  static final _nameShape = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$');

  /// Every control character but a tab, which a description may hold.
  static final _controls = RegExp(r'[\x00-\x08\x0a-\x1f\x7f-\x9f]');

  static String _text(Object? value) => value is String
      ? value.replaceAll(_controls, ' ').replaceAll(RegExp(r'\s+'), ' ').trim()
      : '';

  /// The commands in what [ClaudeChat.slashCommandsCommand] printed: the
  /// CLI's `control_response` line, then the command files of the user's own
  /// after [yoursMark]. Null when the host gave no list, for the caller to
  /// show what it said instead.
  static List<SlashCommand>? parse(String output) {
    final cut = output.indexOf(yoursMark);
    final listing = cut < 0 ? output : output.substring(0, cut);
    final yours = {
      if (cut >= 0)
        for (final line in const LineSplitter().convert(
          output.substring(cut + yoursMark.length),
        ))
          if (line.trim().endsWith('.md'))
            line.trim().split('/').last.replaceFirst(RegExp(r'\.md$'), ''),
    };
    List<Object?>? rows;
    for (final line in const LineSplitter().convert(listing)) {
      if (!line.startsWith('{') || !line.contains('control_response')) continue;
      try {
        final event = jsonDecode(line);
        final commands = event['response']?['response']?['commands'];
        if (commands is List) rows = commands;
      } catch (_) {
        // Not the line this was looking for.
      }
    }
    if (rows == null) return null;
    final commands = <SlashCommand>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final name = row['name'];
      if (name is! String || !_nameShape.hasMatch(name)) continue;
      if (!seen.add(name)) continue;
      commands.add(
        SlashCommand(
          name: name,
          description: _text(row['description']),
          argumentHint: _text(row['argumentHint']),
          aliases: [
            if (row['aliases'] case final List aliases)
              for (final alias in aliases)
                if (alias is String && _nameShape.hasMatch(alias)) alias,
          ],
          group: row['builtin'] == true
              ? SlashGroup.builtIn
              : name.contains(':')
              ? SlashGroup.plugins
              : yours.contains(name)
              ? SlashGroup.yours
              : SlashGroup.skills,
        ),
      );
    }
    return commands;
  }

  /// The line between the CLI's listing and the user's own command files.
  static const yoursMark = '\n--- yours\n';

  /// What the list shows for [query], the text after the `/`: the commands
  /// chat offers, in their groups, those whose name starts with it first and
  /// then those that hold it, each group in the CLI's order.
  static List<SlashCommand> matching(List<SlashCommand> all, String query) {
    final q = query.toLowerCase();
    bool starts(SlashCommand c) =>
        c.name.toLowerCase().startsWith(q) ||
        c.aliases.any((a) => a.toLowerCase().startsWith(q));
    bool holds(SlashCommand c) => c.name.toLowerCase().contains(q);
    final offered = all.where((c) => c.offered);
    return [
      for (final group in SlashGroup.values) ...[
        ...offered.where((c) => c.group == group && starts(c)),
        ...offered.where((c) => c.group == group && !starts(c) && holds(c)),
      ],
    ];
  }

  /// The command [text] names when it is one — a `/` and a name at its very
  /// start, then a space or nothing — or null. `/tmp/x` is a path.
  static String? named(String text) =>
      RegExp(r'^/([A-Za-z0-9][A-Za-z0-9:._-]*)(?:\s|$)').firstMatch(text)?[1];

  /// Why [text] is not sent from chat, or null when it may be: a command
  /// chat does not offer, or one the host does not list — a terminal-only
  /// one such as /permissions or /rewind, all of them dialogs. With no list
  /// read yet only the built-ins known to run go through.
  static String? refusal(String text, List<SlashCommand>? all) {
    final name = named(text.trimLeft());
    if (name == null) return null;
    final command = all == null
        ? (_runs.contains(name)
              ? SlashCommand(
                  name: name,
                  description: '',
                  group: SlashGroup.builtIn,
                )
              : null)
        : all
              .where((c) => c.name == name || c.aliases.contains(name))
              .firstOrNull;
    if (command != null && command.offered && !_dialogs.contains(name)) {
      return null;
    }
    return '/$name opens a dialog chat cannot answer, or is not one chat '
        'knows — run it in the terminal instead.';
  }
}

/// A command as a transcript records it, read back for the chat to draw.
///
/// Claude Code writes the command a user ran as tags, in a `user` line or a
/// `system` one of subtype `local_command`:
/// `<command-name>/color</command-name>`,
/// `<command-message>color</command-message>`,
/// `<command-args>cyan</command-args>`; and what a
/// command that runs in the CLI printed as
/// `<local-command-stdout>Session color set to: cyan</local-command-stdout>`,
/// with the terminal's colours in it. Measured on 2.1.286.
///
/// Each record opens with its tag, and an output record is nothing else,
/// so only those are read as such: a message that merely mentions the tags
/// mid-text stays a message.
abstract final class CommandTags {
  static final _starts = RegExp(r'^\s*<command-(?:name|message)>');
  static final _name = RegExp(r'<command-name>/?([^<\s]*)</command-name>');
  static final _args = RegExp(r'<command-args>([\s\S]*?)</command-args>');
  static final _record = RegExp(
    r'<local-command-(stdout|stderr)>([\s\S]*?)</local-command-\1>',
  );

  /// Content that is nothing but such records: a stdout, a stderr, or both.
  static final _records = RegExp(
    r'^(?:\s*<local-command-(stdout|stderr)>[\s\S]*?</local-command-\1>)+\s*$',
  );

  /// Terminal escapes and stray control bytes, tab and newline kept: CSI,
  /// OSC ended by BEL or ST, charset selects and C1 CSI.
  static final _ansi = RegExp(
    r'\x1b\[[0-?]*[ -/]*[@-~]|\x9b[0-?]*[ -/]*[@-~]'
    r'|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]'
    r'|[\x00-\x08\x0b-\x1f\x7f-\x9f]',
  );

  /// The command [text] records, or null when it records none.
  static ({String name, String args})? command(String text) {
    if (!_starts.hasMatch(text)) return null;
    final name = _name.firstMatch(text)?[1];
    if (name == null || name.isEmpty) return null;
    return (name: name, args: (_args.firstMatch(text)?[1] ?? '').trim());
  }

  /// What a command printed, its terminal colours taken out, or null when
  /// [text] is not that.
  static String? output(String text) {
    if (!_records.hasMatch(text)) return null;
    return [
      for (final record in _record.allMatches(text))
        record[2]!.replaceAll(_ansi, '').trimRight(),
    ].where((part) => part.isNotEmpty).join('\n');
  }
}
