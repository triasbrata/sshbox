import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../chat/claude_chat.dart';
import '../chat/picture_draft.dart';
import '../files/transfers.dart';
import '../platform.dart';
import '../session/session_manager.dart';
import '../session/terminal_session.dart' show uploadName;
import 'code_languages.dart';
import 'file_editor_page.dart'
    show
        CodeBlockBuilder,
        copyAndSay,
        pictureMaxPixels,
        pictureSize,
        showPicture;
import 'markdown_input.dart';
import 'mermaid_view.dart';
import 'settings_page.dart' show chatEnterSends, terminalSettings;
import 'slash_command_menu.dart';
import 'text_size.dart';
import 'terminal_page.dart' show openUrl;
import 'terminal_paste.dart'
    show clipboardImage, insertedImage, pasteImageLimit;
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

  /// The pictures the message being written carries: a card each above the
  /// box, and an `[Image #N]` each in its text.
  final _draft = PictureDraft();

  /// Where each picture added is copied, under a name of its own: the
  /// clipboard's and the keyboard's copies are emptied at the next paste,
  /// and two pictures of one name would be one file on the host. Gone with
  /// the page; a bubble whose copy has gone shows that it has.
  Directory? _picturesDir;

  /// True while files are dragged over the page on a desktop.
  bool _dropping = false;
  final _scroll = ScrollController();
  late final _inputFocus = FocusNode(onKeyEvent: _onBoxKey);

  /// Whether the box may send now, as it was last drawn.
  bool _canSend = false;

  bool get _sendable =>
      _canSend && (_input.text.trim().isNotEmpty || !_draft.isEmpty);

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

  /// True while the list runs the view back into range after the layout left
  /// it past its end; see [_onScrollUpdate].
  bool _runBack = false;

  /// What the list says it did. Upward is the reader's unless the layout did
  /// it: a keyboard going away or a window growing leaves the view past its
  /// new end and the list runs back to it, upward and with no reader in it.
  /// That run starts out of range; anything upward that starts in range is
  /// the reader's, PageUp and the arrows included, which scroll by animateTo
  /// or jumpTo. Under bouncing physics an overscroll at the bottom is the end
  /// anyway. Our own pinning to the end is [_pinning], and a landing on a
  /// place is [_switching]'s.
  bool _onScrollUpdate(ScrollNotification note) {
    // The conversation's own list only: a tool row's block scrolls inside it,
    // and a reader moving that is not moving the conversation.
    if (note.depth != 0) return false;
    if (note is ScrollEndNotification) _runBack = false;
    if (note is! ScrollUpdateNotification ||
        _switching ||
        !_scroll.hasClients) {
      return false;
    }
    final metrics = note.metrics;
    // Where the move started: the layout's run-back starts out of range, the
    // viewport having grown under a view left at its old end, and the
    // reader's move up starts in range. A run-back, once seen to start out of
    // range, is one until it ends, its last steps being in range.
    final delta = note.scrollDelta ?? 0;
    if (metrics.pixels - delta > metrics.maxScrollExtent + 0.5) {
      _runBack = true;
    }
    final byReader = delta < 0 && !_pinning && !_runBack;
    final follow = byReader
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
    try {
      _picturesDir?.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
    super.dispose();
  }

  /// The kinds of picture Claude's API reads.
  static final _pictureNames = RegExp(
    r'\.(png|jpe?g|gif|webp)$',
    caseSensitive: false,
  );

  /// Adds [file] to the message being written, at the caret: a picture
  /// Claude can read, no bigger than a paste into the terminal may be.
  /// Anything else is refused, saying why.
  Future<void> _addPicture(({String path, String name}) file) async {
    final why = _readOnlyWhy;
    if (why != null) {
      return _refuse('Not added: this session is read-only from here — $why');
    }
    if (!_pictureNames.hasMatch(file.name)) {
      return _refuse(
        'Not a picture Claude can read: ${file.name}. A PNG, '
        'JPEG, GIF or WebP is.',
      );
    }
    final source = File(file.path);
    final File copy;
    try {
      if (await source.length() > pasteImageLimit) {
        return _refuse(
          '${file.name} is bigger than '
          '${pasteImageLimit ~/ (1024 * 1024)} MB, the most a picture may '
          'be.',
        );
      }
      final dir = _picturesDir ??= Directory.systemTemp.createTempSync(
        'chat-pictures',
      );
      copy = await source.copy(
        '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-'
        '${uploadName(file.name)}',
      );
    } on FileSystemException catch (error) {
      return _refuse('${file.name} could not be read: ${error.message}');
    }
    if (!mounted) return;
    setState(() {
      _input.value = _draft.add(
        _input.value,
        ChatPicture(path: copy.path, name: file.name),
        _chat.nextPicture,
      );
    });
  }

  /// The box's selection menu, its Paste taking a picture first — the only
  /// paste a touch screen with no keyboard has. Offered even when the
  /// clipboard holds no text, which is when the field's own leaves it out:
  /// a picture alone is exactly that.
  Widget _contextMenu(BuildContext context, EditableTextState editable) {
    final paste = ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      onPressed: () {
        editable.hideToolbar();
        unawaited(
          _pastePicture().then((took) {
            if (!took) editable.pasteText(SelectionChangedCause.toolbar);
          }),
        );
      },
    );
    final items = [...editable.contextMenuButtonItems];
    final at = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.paste,
    );
    if (at >= 0) {
      items[at] = paste;
    } else if (_attachable) {
      items.add(paste);
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// A picture refused is one the user has to do something about, so it
  /// stays the 5 s such refusals get, as the slash command refusal does.
  void _refuse(String why) {
    if (mounted) {
      showToast(
        context,
        why,
        type: TuiToastType.warning,
        duration: const Duration(seconds: 5),
      );
    }
  }

  /// A paste into the box: a picture on the clipboard becomes a card, and
  /// anything else is pasted as text, as it always was. True when the
  /// clipboard held a picture, taken or not.
  Future<bool> _pastePicture() async {
    try {
      final image = await clipboardImage();
      if (image == null) return false;
      await _addPicture(image);
    } on PlatformException catch (error) {
      _refuse(
        error.message ??
            'The picture on the clipboard could not be '
                'taken.',
      );
    }
    return true;
  }

  /// A picture Gboard's clipboard strip put in.
  Future<void> _inserted(KeyboardInsertedContent content) async {
    try {
      final image = await insertedImage(content);
      if (image == null) {
        return _refuse('Only a picture can go into a chat this way.');
      }
      await _addPicture(image);
    } on PlatformException catch (error) {
      _refuse(error.message ?? 'That picture could not be taken.');
    }
  }

  Future<void> _pickPictures() async {
    for (final file in await FilePicker.pickFiles(type: FileType.image)) {
      // Something picked from a cloud provider has no path to read.
      final path = file.path;
      if (path == null) {
        _refuse('${file.name} is not on this device to send.');
        continue;
      }
      await _addPicture((path: path, name: file.name));
    }
  }

  /// Files dropped from the OS file manager on a desktop, in order.
  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _dropping = false);
    for (final item in details.files) {
      if (FileSystemEntity.isDirectorySync(item.path)) {
        _refuse('A folder is not a picture: ${item.name}');
        continue;
      }
      await _addPicture((path: item.path, name: item.name));
      if (!mounted) return;
    }
  }

  /// Puts [picture] on the host for a session there, through the upload the
  /// terminal's paste uses: in the Transfers tab, made 0600 and named by
  /// [uploadName] — here after the copy's own name, which is unique — or
  /// copied on this machine for a Local shell.
  Future<String> _upload(ChatPicture picture) => transfers.run(
    name: picture.name,
    host: widget.session.host.displayName,
    direction: TransferDirection.upload,
    work: (transfer) => widget.session.uploadToTmp(
      localPath: picture.path!,
      fileName: picture.path!,
      onProgress: transfer.report,
      cancel: transfer.cancelled,
    ),
  );

  /// Why nothing can be sent to this chat, or null: only a session that is
  /// read-only from here. A picture is taken whenever that is null, ready
  /// yet or not — the box may be up before Claude is, and a picture pasted
  /// then is a card, sent when Send turns on. Only Send is gated.
  String? get _readOnlyWhy => _chat.watching != null ? _chat.readOnly : null;

  bool get _attachable => _readOnlyWhy == null;

  /// On a desktop, files dropped on the chat: see [_dropped]. Only while this
  /// tab is the one showing and nothing covers it, as the terminal's.
  Widget _dropTarget(Widget child) {
    if (!isDesktop) return child;
    final enable =
        _attachable &&
        Visibility.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final theme = Theme.of(context);
    return DropTarget(
      enable: enable,
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: _dropped,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_dropping && enable)
            IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('drop-highlight'),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
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

  /// To the end once what changed is laid out. Hidden, the tab's tickers are
  /// off and an animation would stand still, so it goes at once, and is at the
  /// end when shown.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_follow) return;
      final position = _scroll.position;
      final end = position.maxScrollExtent;
      if (end - position.pixels <= _atEnd) return;
      if (!TickerMode.valuesOf(context).enabled) return _scroll.jumpTo(end);
      _pinning = true;
      // A run begun over this one ends it, and its late end is not this
      // run's to act on.
      final run = ++_pinRun;
      unawaited(
        _scroll
            .animateTo(
              end,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            )
            .whenComplete(() {
              if (run != _pinRun) return;
              _pinning = false;
              // What grew meanwhile, or came back from a reader's hand, is
              // not for this to chase: only an idle list is pinned again.
              if (mounted &&
                  _follow &&
                  _scroll.hasClients &&
                  _scroll.position.userScrollDirection ==
                      ScrollDirection.idle) {
                _scrollToEnd();
              }
            }),
      );
    });
  }

  /// True while the view runs to the end, which is not to be started again
  /// by each frame of its own run.
  bool _pinning = false;
  int _pinRun = 0;

  /// The end slips below the fold with no new entry whenever the room or the
  /// content changes size — the keyboard, a shorter window, the working line
  /// appearing, a row growing in place — so while following, the end is kept
  /// in view for those too.
  bool _onScrollMetrics(ScrollMetricsNotification note) {
    if (note.depth != 0) return false;
    final metrics = note.metrics;
    if (_follow &&
        !_switching &&
        !_pinning &&
        metrics.maxScrollExtent - metrics.pixels > _atEnd) {
      _scrollToEnd();
    }
    return false;
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
    // Numbered as Claude will number them, now that it is going.
    final text = _draft.sync(_input.value, _chat.nextPicture).text;
    if (text.trim().isEmpty && _draft.isEmpty) return;
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
    final sent = _chat.send(
      text,
      pictures: _draft.pictures,
      upload: widget.session.canUploadFiles ? _upload : null,
    );
    _draft.clear();
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
      // A right-click on the sessions is theirs, and a session has no menu:
      // claimed here, it never falls through to the tab's own menu, whose
      // Group with… a session is no tab to answer.
      final sessions = GestureDetector(
        onSecondaryTapUp: (_) {},
        child: ContentText(
          child: _SessionList(
            chat: _chat,
            agents: _agents,
            connected: widget.session.isConnected,
            onPick: _pick,
            onRefresh: () => setState(_listAgents),
            onNewChat: _newChat,
            unseen: (agent) => _unseen.contains(_placeOf(agent.sessionId)),
          ),
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
              child: _dropTarget(
                ContentText(
                  child: _conversation(wide: wide, sidebar: sidebar),
                ),
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
              : NotificationListener<ScrollMetricsNotification>(
                  onNotification: _onScrollMetrics,
                  child: NotificationListener<ScrollNotification>(
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
        // Under the working line, and alone between turns while a task is
        // still open, as Claude Code's own view keeps it.
        if (chat.openTasks.isNotEmpty) _Checklist(chat: chat),
        // How much of the context window the session uses, with the plan's
        // quota in a popup: hover on a desktop, a tap on touch.
        if (chat.context != null) _UsageChip(chat: chat),
        const Divider(height: 1),
        if (!_draft.isEmpty) _pictureCards(),
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

  /// A card for each picture the message being written carries, above the
  /// box.
  Widget _pictureCards() => SizedBox(
    height: 138,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
      children: [
        for (final picture in _draft.pictures)
          _PictureCard(
            picture: picture,
            onRemove: () => setState(() {
              _input.value = _draft.remove(
                _input.value,
                picture,
                _chat.nextPicture,
              );
            }),
          ),
      ],
    ),
  );

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
      ..panel = palette.selection
      // Its pictures' tokens drawn as chips.
      ..pictures = {for (final picture in _draft.pictures) picture.number};
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
              IconButton(
                tooltip: 'Add a picture',
                onPressed: readOnly ? null : _pickPictures,
                icon: const Icon(Icons.add_photo_alternate_outlined),
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
                // A picture pasted goes in as a card rather than as nothing:
                // see [_pastePicture]. The field's own menu Paste is offered
                // only for text, and takes text — so it is replaced by one
                // that takes a picture first, offered with a picture alone.
                // Enter and the slash menu stay [_onBoxKey]'s: only a paste is
                // taken here.
                child: Actions(
                  actions: {PasteTextIntent: _PictureOrText(_pastePicture)},
                  child: TextField(
                    contextMenuBuilder: _contextMenu,
                    contentInsertionConfiguration:
                        ContentInsertionConfiguration(
                          allowedMimeTypes: const [
                            'image/png',
                            'image/jpeg',
                            'image/gif',
                            'image/webp',
                          ],
                          onContentInserted: (content) =>
                              unawaited(_inserted(content)),
                        ),
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
                    // Shut only for a session that cannot be typed into at
                    // all. A box shut for a moment between turns drops keys
                    // and loses the focus, so what is typed then went
                    // nowhere; the text waits instead, and [open] gates only
                    // Send.
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
                    // A token deleted takes its card with it.
                    onChanged: (_) => setState(() {
                      final synced = _draft.sync(
                        _input.value,
                        _chat.nextPicture,
                      );
                      if (synced != _input.value) _input.value = synced;
                    }),
                  ),
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

/// Paste in the box: [take] first, which takes a picture from the clipboard,
/// and the field's own text paste only when there was none.
class _PictureOrText extends Action<PasteTextIntent> {
  _PictureOrText(this.take);

  final Future<bool> Function() take;

  @override
  Object? invoke(PasteTextIntent intent) {
    final text = callingAction;
    unawaited(
      take().then((took) {
        if (!took) text?.invoke(intent);
      }),
    );
    return null;
  }
}

/// What a picture is drawn from: the copy sent from here, or the bytes the
/// transcript holds.
ImageProvider _pictureImage(ChatPicture picture) => picture.path != null
    ? FileImage(File(picture.path!))
    : MemoryImage(picture.bytes!);

/// A picture's small copy, which a tap opens large.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.picture, this.width = 112, this.height = 84});

  final ChatPicture picture;
  final double width;
  final double height;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late final ImageProvider _image = _pictureImage(widget.picture);

  /// Whether it may be drawn: its size read from its header first, since a
  /// PNG or GIF is decoded whole before it is scaled down, and a transcript's
  /// picture can claim a size that whole would not fit in memory. Null while
  /// that is being read.
  bool? _drawable;

  @override
  void initState() {
    super.initState();
    pictureSize(_image).then(
      (size) {
        if (mounted) {
          setState(
            () => _drawable = size.width * size.height <= pictureMaxPixels,
          );
        }
      },
      onError: (Object _) {
        if (mounted) setState(() => _drawable = false);
      },
    );
  }

  String get _label => widget.picture.name.isNotEmpty
      ? widget.picture.name
      : '[Image #${widget.picture.number}]';

  @override
  Widget build(BuildContext context) {
    final palette = TermulThemeData.of(context).palette;
    final width = widget.width;
    final height = widget.height;
    final unshown = SizedBox(
      width: width,
      height: height,
      child: _drawable == false
          ? Icon(Icons.broken_image_outlined, color: palette.dim)
          : null,
    );
    return Semantics(
      container: true,
      button: true,
      label: 'View $_label',
      child: GestureDetector(
        // The whole of it, drawn yet or not.
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(showPicture(context, _image, _label)),
        child: _drawable != true
            ? unshown
            : Image(
                // Decoded small: a thumbnail of a 20 MB photo need not hold
                // it all.
                image: ResizeImage(_image, width: (width * 2).round()),
                width: width,
                height: height,
                fit: BoxFit.cover,
                errorBuilder: (context, _, _) => SizedBox(
                  width: width,
                  height: height,
                  child: Icon(Icons.broken_image_outlined, color: palette.dim),
                ),
              ),
      ),
    );
  }
}

/// A picture going with the message being written: its thumbnail, which a
/// tap opens, its token and name, and a button to take it out.
///
/// TODO(termul): termul has no attachment card; this is its panel, border
/// and mono caption around a thumbnail.
class _PictureCard extends StatelessWidget {
  const _PictureCard({required this.picture, required this.onRemove});

  final ChatPicture picture;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = TermulThemeData.of(context).palette;
    return Container(
      width: 114,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              _Thumbnail(picture: picture),
              Positioned(
                top: 0,
                right: 0,
                child: Material(
                  color: palette.panel.withValues(alpha: 0.85),
                  child: IconButton(
                    tooltip: 'Remove ${picture.name}',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onRemove,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Text(
              '[Image #${picture.number}] ${picture.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: palette.dim,
              ),
            ),
          ),
        ],
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

  /// termul's bubble, with its note while it is not in the session yet, and
  /// over it the pictures it carries.
  @override
  Widget build(BuildContext context) {
    final bubble = _bubble(context);
    if (said.pictures.isEmpty) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 48),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final picture in said.pictures)
                _Thumbnail(picture: picture, width: 160, height: 120),
            ],
          ),
        ),
        bubble,
      ],
    );
  }

  Widget _bubble(BuildContext context) => TuiChatBubble(
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
  'code': CodeBlockBuilder(copyable: true, wrap: true),
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

/// The session's tasks, as Claude Code's view draws them under its spinner:
/// `⎿` then the ones in progress, bold with a filled square, and the ones
/// pending with an empty one; completed ones are only counted, in a last
/// `… +N pending, M completed` line. Task text is host text: plain [Text].
class _Checklist extends StatelessWidget {
  const _Checklist({required this.chat});

  final ClaudeChat chat;

  /// How many tasks it lists before it counts the rest.
  static const _lines = 6;

  @override
  Widget build(BuildContext context) {
    final open = chat.openTasks;
    final done = chat.tasksDone;
    // The ones in progress first, then the pending, shown in task order.
    final shown = {
      ...[...open.where((t) => t.inProgress), ...open.where((t) => !t.inProgress)]
          .take(_lines),
    };
    // Counted for what they are: more than the lines hold of the ones in
    // progress is possible too.
    final hidden = open.where((t) => !shown.contains(t));
    final hiddenActive = hidden.where((t) => t.inProgress).length;
    final hiddenPending = hidden.length - hiddenActive;
    final more = [
      if (hiddenActive > 0) '+$hiddenActive in progress',
      if (hiddenPending > 0) '+$hiddenPending pending',
      if (done > 0) '$done completed',
    ];
    Widget line(String text, {bool bold = false, TuiTextTone? tone}) => Row(
      children: [
        const SizedBox(width: 16),
        Expanded(
          child: TuiText(
            text,
            size: 12,
            bold: bold,
            tone: tone ?? TuiTextTone.normal,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, task) in open.where(shown.contains).indexed)
            line(
              '${i == 0 ? '⎿ ' : '  '}${task.inProgress ? '■' : '□'} '
              '${task.label}',
              bold: task.inProgress,
              tone: task.inProgress ? null : TuiTextTone.muted,
            ),
          if (more.isNotEmpty)
            line('  … ${more.join(', ')}', tone: TuiTextTone.dim),
        ],
      ),
    );
  }
}

// TODO(termul): a rich anchored popover — hover, tap to pin, tap outside to
// close — holding any widgets; TuiTooltip takes a String only, so this builds
// its own from OverlayPortal and TuiBox. Asked of termul in sshbox#195.
/// "Context 45%" at the box's edge, in the warning colour from 80%, and the
/// popup it opens: context used out of the window with a bar and the model, the
/// plan's usage with each reset, and when it was read. Hover opens it, a tap
/// pins it open, and a tap anywhere else closes it. Everything the host said is
/// drawn as plain text.
class _UsageChip extends StatefulWidget {
  const _UsageChip({required this.chat});

  final ClaudeChat chat;

  @override
  State<_UsageChip> createState() => _UsageChipState();
}

class _UsageChipState extends State<_UsageChip> {
  final _link = LayerLink();
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _working = widget.chat.progress != null;
    widget.chat.addListener(_onChat);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChat);
    super.dispose();
  }

  /// A turn ended: what it used of the plan has moved, and Claude Code is
  /// asked once, as often as the minute allows — and only while the tab shows,
  /// so a chat in the background spawns nothing.
  void _onChat() {
    final working = widget.chat.progress != null;
    final ended = _working && !working;
    _working = working;
    if (ended && mounted && TickerMode.valuesOf(context).enabled) {
      unawaited(widget.chat.refreshQuota());
    }
  }

  final _portal = OverlayPortalController();
  bool _hover = false;
  bool _pinned = false;

  bool get _shown => _hover || _pinned;

  void _sync() {
    if (_shown) {
      if (!_portal.isShowing) _portal.show();
      // The first look at it asks for the plan's usage, if a minute has
      // passed since anyone did.
      unawaited(widget.chat.refreshQuota());
    } else if (_portal.isShowing) {
      _portal.hide();
    }
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// A moment in the device's own time: `Oct 2, 15:59`, or just `15:59` today.
  static String _local(DateTime at, DateTime now) {
    final local = at.toLocal();
    final time = '${_two(local.hour)}:${_two(local.minute)}';
    final today =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return today ? time : '${_months[local.month - 1]} ${local.day}, $time';
  }

  static String _count(int tokens) => ChatProgress.count(tokens);

  @override
  Widget build(BuildContext context) {
    final context_ = widget.chat.context!;
    final percent = (context_.fraction * 100).round();
    final warn = context_.fraction >= 0.8;
    final label = 'Context $percent%';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (_) => CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              child: Align(
                alignment: Alignment.bottomRight,
                child: _UsagePopup(
                  chat: widget.chat,
                  local: _local,
                  count: _count,
                ),
              ),
            ),
            child: TapRegion(
              onTapOutside: (_) {
                if (_pinned) {
                  _pinned = false;
                  _sync();
                }
              },
              child: MouseRegion(
                onEnter: (_) {
                  _hover = true;
                  _sync();
                },
                onExit: (_) {
                  _hover = false;
                  _sync();
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _pinned = !_pinned;
                    _sync();
                  },
                  child: Semantics(
                    container: true,
                    button: true,
                    label: '$label used. Usage details',
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: TuiText(
                        label,
                        size: 11,
                        tone: warn ? TuiTextTone.yellow : TuiTextTone.dim,
                        bold: warn,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UsagePopup extends StatelessWidget {
  const _UsagePopup({
    required this.chat,
    required this.local,
    required this.count,
  });

  final ClaudeChat chat;
  final String Function(DateTime, DateTime) local;
  final String Function(int) count;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: chat,
    builder: (context, _) {
      final used = chat.context;
      final quota = chat.quota;
      final now = chatNow();
      Widget bar(double fraction) => Padding(
        padding: const EdgeInsets.only(top: 3, bottom: 6),
        child: TuiProgressBar(
          value: fraction.clamp(0.0, 1.0),
          height: 4,
          tone: fraction >= 0.8
              ? TuiProgressTone.danger
              : TuiProgressTone.accent,
        ),
      );
      Widget row(
        String text, {
        TuiTextTone tone = TuiTextTone.normal,
        bool bold = false,
      }) => TuiText(
        text,
        size: 11,
        tone: tone,
        bold: bold,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
      final age = quota == null ? null : now.difference(quota.asOf);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: TuiBox(
          expanded: false,
          title: 'Usage',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (used != null) ...[
                row(
                  'Context  ${count(used.tokens)} / ${count(used.window)} '
                  '(${(used.fraction * 100).round()}%)',
                  bold: used.fraction >= 0.8,
                ),
                bar(used.fraction),
                if (used.model != null) row(used.model!, tone: TuiTextTone.dim),
                const SizedBox(height: 6),
              ],
              if (quota != null)
                for (final window in quota.windows) ...[
                  row('${window.label}  ${window.percent.round()}% used'),
                  bar(window.percent / 100),
                  if (window.resetsAt != null)
                    row(
                      'resets ${local(window.resetsAt!, now)}',
                      tone: TuiTextTone.dim,
                    )
                  else if (window.resetsText != null)
                    row('resets ${window.resetsText}', tone: TuiTextTone.dim),
                ]
              else
                row(
                  chat.quotaNotReported
                      ? "Claude Code didn't report plan usage."
                      : 'Reading plan usage…',
                  tone: TuiTextTone.dim,
                ),
              if (quota != null) ...[
                const SizedBox(height: 4),
                row(
                  'as of ${local(quota.asOf, now)}'
                  '${age! >= ClaudeChat.quotaEvery * 2 ? ' · ${age.inMinutes} min ago' : ''}',
                  tone: TuiTextTone.dim,
                ),
              ],
            ],
          ),
        ),
      );
    },
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
