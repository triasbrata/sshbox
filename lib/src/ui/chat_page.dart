import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../chat/claude_chat.dart';
import '../session/session_manager.dart';
import 'settings_page.dart' show terminalSettings;

/// A conversation with Claude Code running on the host, beside that host's
/// shell — what the VS Code plugin shows in its side panel: what was asked,
/// what Claude answered, and every tool it reached for on the way, each one
/// a row that opens to what it was given and what it gave back.
///
/// The page owns nothing of the conversation: it draws [LiveSession.chat] and
/// writes into it. Switching tabs, or scrolling away, leaves the process on
/// the host running and everything said still there.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.session});

  final LiveSession session;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Held rather than asked for each time: closing the tab lets the session
  /// go of its chat, and asking again would make a second one to take the
  /// listener off.
  late final ClaudeChat _chat = widget.session.chat;

  /// Whether the session was connected last time we looked, so Claude is
  /// started once per connection: a host with no Claude on it ends the
  /// moment it starts, and starting again on every change would be a loop.
  bool _wasConnected = false;

  /// How long the transcript was when it was last drawn, so a new entry
  /// scrolls into view and a rebuild for anything else does not.
  int _drawn = 0;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChanged);
    _chat.addListener(_onChanged);
    _onChanged();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onChanged);
    _chat.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final connected = widget.session.isConnected;
    if (connected && !_wasConnected) {
      _wasConnected = true;
      // After a reconnect the old process went with the old connection;
      // restarting resumes the same conversation on the new one.
      unawaited(_chat.ended ? _chat.restart() : _chat.start());
    } else if (!connected) {
      _wasConnected = false;
    }
    setState(() {});
    _followTranscript();
  }

  /// Keeps the newest entry in view, unless the reader has scrolled up to
  /// look at something — then it stays where they put it.
  void _followTranscript() {
    final entries = _chat.entries.length;
    if (entries == _drawn) return;
    _drawn = entries;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (end - _scroll.offset > 240) return;
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Shows what `claude agents` sees on the host, and picks one up.
  Future<void> _pickSession() async {
    final agent = await showModalBottomSheet<ClaudeAgent>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SessionSheet(chat: _chat),
    );
    if (agent == null || !mounted) return;
    await _chat.continueFrom(agent);
    _drawn = -1;
    _followTranscript();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _chat.send(text);
    _input.clear();
    // Whatever was said, the reader wants to be at the bottom again.
    _drawn = -1;
    _followTranscript();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chat = _chat;
    final entries = chat.entries;

    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? _Empty(session: widget.session, onPickSession: _pickSession)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(entries[index]),
                ),
        ),
        if (chat.busy)
          Row(
            children: [
              const SizedBox(width: 16),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text('Claude is working…', style: theme.textTheme.bodySmall),
            ],
          ),
        const Divider(height: 1),
        _composer(theme),
      ],
    );
  }

  Widget _entry(ChatEntry entry) => switch (entry) {
    ChatSaid(mine: true, :final text) => _Bubble(text: text),
    ChatSaid(:final text) => _Answer(text: text),
    final ChatToolRun run => _ToolRow(run: run),
    final ChatNotice notice => _Notice(notice: notice),
  };

  Widget _composer(ThemeData theme) {
    final chat = _chat;
    final canSend = chat.ready && !chat.busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PopupMenuButton<Object>(
              tooltip: 'Chat settings',
              icon: const Icon(Icons.more_vert),
              onSelected: (choice) {
                if (choice is ChatPermission) {
                  unawaited(chat.restart(permission: choice));
                } else if (choice == 'sessions') {
                  unawaited(_pickSession());
                } else {
                  unawaited(chat.restart());
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'sessions',
                  child: Text('Sessions on this host…'),
                ),
                const PopupMenuDivider(),
                for (final mode in ChatPermission.values)
                  CheckedPopupMenuItem(
                    value: mode,
                    checked: chat.permission == mode,
                    child: Text(mode.label),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'restart',
                  child: Text('Restart Claude'),
                ),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _input,
                enabled: chat.ready,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: chat.ready
                      ? 'Ask Claude…'
                      : widget.session.isConnected
                      ? 'Starting Claude on the host…'
                      : 'Connect this session first',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: 'Send',
              onPressed: canSend && _input.text.trim().isNotEmpty
                  ? _send
                  : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the tab says before anything has been asked.
class _Empty extends StatelessWidget {
  const _Empty({required this.session, required this.onPickSession});

  final LiveSession session;
  final VoidCallback onPickSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = session.host.fileRoot.trim();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Claude Code on ${session.host.displayName}',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              root.isEmpty
                  ? 'It runs on the host, in the login directory, and sees '
                        'the files there.'
                  : 'It runs on the host, in $root, and sees the files there.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Where a new chat tab lands, so the sessions already running on
            // the host are offered before anything has been typed.
            FilledButton.tonalIcon(
              onPressed: onPickSession,
              icon: const Icon(Icons.dashboard_customize_outlined),
              label: const Text('Sessions on this host'),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the user said: their own bubble, on their own side.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 8, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

/// What Claude said, as Markdown: it writes lists, headings and code, and
/// this is the renderer the Markdown preview already uses.
class _Answer extends StatelessWidget {
  const _Answer({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium!;
    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, terminal, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectionArea(
          child: MarkdownBody(
            data: text,
            // A reply is text, and any picture in it lives on a server we do
            // not fetch from: its alt text says what was meant.
            imageBuilder: (uri, title, alt) =>
                Text(alt == null || alt.isEmpty ? '$uri' : alt),
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: body,
              a: TextStyle(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary,
              ),
              code: body.copyWith(
                fontFamily: terminal.fontFamily,
                fontFamilyFallback: terminal.fontFamilyFallback,
                fontSize: body.fontSize! * 0.9,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
              codeblockDecoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tool Claude reached for: its name and the one line it is about, which
/// opens to what it was given and what came back.
class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.run});

  final ChatToolRun run;

  static IconData _iconFor(String name) => switch (name) {
    'Bash' || 'BashOutput' || 'KillShell' => Icons.terminal,
    'Read' || 'NotebookEdit' => Icons.description_outlined,
    'Edit' || 'Write' => Icons.edit_outlined,
    'Grep' || 'Glob' => Icons.search,
    'WebFetch' || 'WebSearch' => Icons.public,
    'Task' => Icons.group_outlined,
    'TodoWrite' => Icons.checklist,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = run.result;
    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, terminal, _) {
        final mono = theme.textTheme.bodySmall!.copyWith(
          fontFamily: terminal.fontFamily,
          fontFamilyFallback: terminal.fontFamilyFallback,
        );
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          color: scheme.surfaceContainerHighest,
          elevation: 0,
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: PageStorageKey(run.id),
              dense: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              leading: run.done
                  ? Icon(
                      _iconFor(run.name),
                      size: 18,
                      color: run.failed ? scheme.error : scheme.primary,
                    )
                  : const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              title: Row(
                children: [
                  Text(run.name, style: theme.textTheme.labelLarge),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      run.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              children: [
                if (run.input.isNotEmpty)
                  _block(
                    context,
                    const JsonEncoder.withIndent('  ').convert(run.input),
                    mono,
                  ),
                if (result != null && result.isNotEmpty)
                  _block(
                    context,
                    result,
                    mono.copyWith(color: run.failed ? scheme.error : null),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A slab of text that never grows past a screenful — a tool's answer can
  /// be hundreds of lines, and the transcript has to stay readable.
  Widget _block(BuildContext context, String text, TextStyle style) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxHeight: 240),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(child: SelectableText(text, style: style)),
      );
}

/// The run's own asides: it ended, it was refused, the host had nothing to
/// run. Quieter than anything that was said.
class _Notice extends StatelessWidget {
  const _Notice({required this.notice});

  final ChatNotice notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: SelectableText(
        notice.text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: notice.failed
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}


/// The sessions `claude agents` can see on the host, to pick one up in this
/// chat.
///
/// Every row is data from the host — a name is whatever the person who
/// started it typed — so it is drawn and never run.
class _SessionSheet extends StatefulWidget {
  const _SessionSheet({required this.chat});

  final ClaudeChat chat;

  @override
  State<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<_SessionSheet> {
  late Future<List<ClaudeAgent>> _agents = widget.chat.agents();

  void _again() => setState(() => _agents = widget.chat.agents());

  /// How long ago, in as few characters as a row can spare.
  static String _ago(DateTime? at) {
    if (at == null) return '';
    final since = DateTime.now().difference(at);
    if (since.inMinutes < 1) return 'just now';
    if (since.inHours < 1) return '${since.inMinutes}m ago';
    if (since.inDays < 1) return '${since.inHours}h ago';
    return '${since.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sessions on this host',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _again,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'One still running is picked up as a copy, so it carries on '
                'untouched and nothing said here reaches it.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Flexible(
              child: FutureBuilder<List<ClaudeAgent>>(
                future: _agents,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final error = snapshot.error;
                  if (error != null) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      // What the host said, as it said it: an old Claude with
                      // no agents command, or none installed at all.
                      child: SelectableText(
                        '$error',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    );
                  }
                  final agents = snapshot.data ?? const <ClaudeAgent>[];
                  if (agents.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      child: Text(
                        'No Claude sessions are running on this host.',
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: agents.length,
                    itemBuilder: (context, index) =>
                        _row(context, agents[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ClaudeAgent agent) {
    final theme = Theme.of(context);
    final where = [
      if (agent.interactive)
        'at a terminal'
      else if (agent.busy)
        'working'
      else if (agent.live)
        'idle'
      else
        'finished',
      if (_ago(agent.startedAt).isNotEmpty) _ago(agent.startedAt),
      if (agent.cwd.isNotEmpty) agent.cwd,
    ].join(' · ');
    return ListTile(
      leading: agent.busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              // Somebody is typing into an interactive one; a background one
              // is a job that was sent off.
              agent.interactive ? Icons.keyboard_outlined : Icons.forum_outlined,
              color: theme.colorScheme.primary,
            ),
      title: Text(agent.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        where,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => Navigator.pop(context, agent),
    );
  }
}
