import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/slash_commands.dart';
import 'tui.dart';

/// The list of slash commands that opens above the chat's box when it starts
/// with `/`, as Discord's does: each group under a heading, each command its
/// name, what it takes and what it does, narrowed as the name is typed.
/// Up and Down move through it, Enter or Tab or a tap put `/name ` in the
/// box, and Escape closes it until the box is emptied of its `/`.
///
/// It wraps the box: the box keeps its focus, and the keys the list wants
/// reach it first, only while it is open.
///
/// TODO(termul): termul has no command palette or autocomplete; this is
/// built from its box, section label, key hint and text.
class SlashCommandMenu extends StatefulWidget {
  const SlashCommandMenu({
    super.key,
    required this.controller,
    required this.commands,
    required this.child,
    this.onRefresh,
    this.onOpen,
  });

  /// Called as the list opens, for the host's commands to be read the first
  /// time they are wanted rather than with every connection.
  final VoidCallback? onOpen;

  final TextEditingController controller;

  /// The host's commands: null while they are being read, an error when
  /// they could not be.
  final AsyncSnapshot<List<SlashCommand>> commands;

  /// Reads the host's commands again: the ↻ in the list's heading.
  final VoidCallback? onRefresh;

  final Widget child;

  @override
  State<SlashCommandMenu> createState() => _SlashCommandMenuState();
}

class _SlashCommandMenuState extends State<SlashCommandMenu> {
  var _dismissed = false;
  var _at = 0;
  final _list = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(SlashCommandMenu old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _list.dispose();
    super.dispose();
  }

  String? _query;

  void _onText() {
    final query = _queryOf(widget.controller.text);
    if (query == _query) return;
    final opens = _query == null && query != null;
    setState(() {
      if (query == null) _dismissed = false;
      _query = query;
      _at = 0;
    });
    if (opens) widget.onOpen?.call();
  }

  /// What follows the `/` while a command name is still being typed: the
  /// box holding `/` and no space yet. Null otherwise.
  static String? _queryOf(String text) {
    if (!text.startsWith('/')) return null;
    final rest = text.substring(1);
    return rest.contains(RegExp(r'\s')) ? null : rest;
  }

  bool get _open => _query != null && !_dismissed;

  List<SlashCommand> get _matches => switch (widget.commands.data) {
    final all? => SlashCommand.matching(all, _query ?? ''),
    null => const [],
  };

  void _pick(SlashCommand command) {
    final text = '/${command.name} ';
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_open || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final matches = _matches;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _dismissed = true);
      return KeyEventResult.handled;
    }
    if (matches.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => _at = (_at + step) % matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _pick(matches[_at.clamp(0, matches.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_open) _menu(context),
      Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    ],
  );

  Widget _menu(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final matches = _matches;
    final snapshot = widget.commands;
    // Each group's heading before its first command.
    final rows = <Object>[];
    SlashGroup? group;
    for (final command in matches) {
      if (command.group != group) rows.add(group = command.group);
      rows.add(command);
    }
    final Widget body;
    if (snapshot.hasError) {
      body = Padding(
        padding: const EdgeInsets.all(8),
        child: TuiText(
          'Could not read the commands: ${snapshot.error}',
          tone: TuiTextTone.red,
          size: 12,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      );
    } else if (!snapshot.hasData) {
      body = const Padding(
        padding: EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(width: 12, height: 12, child: TuiSpinner()),
            SizedBox(width: 8),
            TuiText('Reading the commands on the host…', size: 12),
          ],
        ),
      );
    } else if (rows.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(8),
        child: TuiText(
          'No command chat can run starts with /$_query',
          tone: TuiTextTone.dim,
          size: 12,
        ),
      );
    } else {
      final at = _at.clamp(0, matches.length - 1);
      final highlighted = matches[at];
      body = ListView.builder(
        controller: _list,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: rows.length,
        itemBuilder: (context, index) => switch (rows[index]) {
          final SlashGroup group => Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: TuiSectionLabel(group.label),
          ),
          final SlashCommand command => _Row(
            command: command,
            highlighted: identical(command, highlighted),
            onTap: () => _pick(command),
          ),
          _ => const SizedBox.shrink(),
        },
      );
      _keepInView(rows.indexOf(highlighted), rows.length);
    }
    // No taller than a share of what the keyboard leaves, so the box, the
    // tab strip and some of the conversation stay on screen; the list
    // scrolls inside it.
    final media = MediaQuery.of(context);
    final room =
        media.size.height - media.viewInsets.bottom - media.padding.vertical;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: (room * 0.4).clamp(96, 300)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: p.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: TuiText(
                    _query!.isEmpty ? 'Commands' : 'Commands matching /$_query',
                    tone: TuiTextTone.muted,
                    size: 11,
                    bold: true,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Keys are for a keyboard, and only where they fit.
                if (media.size.width >= _hintsFrom) ...const [
                  TuiKeyHint(keys: '↑↓', label: 'move'),
                  SizedBox(width: 8),
                  TuiKeyHint(keys: '⏎', label: 'pick'),
                  SizedBox(width: 8),
                  TuiKeyHint(keys: 'esc', label: 'close'),
                ],
                IconButton(
                  tooltip: 'Read the commands again',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            TuiDivider(),
            Flexible(child: body),
          ],
        ),
      ),
    );
  }

  /// From this width the heading has room for its key hints.
  static const _hintsFrom = 600.0;

  /// Scrolls the list so the highlighted row stays on screen as the arrows
  /// move it. ponytail: by the row's share of the list, rows being near one
  /// height; measure them if a long list drifts.
  void _keepInView(int row, int rows) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_list.hasClients || rows == 0) return;
      final position = _list.position;
      final extent = position.maxScrollExtent + position.viewportDimension;
      final top = extent * row / rows;
      final bottom = extent * (row + 1) / rows;
      if (top < position.pixels) {
        _list.jumpTo(top);
      } else if (bottom > position.pixels + position.viewportDimension) {
        _list.jumpTo(
          (bottom - position.viewportDimension).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      }
    });
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.command,
    required this.highlighted,
    required this.onTap,
  });

  final SlashCommand command;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      button: true,
      selected: highlighted,
      label: '/${command.name}',
      child: InkWell(
        onTap: onTap,
        child: Container(
          // One height for every row, however narrow the page: each line
          // is cut rather than wrapped.
          height: 44,
          color: highlighted ? p.selection : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: TuiText(
                      '/${command.name}',
                      tone: TuiTextTone.accent,
                      size: 13,
                      bold: true,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (command.argumentHint.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: TuiText(
                        command.argumentHint,
                        tone: TuiTextTone.dim,
                        size: 12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              if (command.description.isNotEmpty)
                TuiText(
                  command.description,
                  tone: TuiTextTone.muted,
                  size: 12,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
