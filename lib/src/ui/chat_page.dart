import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../chat/claude_chat.dart';
import '../session/session_manager.dart';
import 'code_languages.dart';
import 'settings_page.dart' show terminalSettings;
import 'terminal_page.dart' show openUrl;
import 'toast.dart';
import 'tui.dart';

/// A conversation with Claude Code running on the host, beside that host's
/// shell — what the VS Code plugin shows in its side panel: what was asked,
/// what Claude answered, and every tool it reached for on the way, each one
/// a row that opens to what it was given and what it gave back.
///
/// The page owns nothing of the conversation: it draws [LiveSession.chat] and
/// writes into it. Switching tabs, or scrolling away, leaves the process on
/// the host running and everything said still there.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.session, this.onOpenWeb});

  final LiveSession session;

  /// Opens a web page in a tab beside this chat's shell, as a link tapped in
  /// the terminal or the Markdown preview does — see [openUrl], which decides
  /// whether a tab is wanted at all.
  final void Function(Uri url)? onOpenWeb;

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

  /// How long the transcript was when it was last drawn, below where it
  /// opened, so a new entry scrolls into view and a rebuild for anything
  /// else — earlier turns going in above — does not.
  int _drawn = 0;

  int get _below => _chat.entries.length - _chat.earlier;

  /// Where the conversation opened: earlier turns grow up from it, and new
  /// ones down, so neither moves what is on screen.
  final _opened = UniqueKey();

  /// The sessions on the host, as last asked for. Held here rather than by
  /// the list, which goes whenever the sidebar is hidden or the drawer shut:
  /// held there, it came back empty. Asked for when the connection comes up,
  /// and again only by Refresh or when this chat starts a session of its own.
  Future<List<ClaudeAgent>>? _agents;

  // A block, not an arrow: an arrow would hand setState the future. Its
  // error is the list's to show, and it may not be showing yet.
  void _listAgents() {
    _agents = _chat.agents(all: true)..ignore();
  }

  /// Nearer the end than this, the reader is following: a new entry scrolls
  /// into view.
  static const _nearEnd = 240.0;

  /// Nearer the end than this, a session is left at its bottom, and is come
  /// back to at its end, however much it wrote meanwhile. Anything further up
  /// is a place somebody scrolled to, kept however small: a few lines up is
  /// still well inside [_nearEnd], and was once taken for the bottom.
  static const _atEnd = 2.0;

  /// Where each session was left scrolled up, by host and session: kept for
  /// as long as the app runs, so picking one again, or closing the tab and
  /// opening it again, comes back to the same place. A session left at the
  /// bottom has no entry, and comes back at its bottom — newest first, and
  /// still following what it goes on to write.
  static final _leftAt = <String, double>{};

  String? _placeOf(String? sessionId) =>
      sessionId == null ? null : '${widget.session.host.id} $sessionId';

  /// True while one session is being swapped for another, when what the
  /// list scrolls to is the old one's place and not to be kept for the new.
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChanged);
    _chat.addListener(_onChanged);
    _scroll.addListener(_onScrolled);
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
      _listAgents();
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

  /// Notes where the session showing was left: as it is scrolled, since by
  /// the time the tab closes the list has already let go of its position.
  void _onScrolled() {
    final place = _placeOf(_chat.pickedFrom);
    if (_switching || place == null) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > _atEnd) {
      _leftAt[place] = position.pixels;
    } else {
      _leftAt.remove(place);
    }
  }

  /// Keeps the newest entry in view, unless the reader has scrolled up to
  /// look at something — then it stays where they put it.
  void _followTranscript() {
    final entries = _below;
    if (entries == _drawn) return;
    _drawn = entries;
    if (_switching) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (end - _scroll.offset > _nearEnd) return;
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Puts a session just picked where it was left, [at] — or, left at the
  /// bottom or never seen, at its bottom.
  ///
  /// A lazy list only knows how long it is once the rows near where it
  /// stands are built: until then its end is a guess from the rows it has,
  /// and short turns at the top make it a guess far short of a session of
  /// long ones. So a jump that the guess held short of [at], or that went to
  /// a bottom not yet known to be the real one, is made again once those rows
  /// are built, until it lands or the end stops moving.
  void _land(double? at, {double? lastEnd, int tries = 20}) {
    final landing = _chat.pickedFrom;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        // Another session picked meanwhile lands for itself.
        if (!mounted || _chat.pickedFrom != landing) return;
        if (_scroll.hasClients) {
          final position = _scroll.position;
          final end = position.maxScrollExtent;
          final to = (at ?? end).clamp(position.minScrollExtent, end);
          _scroll.jumpTo(to);
          if (to != at && end != lastEnd && tries > 0) {
            return _land(at, lastEnd: end, tries: tries - 1);
          }
        }
        _switching = false;
      })
      // The frame to look again after: a jump to where the list already is
      // asks for none.
      ..ensureVisualUpdate();
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

  /// Picks [agent] up in this chat, where it was left, and, on a narrow
  /// screen, gets the drawer out of the way of what it brought.
  Future<void> _pick(ClaudeAgent agent) async {
    _scaffoldKey.currentState?.closeDrawer();
    final at = _leftAt[_placeOf(agent.sessionId)];
    _switching = true;
    await _chat.continueFrom(agent);
    if (!mounted) return;
    _drawn = _below;
    _land(at);
  }

  /// Reads the turns before the first one showing, which go in above it.
  Future<void> _loadEarlier() async {
    try {
      await _chat.loadEarlier();
    } catch (error) {
      if (mounted) {
        showToast(
          context,
          'Earlier turns could not be read\n$error',
          type: ToastificationType.error,
        );
      }
    }
  }

  /// Leaves what this chat shows for a new one, which the next message
  /// starts on the host. What it showed carries on there, and stays listed.
  Future<void> _newChat() async {
    _scaffoldKey.currentState?.closeDrawer();
    await _chat.newChat();
    if (mounted) setState(() {});
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    final starts = _chat.composing;
    final sent = _chat.send(text);
    _input.clear();
    // Whatever was said, the reader wants to be at the bottom again.
    _drawn = -1;
    _followTranscript();
    // A session this chat started is not in a list read before it was.
    if (starts) {
      unawaited(
        sent.then((_) {
          if (mounted && _chat.pickedFrom != null) setState(_listAgents);
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= _wide;
      final sidebar = wide && _sidebarOpen;
      final sessions = _SessionList(
        chat: _chat,
        agents: _agents,
        connected: widget.session.isConnected,
        onPick: _pick,
        onRefresh: () => setState(_listAgents),
        onNewChat: _newChat,
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
              : CustomScrollView(
                  // A list of its own for each session picked. The rows a
                  // lazy list has built keep where they were laid out, and
                  // another session's rows, of other heights, drawn into
                  // them put what a session was left at somewhere else.
                  key: ValueKey(chat.pickedFrom),
                  controller: _scroll,
                  center: _opened,
                  slivers: [
                    // Above [_opened], slivers grow upwards: the nearest to it
                    // is the list of earlier turns, newest of them first, and
                    // over them what says there are more.
                    if (chat.hasEarlier)
                      SliverToBoxAdapter(
                        child: _Earlier(chat: chat, onLoad: _loadEarlier),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      sliver: SliverList.builder(
                        itemCount: chat.earlier,
                        itemBuilder: (context, index) =>
                            _entry(entries[chat.earlier - 1 - index]),
                      ),
                    ),
                    SliverPadding(
                      key: _opened,
                      padding: EdgeInsets.fromLTRB(
                        12,
                        chat.hasEarlier || chat.earlier > 0 ? 0 : 12,
                        12,
                        4,
                      ),
                      sliver: SliverList.builder(
                        itemCount: entries.length - chat.earlier,
                        itemBuilder: (context, index) =>
                            _entry(entries[chat.earlier + index]),
                      ),
                    ),
                  ],
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
              Text(
                chat.composing
                    ? 'Starting a new session on the host…'
                    : 'Claude is working…',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        const Divider(height: 1),
        _composer(theme, wide: wide, sidebar: sidebar),
      ],
    );
  }

  Widget _entry(ChatEntry entry) => switch (entry) {
    ChatSaid(mine: true) => _Bubble(said: entry),
    ChatSaid(:final text) => _Answer(text: text, onTapLink: _openLink),
    final ChatToolRun run => _ToolRow(run: run),
    final ChatNotice notice => _Notice(notice: notice),
  };

  /// A link tapped in what Claude said. A reply quotes whatever Claude read —
  /// a file, a web page, a tool's output — so it is somebody else's text, and
  /// what it may open is [openUrl]'s to decide, as for the terminal and the
  /// Markdown preview, which show text just as untrusted: a web page, a mail
  /// or a call, and never `javascript:`, `file:`, `intent:` or this app's own
  /// `sshbox:`. A chat once kept a stricter rule of its own, web links only,
  /// but all that shut out beyond [openUrl]'s is a mail or a call, each of
  /// which stops at a composer or a dialer for the user to send, and the one
  /// thing a link in a reply could leak by is its address, which a web link
  /// carries as well as any. Two rules would only be two lists to keep.
  ///
  /// A path, which Claude writes for the files it touched, is on the host
  /// rather than here, so its address is copied: the label hides it, and
  /// copying the label gives only the label.
  void _openLink(String text, String? href, String title) {
    final url = Uri.tryParse(href ?? '');
    if (url != null && url.hasScheme) {
      unawaited(openUrl(context, url, inTab: widget.onOpenWeb));
      return;
    }
    final address = href ?? text;
    unawaited(Clipboard.setData(ClipboardData(text: address)));
    showToast(context, 'Not opened: $address is on the host. Copied it');
  }

  Widget _composer(
    ThemeData theme, {
    required bool wide,
    required bool sidebar,
  }) {
    final chat = _chat;
    final watching = chat.watching;
    final connected = widget.session.isConnected;
    // Before there is a conversation, what is sent starts one.
    final composing = chat.composing && connected;
    // Running at a terminal in no tmux pane this app can type into: shown
    // here, typed there.
    final readOnly = watching != null && chat.readOnly != null;
    // Into a session being watched, what is typed goes to that session and
    // queues behind whatever it is doing; to this chat's own Claude, only
    // between its turns.
    final open = !readOnly && (watching != null || chat.ready || composing);
    final canSend =
        open && (watching != null || ((chat.ready || composing) && !chat.busy));
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
                } else if (choice == 'new') {
                  unawaited(_newChat());
                } else {
                  unawaited(chat.restart());
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'new',
                  enabled: connected,
                  child: const Text('New chat'),
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
                enabled: open,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: readOnly
                      ? 'Read-only: “${watching.name}” cannot be typed into '
                            'from here'
                      : watching != null
                      ? 'Message “${watching.name}”…'
                      : composing
                      ? 'Start a new chat…'
                      : chat.ready
                      ? 'Ask Claude…'
                      : connected
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
            const SizedBox(height: 6),
            Text(
              'What you send starts a new session there, listed with the '
              'others, which carries on when this app is closed.',
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

/// Over the earliest turn showing, when the transcript on the host goes back
/// further: a button that reads more of it, or, once a chat has read all it
/// may of one transcript, that the rest is on the host.
class _Earlier extends StatelessWidget {
  const _Earlier({required this.chat, required this.onLoad});

  final ClaudeChat chat;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Center(
        child: chat.loadingEarlier
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : chat.canLoadEarlier
            ? TextButton.icon(
                onPressed: onLoad,
                icon: const Icon(Icons.history),
                label: const Text('Load earlier turns'),
              )
            : Text(
                'Earlier turns are on the host: a chat reads at most '
                '${ClaudeChat.transcriptBudget ~/ (1024 * 1024)} MB of one '
                'session.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
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
  const _Answer({required this.text, required this.onTapLink});

  final String text;

  /// Without it the package draws a link and does nothing when it is tapped.
  final MarkdownTapLinkCallback onTapLink;

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
            onTapLink: onTapLink,
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
    'Edit' || 'MultiEdit' || 'Write' => Icons.edit_outlined,
    'Grep' || 'Glob' => Icons.search,
    'WebFetch' || 'WebSearch' => Icons.public,
    'Task' => Icons.group_outlined,
    'TodoWrite' => Icons.checklist,
    _ => Icons.build_outlined,
  };

  /// A result that came back as a JSON string, quotes and escapes and all,
  /// as the text it holds; anything else as it came.
  static String _unquoted(String result) {
    final text = result.trim();
    if (text.length < 2 || !text.startsWith('"') || !text.endsWith('"')) {
      return result;
    }
    try {
      final value = jsonDecode(text);
      if (value is String) return value;
    } catch (_) {
      // Only looked like one.
    }
    return result;
  }

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
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
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
                // Built only once the row is opened: colouring code is work.
                // Under a storage key of its own, as every block is: a
                // SelectableText scrolls, and without one it would read the
                // tile's bool as its offset.
                if (run.input.isNotEmpty)
                  _ToolInput(
                    key: const PageStorageKey('input'),
                    run: run,
                    mono: mono,
                  ),
                if (result != null && result.isNotEmpty)
                  _block(
                    context,
                    'result',
                    SelectableText(
                      _unquoted(result),
                      style: mono.copyWith(
                        color: run.failed ? scheme.error : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A slab of text that never grows past a screenful — a tool's answer, or a
/// file it wrote, can be hundreds of lines, and the transcript has to stay
/// readable.
///
/// [slot] names the block's own place in page storage, and has to differ
/// from every other block in its row. Without it the scroll view's offset
/// was stored under the tile's PageStorageKey, where the ExpansionTile keeps
/// its open-or-shut bool, so an opened row read a bool as a double and threw
/// — which a release build draws as nothing, the "expanded and empty" the
/// user saw.
Widget _block(BuildContext context, String slot, Widget text) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(top: 8),
  padding: const EdgeInsets.all(8),
  constraints: const BoxConstraints(maxHeight: 240),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(6),
  ),
  child: SingleChildScrollView(key: PageStorageKey(slot), child: text),
);

/// What a tool was given, drawn the way the VS Code plugin draws it rather
/// than as the JSON it came in: a command as a command, a file written as
/// the file, an edit as the lines it took out and put in. Whatever a tool's
/// drawing does not take — a field it does not know, or one of a shape it
/// did not expect — is listed after it as `name: value`, strings as they
/// read, so nothing Claude passed is ever left out.
///
/// Every value came from the host, through Claude, so it is drawn and never
/// run or opened.
class _ToolInput extends StatelessWidget {
  const _ToolInput({super.key, required this.run, required this.mono});

  final ChatToolRun run;
  final TextStyle mono;

  /// Colouring past this much is left undone: a file this big is read in
  /// the editor, not in a 240-pixel box.
  ///
  /// ponytail: coloured on every build of an opened row. Keep the span in a
  /// State if a busy session with a big Write open ever stutters.
  static const _colourLimit = 16 * 1024;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final rest = Map<String, dynamic>.of(run.input);

    /// The field [key] when it is text worth drawing, taken from what is
    /// left to list.
    String? take(String key) {
      final value = rest[key];
      if (value is! String || value.isEmpty) return null;
      rest.remove(key);
      return value;
    }

    Widget caption(String text, {bool path = false}) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SelectableText(
        text,
        style: (path ? mono : theme.textTheme.bodySmall!).copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );

    Widget code(String slot, String text, {String path = ''}) => _block(
      context,
      slot,
      SelectableText.rich(
        (text.length <= _colourLimit
                ? highlightCode(path, text, mono, brightness)
                : null) ??
            TextSpan(text: text, style: mono),
      ),
    );

    final parts = <Widget>[];
    switch (run.name) {
      case 'Bash':
        if (take('description') case final description?) {
          parts.add(caption(description));
        }
        if (take('command') case final command?) {
          parts.add(code('command', command, path: 'command.sh'));
        }
      case 'Write':
        final path = take('file_path');
        if (path != null) parts.add(caption(path, path: true));
        if (take('content') case final content?) {
          parts.add(code('content', content, path: path ?? ''));
        }
      case 'Edit' || 'MultiEdit':
        if (take('file_path') case final path?) {
          parts.add(caption(path, path: true));
        }
        final edits = run.name == 'Edit' ? [rest] : rest['edits'];
        final pairs = [
          if (edits is List)
            for (final edit in edits)
              if (edit case {
                'old_string': final String old,
                'new_string': final String put,
              })
                (old, put),
        ];
        if (edits is List && pairs.isNotEmpty && pairs.length == edits.length) {
          rest
            ..remove('old_string')
            ..remove('new_string');
          if (run.name == 'MultiEdit') rest.remove('edits');
          parts.add(_block(context, 'diff', _diff(pairs, brightness)));
        }
      case 'Read':
        final path = take('file_path');
        final offset = rest['offset'];
        final limit = rest['limit'];
        final from = offset is int ? offset : 1;
        final range = limit is int
            ? 'lines $from–${from + limit - 1}'
            : offset is int
            ? 'from line $from'
            : null;
        if (range != null) {
          rest
            ..remove('offset')
            ..remove('limit');
        }
        if (path != null || range != null) {
          parts.add(caption([?path, ?range].join(' · '), path: true));
        }
      case 'Grep' || 'Glob':
        if (take('pattern') case final pattern?) {
          parts.add(code('pattern', pattern));
        }
      case 'TodoWrite':
        final todos = rest['todos'];
        final items = [
          if (todos is List)
            for (final todo in todos)
              if (todo case {'content': final String content})
                (content, todo['status']),
        ];
        if (todos is List && items.isNotEmpty && items.length == todos.length) {
          rest.remove('todos');
          parts.add(_checklist(context, items));
        }
    }
    if (rest.isNotEmpty) parts.add(code('fields', _fields(rest)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: parts,
    );
  }

  /// Each edit as the lines it took out, in the editor's red for a diff, and
  /// the lines it put in, in its green.
  Widget _diff(List<(String, String)> pairs, Brightness brightness) {
    final styles = codeColoursFor(brightness);
    final out = mono.copyWith(color: styles['deletion']?.color);
    final put = mono.copyWith(color: styles['addition']?.color);
    final spans = <TextSpan>[];
    for (final (index, (old, now)) in pairs.indexed) {
      if (index > 0) spans.add(TextSpan(text: '\n', style: mono));
      for (final line in const LineSplitter().convert(old)) {
        spans.add(TextSpan(text: '- $line\n', style: out));
      }
      for (final line in const LineSplitter().convert(now)) {
        spans.add(TextSpan(text: '+ $line\n', style: put));
      }
    }
    return SelectableText.rich(TextSpan(children: spans, style: mono));
  }

  /// A to-do list as a checklist: done, under way, or still to do.
  Widget _checklist(BuildContext context, List<(String, Object?)> items) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (content, status) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (status) {
                      'completed' => Icons.check_box,
                      'in_progress' => Icons.indeterminate_check_box_outlined,
                      _ => Icons.check_box_outline_blank,
                    },
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      content,
                      style: theme.textTheme.bodySmall?.copyWith(
                        decoration: status == 'completed'
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// `name: value` a line, text as it reads — its newlines real, not `\n` —
  /// and anything else as JSON.
  static String _fields(Map<String, dynamic> fields) => [
    for (final MapEntry(:key, :value) in fields.entries)
      switch (value) {
        final String text when text.contains('\n') => '$key:\n$text',
        final String text => '$key: $text',
        _ => '$key: ${const JsonEncoder.withIndent('  ').convert(value)}',
      },
  ].join('\n');
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
/// chat: the sidebar on a wide screen, the drawer on a narrow one. Pinned
/// ones first, then the ones running, then the finished ones, each under a
/// heading of its own.
///
/// ponytail: every finished session is listed, 80 on a working machine,
/// in a lazy list below the running ones. Cap it, or page it, if a host's
/// runs to thousands.
///
/// Every row is data from the host — a name is whatever the person who
/// started it typed — so it is drawn and never run.
class _SessionList extends StatelessWidget {
  const _SessionList({
    required this.chat,
    required this.agents,
    required this.connected,
    required this.onPick,
    required this.onRefresh,
    required this.onNewChat,
  });

  final ClaudeChat chat;

  /// As the page last asked for them; null before the session first came
  /// up.
  final Future<List<ClaudeAgent>>? agents;

  /// Whether the session is up: the list is asked for over its connection.
  final bool connected;
  final ValueChanged<ClaudeAgent> onPick;
  final VoidCallback onRefresh;
  final VoidCallback onNewChat;

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
    final agents = this.agents;
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
                tooltip: 'New chat',
                onPressed: connected ? onNewChat : null,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: connected ? onRefresh : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'One still running is watched live, and what you send goes into '
            'it; one open in a terminal is only watched. A finished one is '
            'continued where it stopped.',
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
                        'No Claude sessions on this host yet.',
                      );
                    }
                    // Already in this order; the headings go where each
                    // part starts.
                    final pinned = rows.where((row) => row.pinned);
                    final running = rows.where(
                      (row) => !row.pinned && row.live,
                    );
                    final finished = rows.where(
                      (row) => !row.pinned && !row.live,
                    );
                    final items = <Object>[
                      if (pinned.isNotEmpty) ...['Pinned', ...pinned],
                      if (running.isNotEmpty) ...['Running', ...running],
                      if (finished.isNotEmpty) ...[
                        'Finished (${finished.length})',
                        ...finished,
                      ],
                    ];
                    return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) => switch (items[index]) {
                        final ClaudeAgent agent => _row(context, agent),
                        final Object heading => _heading(context, '$heading'),
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) =>
      TuiHeading(text, padding: const EdgeInsets.fromLTRB(16, 12, 16, 4));

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
      selected: agent.sessionId == chat.pickedFrom,
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
      onTap: () => onPick(agent),
    );
  }
}
