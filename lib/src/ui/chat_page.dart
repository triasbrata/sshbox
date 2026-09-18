import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
      // After a reconnect the old process, or the follow of a session being
      // watched, went with the old connection: it is picked up again on the
      // new one, the same conversation either way.
      unawaited(_chat.resume());
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

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// From this width the sessions stay in view beside the conversation, as a
  /// sidebar; below it they slide in over it, as the files drawer does beside
  /// a terminal. Material's expanded breakpoint: a tablet held either way,
  /// and not a phone.
  static const _wide = 840.0;

  /// Whether the sidebar is showing on a wide screen. It starts showing —
  /// that is where the sessions were asked to be — and the button beside the
  /// box hides it for more room to read.
  bool _sidebarOpen = true;

  /// Shows the sessions: the sidebar on a wide screen, the drawer on a
  /// narrow one.
  void _showSessions(bool wide) {
    if (wide) {
      setState(() => _sidebarOpen = true);
    } else {
      _scaffoldKey.currentState?.openDrawer();
    }
  }

  void _toggleSessions(bool wide) {
    if (wide) {
      setState(() => _sidebarOpen = !_sidebarOpen);
    } else {
      _scaffoldKey.currentState?.openDrawer();
    }
  }

  /// Picks [agent] up in this chat, and, on a narrow screen, gets the drawer
  /// out of the way of what it brought.
  Future<void> _pick(ClaudeAgent agent) async {
    _scaffoldKey.currentState?.closeDrawer();
    await _chat.continueFrom(agent);
    if (!mounted) return;
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= _wide;
      final sidebar = wide && _sidebarOpen;
      final sessions = _SessionList(
        chat: _chat,
        connected: widget.session.isConnected,
        onPick: _pick,
      );
      return Scaffold(
        key: _scaffoldKey,
        drawer: wide
            ? null
            : Drawer(
                width: math.min(360, box.maxWidth * 0.85),
                child: SafeArea(child: sessions),
              ),
        // Opened by its button only: a sideways drag here is somebody
        // scrolling a wide code block.
        drawerEnableOpenDragGesture: false,
        body: Row(
          children: [
            if (sidebar) ...[
              SizedBox(width: 300, child: sessions),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: _conversation(wide: wide, sidebar: sidebar)),
          ],
        ),
      );
    },
  );

  Widget _conversation({required bool wide, required bool sidebar}) {
    final theme = Theme.of(context);
    final chat = _chat;
    final entries = chat.entries;

    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? _Empty(
                  session: widget.session,
                  // Beside a sidebar already showing them, a button to show
                  // them would do nothing.
                  onPickSession: sidebar ? null : () => _showSessions(wide),
                )
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
        _composer(theme, wide: wide, sidebar: sidebar),
      ],
    );
  }

  Widget _entry(ChatEntry entry) => switch (entry) {
    ChatSaid(mine: true) => _Bubble(said: entry),
    ChatSaid(:final text) => _Answer(text: text),
    final ChatToolRun run => _ToolRow(run: run),
    final ChatNotice notice => _Notice(notice: notice),
  };

  Widget _composer(
    ThemeData theme, {
    required bool wide,
    required bool sidebar,
  }) {
    final chat = _chat;
    final watching = chat.watching;
    // Into a session being watched, what is typed goes to that session and
    // queues behind whatever it is doing; to this chat's own Claude, only
    // between its turns.
    final open = watching != null || chat.ready;
    final canSend = watching != null || (chat.ready && !chat.busy);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: sidebar
                  ? 'Hide the sessions on this host'
                  : 'Sessions on this host',
              isSelected: sidebar,
              onPressed: () => _toggleSessions(wide),
              icon: const Icon(Icons.view_sidebar_outlined),
              selectedIcon: const Icon(Icons.view_sidebar),
            ),
            PopupMenuButton<Object>(
              tooltip: 'Chat settings',
              icon: const Icon(Icons.more_vert),
              onSelected: (choice) {
                if (choice is ChatPermission) {
                  unawaited(chat.restart(permission: choice));
                } else {
                  unawaited(chat.restart());
                }
              },
              itemBuilder: (context) => [
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
                enabled: open,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: watching != null
                      ? 'Message “${watching.name}”…'
                      : chat.ready
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
  const _Empty({required this.session, this.onPickSession});

  final LiveSession session;

  /// Null while the sessions are already in view beside it.
  final VoidCallback? onPickSession;

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
            // Where a new chat tab lands, so the sessions already running on
            // the host are offered before anything has been typed.
            if (onPickSession case final show?) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: show,
                icon: const Icon(Icons.view_sidebar_outlined),
                label: const Text('Sessions on this host'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the user said: their own bubble, on their own side — and, for a
/// message typed into a session being watched, where it has got to, until
/// that session has recorded it.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.said});

  final ChatSaid said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final delivery = said.delivery;
    final failed = delivery == Delivery.failed;
    final note = switch (delivery) {
      Delivery.sending => 'Sending…',
      Delivery.queued => 'Queued: it runs after what the session is doing.',
      Delivery.failed => said.why ?? 'Not delivered.',
      null => null,
    };
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8, left: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              // Not in the session yet, so not quite said.
              opacity: delivery == null ? 1 : 0.6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: failed
                      ? scheme.errorContainer
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  said.text,
                  style: TextStyle(
                    color: failed
                        ? scheme.onErrorContainer
                        : scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(
                  note,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
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
/// chat: the sidebar on a wide screen, the drawer on a narrow one.
///
/// Every row is data from the host — a name is whatever the person who
/// started it typed — so it is drawn and never run.
class _SessionList extends StatefulWidget {
  const _SessionList({
    required this.chat,
    required this.connected,
    required this.onPick,
  });

  final ClaudeChat chat;

  /// Whether the session is up: the list is asked for over its connection,
  /// and asked again when it comes back.
  final bool connected;
  final ValueChanged<ClaudeAgent> onPick;

  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  Future<List<ClaudeAgent>>? _agents;

  @override
  void initState() {
    super.initState();
    if (widget.connected) _agents = widget.chat.agents();
  }

  @override
  void didUpdateWidget(covariant _SessionList old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _again();
  }

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
    final agents = _agents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Sessions on this host',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: widget.connected ? _again : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'One still running is picked up as a copy, so it carries on '
            'untouched and nothing said here reaches it.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: agents == null
              ? _say(context, 'Connect this session to see its Claude sessions.')
              : FutureBuilder<List<ClaudeAgent>>(
                  future: agents,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final error = snapshot.error;
                    if (error != null) {
                      // What the host said, as it said it: an old Claude with
                      // no agents command, or none installed at all.
                      return _say(context, '$error', failed: true);
                    }
                    final rows = snapshot.data ?? const <ClaudeAgent>[];
                    if (rows.isEmpty) {
                      return _say(
                        context,
                        'No Claude sessions are running on this host.',
                      );
                    }
                    return ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) =>
                          _row(context, rows[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _say(BuildContext context, String text, {bool failed = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: failed ? theme.colorScheme.error : null,
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
      // The one this chat was picked up from, so which is showing is never a
      // guess.
      selected: agent.sessionId == widget.chat.pickedFrom,
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
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      // Pinned in `claude agents` on the host, and so first here too.
      trailing: agent.pinned
          ? Tooltip(
              message: 'Pinned',
              child: Icon(
                Icons.push_pin,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            )
          : null,
      onTap: () => widget.onPick(agent),
    );
  }
}
