import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../chat/claude_chat.dart';
import '../platform.dart';
import '../session/session_manager.dart';
import 'code_languages.dart';
import 'file_editor_page.dart' show CodeBlockBuilder, copyAndSay;
import 'markdown_input.dart';
import 'mermaid_view.dart';
import 'settings_page.dart' show chatEnterSends, terminalSettings;
import 'slash_command_menu.dart';
import 'text_size.dart';
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
  /// Draws what is typed as Markdown; its colours are set from the theme
  /// each time the box is built.
  final _input = MarkdownEditingController(
    mono: '',
    dim: Colors.grey,
    accent: Colors.blue,
    panel: Colors.black12,
  );
  final _scroll = ScrollController();
  late final _inputFocus = FocusNode(onKeyEvent: _onBoxKey);

  /// Whether the box may send now, as it was last drawn.
  bool _canSend = false;

  bool get _sendable => _canSend && _input.text.trim().isNotEmpty;

  /// True while a menu over the box — a list of slash commands — is open:
  /// the box then leaves its keys to the menu, which sits above it in the
  /// focus chain and hears what the box ignores.
  final _menuOpen = ValueNotifier(false);

  /// Whether the tabs showed this chat when it last looked; null until its
  /// first look.
  bool? _shown;

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

  /// Sessions, by host and session id, seen working since last opened here,
  /// and those that have finished since: the dot on their row. Kept for as
  /// long as the app runs, as [_leftAt] is, and never written anywhere.
  static final _sawWorking = <String>{};
  static final _unseen = <String>{};

  /// What the list says of [agent] now, against what it said before.
  void _note(ClaudeAgent agent) {
    final place = _placeOf(agent.sessionId)!;
    final status = _SessionList.statusOf(agent);
    if (status == TuiChatSessionStatus.working ||
        status == TuiChatSessionStatus.waiting) {
      _sawWorking.add(place);
    } else if (_sawWorking.remove(place) &&
        agent.sessionId != _chat.pickedFrom) {
      // Finished while the user was elsewhere.
      _unseen.add(place);
    }
  }

  // A block, not an arrow: an arrow would hand setState the future. Its
  // error is the list's to show, and it may not be showing yet.
  void _listAgents() {
    final agents = _chat.agents(all: true);
    _agents = agents..ignore();
    _asking = true;
    unawaited(
      agents.whenComplete(() => _asking = false).then((rows) {
        if (!mounted) return;
        rows.forEach(_note);
        setState(() {});
      }, onError: (Object _) {}),
    );
  }

  /// Asks for the list again every [_look] while it is on screen — the
  /// sidebar open, or the drawer — and the tab is showing, so each row's
  /// mark follows what its session is doing. Nothing is asked otherwise.
  static const _look = Duration(seconds: 5);
  Timer? _looking;

  /// A list asked for and not back yet: no second one goes after it.
  bool _asking = false;
  /// Whether the last layout had the sidebar beside the chat, not a drawer.
  bool _sidebarWide = false;

  void _onLook() {
    if (!mounted || !widget.session.isConnected) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    final shown = _sidebarWide
        ? _sidebarOpen
        : _scaffoldKey.currentState?.isDrawerOpen ?? false;
    if (shown && !_asking) setState(_listAgents);
  }

  /// The slash commands the host's Claude Code takes, read the first time
  /// the list opens on a connection, and again by its ↻. What came back, or
  /// why not, is kept for [_send] and the list: see [SlashCommandMenu].
  AsyncSnapshot<List<SlashCommand>> _commands = const AsyncSnapshot.nothing();

  void _wantCommands() {
    if (_commands.connectionState == ConnectionState.none) {
      setState(_listCommands);
    }
  }

  void _listCommands() {
    _commands = const AsyncSnapshot.waiting();
    final asked = _chat.slashCommands();
    unawaited(
      asked
          .then(
            (commands) =>
                AsyncSnapshot.withData(ConnectionState.done, commands),
            onError: (Object error) =>
                AsyncSnapshot<List<SlashCommand>>.withError(
                  ConnectionState.done,
                  error,
                ),
          )
          .then((snapshot) {
            if (mounted) setState(() => _commands = snapshot);
          }),
    );
  }

  /// Nearer the end than this, the view is at its end: left at the bottom, and
  /// following. Anything further up is a place somebody scrolled to, kept
  /// however small.
  static const _atEnd = 2.0;

  /// Whether new output keeps the view at the latest reply. On while the view
  /// is at its end, reached by hand or by the jump button; off the moment the
  /// reader scrolls up, even a pixel and even mid-stream, and then the view
  /// stays where it is, whatever arrives, until they are back at the end.
  bool _follow = true;

  /// Entries that arrived below the view while it was not following, for the
  /// jump button to say.
  int _arrived = 0;

  /// What the list says it did. Upward is the reader's: Claude's output only
  /// ever moves the view down, and a landing on a place is [_switching]'s.
  bool _onScrollUpdate(ScrollUpdateNotification note) {
    if (_switching) return false;
    final metrics = note.metrics;
    final follow = (note.scrollDelta ?? 0) < 0
        ? false
        : metrics.maxScrollExtent - metrics.pixels <= _atEnd || _follow;
    if (follow != _follow) {
      setState(() {
        _follow = follow;
        if (follow) _arrived = 0;
      });
    }
    return false;
  }

  /// To the latest reply, following it from there on.
  void _jumpToEnd() {
    setState(() {
      _follow = true;
      _arrived = 0;
    });
    _scrollToEnd();
  }

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
    _looking = Timer.periodic(_look, (_) => _onLook());
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _onChanged();
  }

  @override
  void dispose() {
    _looking?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    widget.session.removeListener(_onChanged);
    _chat.removeListener(_onChanged);
    _input.dispose();
    _inputFocus.dispose();
    _menuOpen.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // On a desktop, a chat put on screen is typed into: the box takes the
    // focus. Not on a touch screen, where focus would raise the soft keyboard
    // by itself; there a hardware key is what moves it, below.
    final shown = Visibility.of(context);
    if (isDesktop && shown && _shown != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Visibility.of(context)) _inputFocus.requestFocus();
      });
    }
    _shown = shown;
  }

  /// Enter in the box: ⌘+Enter on Apple's keyboards, Ctrl+Enter on the
  /// rest, sends; a plain Enter is a new line, or sends where Settings says
  /// Enter sends, Shift+Enter then being the new line. An IME's Enter, which
  /// confirms what it is composing, is the IME's.
  KeyEventResult _onBoxKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        _input.value.isComposingRangeValid) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final chord = switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.iOS => keys.isMetaPressed,
      _ => keys.isControlPressed,
    };
    // An open menu takes every other Enter, to pick; the chord still sends.
    if (_menuOpen.value && !chord) return KeyEventResult.ignored;
    if (chord ||
        (chatEnterSends.value &&
            !keys.isShiftPressed &&
            !keys.isControlPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed)) {
      if (_sendable) _send();
      return KeyEventResult.handled;
    }
    if (chatEnterSends.value && keys.isShiftPressed) {
      // Typed here rather than left to the platform, which, with Enter as
      // the box's send action, need not make it a new line.
      _type('\n');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// [text] typed into the box over its selection, or at its end.
  void _type(String text) {
    final value = _input.value;
    final at = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _input.value = TextEditingValue(
      text: value.text.replaceRange(at.start, at.end, text),
      selection: TextSelection.collapsed(offset: at.start + text.length),
    );
    setState(() {});
  }

  /// Typing in a chat whose box does not have the focus types into the box,
  /// as Discord does: a hardware key is heard here before the focus chain,
  /// focused or not, as the terminal's pane hears one.
  ///
  /// The key that moves the focus is typed into the box here and kept from
  /// going on: the box had no text input connection when the platform read
  /// it, so where that key's character would land is each platform's own
  /// affair — dropped on one, typed once the connection opens on another.
  /// Taken here, it lands once on every one.
  ///
  /// Only a key that types something, with no Ctrl, ⌘ or Alt — so shortcuts,
  /// Ctrl+C on a selection among them, and Tab, arrows, Escape, Enter and the
  /// F-keys go where they were going — and only while this chat is on screen,
  /// the page on top, and no text field anywhere has the focus.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent || _inputFocus.hasFocus || _shown != true) {
      return false;
    }
    final character = event.character;
    if (character == null ||
        character.isEmpty ||
        character.codeUnits.any((u) => u < 0x20 || u == 0x7f)) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    // A drawer open over the chat, its own sessions or a page's around it,
    // is no route but is where the user is.
    for (final scaffold in [
      _scaffoldKey.currentState,
      Scaffold.maybeOf(context),
    ]) {
      if (scaffold != null &&
          (scaffold.isDrawerOpen || scaffold.isEndDrawerOpen)) {
        return false;
      }
    }
    // Space on a focused button or row has already pressed it.
    final primary = FocusManager.instance.primaryFocus;
    if (character == ' ' && primary != null && primary is! FocusScopeNode) {
      return false;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    _inputFocus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    // A box shut, or in a group's pane not focused, cannot take it.
    if (!_inputFocus.hasFocus) return false;
    _type(character);
    return true;
  }

  void _onChanged() {
    if (!mounted) return;
    final connected = widget.session.isConnected;
    if (connected && !_wasConnected) {
      _wasConnected = true;
      _listAgents();
      _commands = const AsyncSnapshot.nothing();
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

  /// Keeps the newest entry in view while following; otherwise leaves the view
  /// exactly where the reader put it, and counts what came in below it.
  void _followTranscript() {
    final entries = _below;
    final before = _drawn;
    if (entries == before) return;
    _drawn = entries;
    if (_switching) return;
    if (!_scroll.hasClients) {
      // Not laid out yet, so there is no end to be at: whether it follows is
      // where it first lands. A list opened on a long transcript lands at its
      // top, and holds there for whatever puts it somewhere; only one that
      // fits, or sits at its end, follows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _switching || !_scroll.hasClients) return;
        final position = _scroll.position;
        final atEnd = position.maxScrollExtent - position.pixels <= _atEnd;
        if (atEnd != _follow) setState(() => _follow = atEnd);
        if (atEnd) _scrollToEnd();
      });
      return;
    }
    if (!_follow) {
      if (before >= 0 && entries > before) _arrived += entries - before;
      return;
    }
    _scrollToEnd();
  }

  /// To the end once the entry just added is laid out. Hidden, the tab's
  /// tickers are off and an animation would stand still, so it goes at once,
  /// and is at the end when shown.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_follow) return;
      final end = _scroll.position.maxScrollExtent;
      if (!TickerMode.valuesOf(context).enabled) return _scroll.jumpTo(end);
      unawaited(
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
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
        // Left at its end it follows; left anywhere above, it holds.
        if (_scroll.hasClients) {
          final position = _scroll.position;
          final atEnd = position.maxScrollExtent - position.pixels <= _atEnd;
          if (atEnd != _follow || (atEnd && _arrived != 0)) {
            setState(() {
              _follow = atEnd;
              _arrived = 0;
            });
          }
        }
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
  static const _wideFrom = 840.0;

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
    _sawWorking.remove(_placeOf(agent.sessionId));
    setState(() => _unseen.remove(_placeOf(agent.sessionId)));
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
          type: TuiToastType.error,
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
    // A dialog in a terminal chat cannot see takes the next Enter as a
    // choice, so a command that may open one is not typed at all.
    if (SlashCommand.refusal(text, _commands.data) case final why?) {
      showToast(
        context,
        why,
        type: TuiToastType.warning,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    final starts = _chat.composing;
    final sent = _chat.send(text);
    _input.clear();
    // Whatever was said, the reader wants to be at the bottom again.
    _follow = true;
    _arrived = 0;
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
      final wide = box.maxWidth >= _wideFrom;
      _sidebarWide = wide;
      final sidebar = wide && _sidebarOpen;
      // Chat at the content size, its sessions, messages, tool rows, code
      // and composer alike: see ContentText.
      final sessions = ContentText(
        child: _SessionList(
          chat: _chat,
          agents: _agents,
          connected: widget.session.isConnected,
          onPick: _pick,
          onRefresh: () => setState(_listAgents),
          onNewChat: _newChat,
          unseen: (agent) => _unseen.contains(_placeOf(agent.sessionId)),
        ),
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
            Expanded(
              child: ContentText(
                child: _conversation(wide: wide, sidebar: sidebar),
              ),
            ),
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
          child: Stack(
            children: [
              Positioned.fill(
                child: entries.isEmpty
                    ? _Empty(
                  session: widget.session,
                  // Beside a sidebar already showing them, a button to show
                  // them would do nothing.
                  onPickSession: sidebar ? null : () => _showSessions(wide),
                )
              : NotificationListener<ScrollUpdateNotification>(
                  onNotification: _onScrollUpdate,
                  child: CustomScrollView(
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
              ),
              // Over the list's own corner, so it covers neither the working
              // line nor the box, which sit below the list.
              if (!_follow && entries.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 8,
                  child: _JumpToLatest(
                    arrived: _arrived,
                    onPressed: _jumpToEnd,
                  ),
                ),
            ],
          ),
        ),
        if (chat.progress case final progress?)
          _Progress(chat: chat, progress: progress)
        else if (chat.busy)
          Row(
            children: [
              const SizedBox(width: 16),
              SizedBox(width: 12, height: 12, child: TuiSpinner()),
              const SizedBox(width: 8),
              Text(
                // Between Claude's last message and its result, in a chat of
                // its own.
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
    ChatSaid(mine: true) => _Bubble(said: entry, onTapLink: _openLink),
    ChatSaid(:final text) => _Answer(text: text, onTapLink: _openLink),
    final ChatToolRun run => _ToolRow(run: run),
    final ChatNotice notice => _Notice(notice: notice),
    final ChatCommand command => _CommandRow(command: command),
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
    _canSend = canSend;
    final palette = TermulThemeData.of(context).palette;
    _input
      ..mono = terminalSettings.value.fontFamily
      ..dim = palette.dim
      ..accent = palette.accent
      // The selection colour: the field itself is drawn on the panel.
      ..panel = palette.selection;
    // The list of commands goes above the whole row, as wide as the page:
    // the box alone is too narrow for it on a phone.
    return SafeArea(
      top: false,
      child: SlashCommandMenu(
        controller: _input,
        commands: _commands,
        onOpen: _wantCommands,
        openState: _menuOpen,
        onRefresh: () => setState(_listCommands),
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
            MenuButton<Object>(
              tooltip: 'Chat settings',
              onSelected: (choice) {
                if (choice is ChatPermission) {
                  unawaited(chat.restart(permission: choice));
                } else if (choice == 'new') {
                  unawaited(_newChat());
                } else {
                  unawaited(chat.restart());
                }
              },
              entries: [
                TuiMenuItem(
                  value: 'new',
                  label: 'New chat',
                  enabled: connected,
                ),
                const TuiMenuDivider(),
                for (final mode in ChatPermission.values)
                  TuiMenuItem(
                    value: mode,
                    label: mode.label,
                    checked: chat.permission == mode,
                  ),
                const TuiMenuDivider(),
                const TuiMenuItem(value: 'restart', label: 'Restart Claude'),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                // Gboard's own Enter sends too when Enter is what sends.
                textInputAction: chatEnterSends.value
                    ? TextInputAction.send
                    : null,
                onSubmitted: (_) {
                  // Not while the list of commands is open: a half-typed
                  // /com is a pick still being made.
                  if (_sendable && !_menuOpen.value) _send();
                },
                // Shut only for a session that cannot be typed into at all. A
                // box shut for a moment between turns drops keys and loses
                // the focus, so what is typed then went nowhere; the text
                // waits instead, and [open] gates only Send.
                enabled: !readOnly,
                minLines: 1,
                // Room for a short code block before it scrolls.
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                // termul's TuiInput look — its ❯ prompt in the accent — on
                // a field that takes several lines and can be shut, which
                // TuiInput does not.
                decoration: InputDecoration(
                  isDense: true,
                  // One line, cut: at a large text size on a phone a hint
                  // that wraps grows the box past the room the keyboard
                  // leaves.
                  hintMaxLines: 1,
                  prefixText: '❯ ',
                  prefixStyle: TextStyle(
                    fontFamily: TermulFonts.mono,
                    color: TermulThemeData.of(context).palette.accent,
                  ),
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
              // The app's iconButtonTheme gives every IconButton an accent
              // foreground, which beats the filled variant's own onPrimary:
              // an accent arrow on an accent fill. Black or white, whichever
              // reads on the fill.
              style: IconButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor:
                    tuiContrast(Colors.black, palette.accent) >=
                        tuiContrast(Colors.white, palette.accent)
                    ? Colors.black
                    : Colors.white,
              ),
              onPressed: _sendable ? _send : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
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
    // Scrolls when a phone's keyboard leaves it less height than it needs.
    return Center(
      child: SingleChildScrollView(
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
              // Shrunk rather than cut where a phone is too narrow for it.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: TuiButton(
                  label: 'Sessions on this host',
                  prefix: '▸',
                  variant: TuiButtonVariant.ghost,
                  onPressed: show,
                ),
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
            ? const SizedBox(width: 20, height: 20, child: TuiSpinner())
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

/// What the user said: their own bubble, on their own side, drawn as the
/// Markdown it was typed in — and, for a message typed into a session being
/// watched, where it has got to, until that session has recorded it.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.said, required this.onTapLink});

  final ChatSaid said;
  final MarkdownTapLinkCallback onTapLink;

  /// termul's bubble, with its note while it is not in the session yet.
  @override
  Widget build(BuildContext context) => TuiChatBubble(
    text: said.text,
    delivery: switch (said.delivery) {
      Delivery.sending => TuiChatDelivery.sending,
      Delivery.queued => TuiChatDelivery.queued,
      Delivery.failed => TuiChatDelivery.failed,
      null => null,
    },
    failureReason: said.why,
    child: SelectionArea(
      child: _ChatMarkdown(
        text: said.text,
        onTapLink: onTapLink,
        ink: TuiChatBubble.bubbleTextStyle(context),
      ),
    ),
  );
}

/// The builders every Markdown in a chat draws with, what was asked and
/// what was answered alike: a ```mermaid fence as a diagram, its source
/// copyable beside it, and any other code block with its copy button.
final chatMarkdownBuilders = <String, MarkdownElementBuilder>{
  'code': CodeBlockBuilder(copyable: true),
};

/// What Claude said, as Markdown: it writes lists, headings and code.
class _Answer extends StatelessWidget {
  const _Answer({required this.text, required this.onTapLink});

  final String text;
  final MarkdownTapLinkCallback onTapLink;

  // termul's answer, holding the Markdown renderer the preview uses.
  @override
  Widget build(BuildContext context) => TuiChatAnswer(
    child: SelectionArea(
      child: _ChatMarkdown(text: text, onTapLink: onTapLink),
    ),
  );
}

/// The one Markdown setup a chat draws with, what was asked and what was
/// answered alike: the renderer the Markdown preview uses, its code blocks
/// with their copy buttons, and every link through the same [onTapLink].
class _ChatMarkdown extends StatelessWidget {
  const _ChatMarkdown({required this.text, required this.onTapLink, this.ink});

  final String text;

  /// Without it the package draws a link and does nothing when it is tapped.
  final MarkdownTapLinkCallback onTapLink;

  /// The text's own style on a bubble's accent, where the theme's colours
  /// would not show; null on the page's own ground.
  final TextStyle? ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = this.ink;
    final body = ink ?? theme.textTheme.bodyMedium!;
    final link = ink?.color ?? scheme.primary;
    // On the accent, code sits on a shade of the text's own colour.
    final panel =
        ink?.color?.withValues(alpha: 0.14) ?? scheme.surfaceContainerHighest;
    TextStyle? heading(double size) =>
        ink?.copyWith(fontSize: size, fontWeight: FontWeight.bold);
    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, terminal, _) => MarkdownBody(
        // A ```mermaid fence is a diagram, as in the Markdown preview,
        // once it has closed.
        data: holdOpenMermaid(text),
        onTapLink: onTapLink,
        builders: chatMarkdownBuilders,
        // A message is text, and any picture in it lives on a server we do
        // not fetch from: its alt text says what was meant.
        imageBuilder: (uri, title, alt) =>
            Text(alt == null || alt.isEmpty ? '$uri' : alt),
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: body,
          h1: heading(20),
          h2: heading(18),
          h3: heading(16),
          listBullet: ink,
          blockquote: ink,
          a: TextStyle(
            color: link,
            decoration: TextDecoration.underline,
            decorationColor: link,
            fontWeight: ink == null ? null : FontWeight.bold,
          ),
          code: body.copyWith(
            fontFamily: terminal.fontFamily,
            fontFamilyFallback: terminal.fontFamilyFallback,
            fontSize: body.fontSize! * 0.9,
            backgroundColor: panel,
          ),
          codeblockDecoration: BoxDecoration(
            color: panel,
            border: Border.all(
              color:
                  ink?.color?.withValues(alpha: 0.3) ?? scheme.outlineVariant,
            ),
          ),
          blockquoteDecoration: ink == null
              ? null
              : BoxDecoration(
                  border: Border(left: BorderSide(color: ink.color!, width: 3)),
                ),
        ),
      ),
    );
  }
}

/// One tool Claude reached for, drawn as termul's [TuiToolRow] draws one:
/// its glyph, its name and the one line it is about, which opens to what it
/// was given and what came back. termul's row takes plain text; what a tool
/// was given is drawn here the way the tool reads, so the row is termul's
/// look around Jeansh's own body.
class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.run});

  final ChatToolRun run;

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
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  /// Open or shut, kept in page storage by the run's id, so a row scrolled
  /// off and built again comes back as it was left.
  late bool _open =
      PageStorage.maybeOf(context)?.readState(context, identifier: _slot)
          as bool? ??
      false;

  String get _slot => 'tool-open-${widget.run.id}';

  void _toggle() {
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)?.writeState(context, _open, identifier: _slot);
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final run = widget.run;
    final result = run.result;
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, terminal, _) {
        final mono = theme.textTheme.bodySmall!.copyWith(
          fontFamily: terminal.fontFamily,
          fontFamilyFallback: terminal.fontFamilyFallback,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.surface,
              border: Border.all(color: p.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: _toggle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: run.done
                              ? Text(
                                  tuiToolGlyph(run.name),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: TermulFonts.mono,
                                    fontSize: 13,
                                    color: run.failed ? p.red : p.accent,
                                  ),
                                )
                              : const Center(child: TuiSpinner(size: 14)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          run.name,
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            run.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: 11,
                              color: p.dim,
                            ),
                          ),
                        ),
                        Text(
                          _open ? '▾' : '▸',
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: 12,
                            color: p.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Built only once the row is opened: colouring code is work.
                // Under a storage key of its own, as every block is: a
                // SelectableText scrolls, and without one it would read the
                // row's bool as its offset.
                if (_open)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (run.input.isNotEmpty) ...[
                          _label(p, 'input'),
                          _ToolInput(
                            key: const PageStorageKey('input'),
                            run: run,
                            mono: mono,
                          ),
                        ],
                        if (result != null && result.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _label(p, 'result'),
                          _block(
                            context,
                            'result',
                            SelectableText(
                              _ToolRow._unquoted(result),
                              style: mono.copyWith(
                                color: run.failed ? p.red : null,
                              ),
                            ),
                            copy: _ToolRow._unquoted(result),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// termul's word over a block.
  Widget _label(TermulPalette p, String text) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontFamily: TermulFonts.mono,
      fontSize: 10,
      letterSpacing: 0.6,
      color: p.dim,
    ),
  );
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
///
/// [copy] is the block's plain text, which its Copy code button puts on the
/// clipboard. The button sits beside the text, as CodeBlockBuilder's does, so
/// it never covers the first line or takes the drag that scrolls the block.
Widget _block(
  BuildContext context,
  String slot,
  Widget text, {
  required String copy,
}) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(top: 4),
  padding: const EdgeInsets.all(8),
  constraints: const BoxConstraints(maxHeight: 240),
  decoration: BoxDecoration(
    color: TermulThemeData.of(context).palette.panel,
    border: Border.all(color: TermulThemeData.of(context).palette.border),
  ),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SingleChildScrollView(key: PageStorageKey(slot), child: text),
      ),
      IconButton(
        tooltip: 'Copy code',
        onPressed: () => copyAndSay(
          context,
          'code block',
          () => Clipboard.setData(ClipboardData(text: copy)),
        ),
        icon: const Icon(Icons.content_copy, size: 18),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      ),
    ],
  ),
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
      copy: text,
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
          parts.add(
            _block(
              context,
              'diff',
              _diff(pairs, brightness),
              copy: _diffText(pairs),
            ),
          );
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

  /// [_diff]'s text as shown, for the clipboard.
  static String _diffText(List<(String, String)> pairs) => [
    for (final (index, (old, now)) in pairs.indexed) ...[
      if (index > 0) '',
      for (final line in const LineSplitter().convert(old)) '- $line',
      for (final line in const LineSplitter().convert(now)) '+ $line',
    ],
  ].join('\n');

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

/// A slash command run in the session: the command as a chip on the user's
/// side, and under it, when it ran in the CLI, what it printed, in the
/// terminal's font as it printed it.
class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command});

  final ChatCommand command;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final output = command.output;
    final typed = '/${command.name} ${command.args}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TuiBadge(label: typed, tone: TuiTextTone.accent),
          if (output != null && output.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: p.surface,
                border: Border.all(color: p.border),
              ),
              child: SelectableText(
                output,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 12,
                  color: p.text,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
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

/// The button over the conversation's corner that goes to the latest reply,
/// with how many entries came in below the view since it left the end.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.arrived, required this.onPressed});

  final int arrived;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: arrived > 0
        ? 'Jump to latest, $arrived new'
        : 'Jump to latest',
    excludeSemantics: true,
    child: TuiButton(
      label: arrived > 0 ? 'Latest · $arrived new' : 'Latest',
      prefix: '↓',
      variant: TuiButtonVariant.ghost,
      onPressed: onPressed,
    ),
  );
}

/// The line under the chat while a turn runs, shaped on Claude Code's own:
/// `⠋ Working… (33s · ↓ 1.4k tokens) · Bash: npm test` — or, when the session
/// waits at its terminal, what for and where to answer it, with no spinner.
///
/// The seconds tick here, once a second, with no round trip; the host is
/// asked what the session is doing every [_look] while a watched turn is
/// open. Both stop while the tab is hidden, the tab strip turning a hidden
/// page's [TickerMode] off.
class _Progress extends StatefulWidget {
  const _Progress({required this.chat, required this.progress});

  final ClaudeChat chat;
  final ChatProgress progress;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  static const _look = Duration(seconds: 5);

  late final Timer _tick;
  DateTime? _looked;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // First look at once: a session picked up at a prompt says so now.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTick());
  }

  void _onTick() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return;
    final now = chatNow();
    final looked = _looked;
    if (looked == null || now.difference(looked) >= _look) {
      _looked = now;
      unawaited(widget.chat.checkState());
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final p = widget.progress;
    final waiting = p.waitingFor;
    final String text;
    if (waiting != null) {
      final agent = widget.chat.watching;
      text = agent == null || agent.interactive
          ? 'Waiting for $waiting at its terminal. Answer it there.'
          : 'Waiting for $waiting on the host. Open it in a terminal with '
                '`claude attach ${agent.id ?? ''}` to answer it.';
    } else {
      final time = ChatProgress.elapsed(chatNow().difference(p.started));
      final tokens = p.tokens > 0
          ? ' · ↓ ${ChatProgress.count(p.tokens)} tokens'
          : '';
      final tool = p.tool;
      final doing = tool == null
          ? ''
          : ' · ${tool.name}${tool.summary.isEmpty ? '' : ': ${tool.summary}'}';
      text = 'Working… ($time$tokens)$doing';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: waiting == null
                ? const TuiSpinner(size: 12)
                : Icon(Icons.pause, size: 12, color: style?.color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: waiting == null ? 1 : 3,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
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
    required this.unseen,
  });

  final ClaudeChat chat;

  /// Whether [agent] finished since it was last opened here.
  final bool Function(ClaudeAgent agent) unseen;

  /// What [agent]'s mark says, from the listing alone: a `waitingFor` is the
  /// session asking the user something — `permission prompt`, measured —
  /// `working` or `busy` its turn, and a session whose process has gone is
  /// finished, or `stopped` when the CLI says so.
  static TuiChatSessionStatus statusOf(ClaudeAgent agent) {
    if (!agent.live) {
      return agent.state == 'stopped'
          ? TuiChatSessionStatus.stopped
          : TuiChatSessionStatus.done;
    }
    if (agent.waitingFor != null || agent.status == 'waiting') {
      return TuiChatSessionStatus.waiting;
    }
    if (agent.busy || agent.state == 'working') {
      return TuiChatSessionStatus.working;
    }
    return TuiChatSessionStatus.done;
  }

  static String _statusLabel(ClaudeAgent agent) =>
      switch (statusOf(agent)) {
        TuiChatSessionStatus.working => 'Working',
        TuiChatSessionStatus.waiting =>
          'Waiting for ${agent.waitingFor ?? 'you'}',
        TuiChatSessionStatus.done => agent.live ? 'Done, idle' : 'Finished',
        TuiChatSessionStatus.stopped => 'Stopped',
      };

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

  static const _hint =
      'One still running is watched live, and what you send goes into it; '
      'one open in a terminal is only watched. A finished one is continued '
      'where it stopped.';

  /// termul's session rail: Pinned, Running and Finished, a mark for each.
  Widget _list({
    List<ClaudeAgent> rows = const [],
    bool loading = false,
    String? error,
    String empty = 'No Claude sessions on this host yet.',
  }) => TuiChatSessionList(
    title: 'Sessions on this host',
    hint: _hint,
    width: null,
    loading: loading,
    errorMessage: error,
    emptyMessage: empty,
    onNewChat: connected ? onNewChat : null,
    onRefresh: connected ? onRefresh : null,
    onSelect: (session) => onPick(rows[int.parse(session.id)]),
    sessions: [
      for (final (i, agent) in rows.indexed)
        TuiChatSession(
          id: '$i',
          title: agent.name,
          subtitle: _where(agent),
          // The one this chat was picked up from, so which is showing is
          // never a guess.
          selected: agent.sessionId == chat.pickedFrom,
          // Pinned in `claude agents` on the host, and so first here too.
          kind: agent.pinned
              ? TuiChatSessionKind.pinned
              : agent.live
              ? TuiChatSessionKind.running
              : TuiChatSessionKind.finished,
          status: statusOf(agent),
          statusLabel: _statusLabel(agent),
          unseen: unseen(agent),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final agents = this.agents;
    if (agents == null) {
      return _list(empty: 'Connect this session to see its Claude sessions.');
    }
    return FutureBuilder<List<ClaudeAgent>>(
      future: agents,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Asked again while on show: the rows it had stay meanwhile,
          // rather than flashing loading every few seconds.
          final had = snapshot.data;
          return had == null ? _list(loading: true) : _list(rows: had);
        }
        // What the host said, as it said it: an old Claude with no agents
        // command, or none installed at all.
        final error = snapshot.error;
        if (error != null) return _list(error: '$error');
        // Already in this order.
        return _list(rows: snapshot.data ?? const <ClaudeAgent>[]);
      },
    );
  }

  /// Where [agent] is and how long it has been going.
  static String _where(ClaudeAgent agent) => [
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
}
