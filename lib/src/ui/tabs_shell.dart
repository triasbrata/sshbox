import 'dart:async';

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../files/transfers.dart';
import '../session/isolate_transport.dart';
import '../session/pane_record.dart';
import '../session/port_forwards.dart';
import '../session/session_manager.dart';
import '../session/tmux.dart';
import 'chat_page.dart';
import 'connect_sheet.dart';
import 'db_browser_page.dart';
import 'db_editor_page.dart' show DbBadge;
import 'file_editor_page.dart';
import 'git_diff_page.dart';
import 'git_page.dart';
import 'hosts_page.dart';
import 'pane_record_page.dart';
import 'tab_groups.dart';
import 'terminal_page.dart';
import 'toast.dart';
import 'transfers_page.dart';
import 'web_page.dart';

/// One tab, named by what it shows rather than by an index — indices shift
/// every time a tab opens or closes. [path] is set for a file tab, where it is
/// the file's path, and for a diff tab, where it is the diff's key; [web] only
/// for a web tab.
typedef TabRef = ({
  LiveSession session,
  TabKind kind,
  String? path,
  WebTab? web,
});

/// The app's one screen: a pinned host list on the left, then a tab per open
/// session, and beside each session a tab for every file opened from its
/// files drawer and every web page opened from a link in it. After them all,
/// a tab for every database opened from the host list.
///
/// Tabs are a view of [SessionManager] rather than a list of their own —
/// which tab exists, in what order, and which one is showing all come from
/// there, so a notification tap and a tap in the host list still land the same
/// way without this widget knowing about either.
///
/// The pages sit in an [IndexedStack] so switching tabs keeps each terminal's
/// key bar and scroll position, and each file its scroll position, exactly as
/// they were left.
///
/// Tabs can be grouped, and a group shows every page it holds at once, each
/// in a pane: see [TabGroups]. The groups are this widget's, not
/// [SessionManager]'s: a group is only how the tabs are laid out.
class TabsShell extends StatefulWidget {
  const TabsShell({
    super.key,
    required this.repository,
    required this.secrets,
    required this.sessions,
    required this.onOpenHost,
    this.onDuplicate,
    this.onOpenLocal,
    this.onOpenWsl,
    this.openDatabase,
  });

  final HostRepository repository;
  final SecretStore secrets;
  final SessionManager sessions;

  /// A tap on a host's card, or on its row in Logs: see `openHost`.
  final Future<void> Function(String hostId) onOpenHost;

  /// Duplicate session, on a shell tab's long press: another shell on the
  /// host every time, where [onOpenHost] first connects a tab brought back
  /// from an earlier run — which Duplicate, asked on that very tab, would
  /// otherwise connect in place of the copy. [onOpenHost] when not given.
  final Future<void> Function(String hostId)? onDuplicate;

  /// Opens a shell on this machine, on the builds that can have one — see
  /// `LocalTransport`. Null elsewhere, and Home draws no card for it.
  final Future<void> Function()? onOpenLocal;

  /// Opens a shell in a WSL distro, on the Windows build alone: see
  /// `wslDistros`. Null elsewhere.
  final Future<void> Function(String distro)? onOpenWsl;

  /// What a database's tab connects with: [DbSession.open], unless a test
  /// brings a stand-in.
  final DbOpener? openDatabase;

  @override
  State<TabsShell> createState() => _TabsShellState();
}

class _TabsShellState extends State<TabsShell> {
  final _groups = TabGroups();

  @override
  void initState() {
    super.initState();
    widget.sessions.addListener(_onSessionsChanged);
    _groups.addListener(_onSessionsChanged);
    transfers.addListener(_onTransfers);
    // A port forward has no page of its own on screen to ask about a host
    // key from, or to speak through, and this shell always is.
    portForwards
      ..confirmHostKey = ((check) => confirmHostKey(context, check))
      ..onNotice = _showForwardNotice;
    // Any connection in the app — a session, a port forward, a database
    // tunnel — saying it came up at a host's alternative address.
    IsolateTransport.onNotice = _showNotice;
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_onSessionsChanged);
    _groups.dispose();
    transfers.removeListener(_onTransfers);
    portForwards
      ..confirmHostKey = null
      ..onNotice = null;
    IsolateTransport.onNotice = null;
    super.dispose();
  }

  /// A remark from a connection, with no page of its own to make it on.
  void _showNotice(String message) {
    if (!mounted) return;
    // Two lines to take in as a session comes up, so a little longer than a
    // remark's second.
    showToast(context, message, duration: const Duration(seconds: 4));
  }

  void _showForwardNotice(ForwardNotice notice) {
    if (!mounted) return;
    final link = notice.link;
    showToast(
      context,
      notice.message,
      type: notice.failed ? ToastificationType.error : ToastificationType.info,
      // Time to read a reason, or to reach for Open.
      duration: Duration(seconds: notice.failed || link != null ? 8 : 3),
      action: link == null
          ? null
          : (label: 'Open', onPressed: () => openUrl(context, link)),
    );
  }

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  /// The newest transfer already seen, so each new one brings the Transfers
  /// tab back once, and closing it until the next one sticks.
  int? _newestTransfer = transfers.items.firstOrNull?.id;

  /// A transfer starting puts the Transfers tab at the end of the strip,
  /// where a browser's downloads button sits, without showing it: the page
  /// it was started from stays in front, and nothing covers the tabs, as a
  /// toast offering to open it would before it went again.
  void _onTransfers() {
    final newest = transfers.items.firstOrNull?.id;
    if (newest == null || newest == _newestTransfer) return;
    _newestTransfer = newest;
    widget.sessions.showTransfers();
  }

  /// Left to right: each session's shell, then the files and the web pages
  /// opened from it. A file tab sits next to its session because it is that
  /// session it is read over, a web tab because it was that session's link —
  /// closing the shell takes them with it.
  List<TabRef> _tabs() => [
    for (final session in widget.sessions.sessions) ...[
      (session: session, kind: TabKind.terminal, path: null, web: null),
      if (session.chatOpen)
        (session: session, kind: TabKind.chat, path: null, web: null),
      if (session.gitOpen)
        (session: session, kind: TabKind.git, path: null, web: null),
      for (final diff in session.diffs)
        (session: session, kind: TabKind.diff, path: diff.key, web: null),
      for (final path in session.openFiles)
        (session: session, kind: TabKind.file, path: path, web: null),
      for (final web in session.webTabs)
        (session: session, kind: TabKind.web, path: null, web: web),
    ],
  ];

  /// Writes a file tree root into the host's saved profile, and hands the
  /// result to the sessions open on it so their next reconnect starts there.
  ///
  /// The profile is read back from storage rather than taken from a session:
  /// writing the session's copy would undo anything edited since.
  Future<void> _saveFileRoot(String hostId, String root) async {
    final hosts = await widget.repository.load();
    final saved = hosts.where((host) => host.id == hostId).firstOrNull;
    if (saved == null) throw StateError('This host is no longer saved.');
    final updated = saved.copyWith(fileRoot: root);
    await widget.repository.upsert(updated);
    widget.sessions.updateHost(updated);
  }

  /// One per page, by what its tab shows, so a tab opened or closed before a
  /// page carries its state along instead of leaving it behind at the old
  /// index. Global, because every page sits under wrappers with no key, the
  /// [IndexedStack]'s own and the [ExcludeFocus] below: a plain key under
  /// them is only compared with whatever page now sits at the same index, so
  /// the page was built afresh, its web page reloaded, its editor read again.
  final Map<String, GlobalKey> _pageKeys = {};

  /// The tabs shown so far, by id. A web or database tab builds its page only
  /// once it has shown, so the tabs brought back from an earlier run do not
  /// all load their pages, or open their connections, as the app starts.
  final Set<String> _shown = {};

  Widget _pageFor(TabRef tab) => switch (tab.kind) {
    TabKind.terminal => TerminalPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      session: tab.session,
      secrets: widget.secrets,
      onOpenFile: (path, {line}) =>
          widget.sessions.openFile(tab.session.id, path, line: line),
      onOpenWeb: (url) => widget.sessions.openWeb(tab.session.id, url),
      onOpenChat: () => widget.sessions.openChat(tab.session.id),
      onOpenGit: () => widget.sessions.openGit(tab.session.id),
      onOpenDiff: (diff) => widget.sessions.openDiff(tab.session.id, diff),
      onSaveFileRoot: (root) => _saveFileRoot(tab.session.host.id, root),
    ),
    TabKind.file => FileEditorPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      browser: tab.session.fileBrowser,
      path: tab.path!,
      // Non-null tells the editor it is embedded rather than a route: leaving
      // it closes this tab instead of popping the whole shell.
      onClose: () => widget.sessions.closeFile(tab.session.id, tab.path!),
      // By host rather than session: a draft is for after the app was killed,
      // when the session it was typed in is long gone.
      draftKey: '${tab.session.host.id}:${tab.path}',
      onOpenWeb: (url) => widget.sessions.openWeb(tab.session.id, url),
      host: tab.session.fileTabHost,
      line:
          tab.session.id == widget.sessions.activeId &&
              tab.path == widget.sessions.activePath
          ? widget.sessions.activeLine
          : null,
    ),
    // Like a web tab: a chat brought back from an earlier run starts Claude
    // on the host the first time it shows, not as the app starts.
    TabKind.chat when !_shown.contains(_idOf(tab)) => const SizedBox.shrink(),
    TabKind.chat => ChatPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      session: tab.session,
      onOpenWeb: (url) => widget.sessions.openWeb(tab.session.id, url),
    ),
    // Like the chat: a git tab brought back from an earlier run asks the host
    // what it has the first time it shows, not as the app starts.
    TabKind.git when !_shown.contains(_idOf(tab)) => const SizedBox.shrink(),
    TabKind.git => GitPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      session: tab.session,
      onOpenDiff: (diff) => widget.sessions.openDiff(tab.session.id, diff),
    ),
    // What git printed, drawn side by side: see [GitDiffPage]. It is built as
    // soon as the tab is, because the command is the session's own and costs
    // one round trip.
    TabKind.diff => _diffPage(tab),
    TabKind.web when !_shown.contains(_idOf(tab)) => const SizedBox.shrink(),
    TabKind.web => WebPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      initialUrl: tab.web!.url,
      onChanged: (url, title) =>
          tab.session.updateWeb(tab.web!, url: url, title: title),
    ),
  };

  /// A diff's page. The diff is looked up by the key its tab carries, so the
  /// page and the strip cannot disagree about which it is.
  Widget _diffPage(TabRef tab) {
    final diff = tab.session.diffs
        .where((open) => open.key == tab.path)
        .firstOrNull;
    if (diff == null) return const SizedBox.shrink();
    return GitDiffPage(
      key: _pageKeys.putIfAbsent(_idOf(tab), GlobalKey.new),
      diff: diff,
      onClose: () => widget.sessions.closeDiff(tab.session.id, diff.key),
    );
  }

  /// Closes [tab], once its page says the changes not saved in its grid may
  /// go: closing it takes the page, and them, with it.
  Future<void> _closeDatabase(DbTab tab) async {
    final page = _pageKeys[_dbIdOf(tab)]?.currentState;
    if (page is DbBrowserPageState && !await page.mayDrop()) return;
    widget.sessions.closeDb(tab);
  }

  /// Attach: a tmux session already running on [from]'s host, picked in
  /// the connect sheet and opened in a tab of its own — over a connection of
  /// its own, as every tab has, and over the same kind of transport [from]
  /// uses, so a local shell's tab does not reach for SSH.
  ///
  /// A tab of its own rather than this one's: the tab the user was in is
  /// still theirs, and one tab is one tmux session everywhere else in the
  /// app.
  Future<void> _attachTmux(LiveSession from) => openInSheet(
    context,
    widget.sessions,
    from.host,
    secrets: widget.secrets,
    transport: from.transport,
    pickTmux: true,
  );

  /// A shell tab's ✕. It ends the tab's tmux session, as it always has —
  /// except one Jeansh did not start, which it leaves running and says so:
  /// see [LiveSession.ownTmux].
  void _closeShell(LiveSession session) {
    final left = session.tmux != null && !session.ownTmux;
    widget.sessions.close(session.id);
    if (!left) return;
    showToast(
      context,
      'Left ${session.tmuxName} running on ${session.host.displayName}: '
      'Jeansh did not start it, so closing its tab does not end it.',
    );
  }

  /// Lets a tab go and leaves its tmux session running on the host.
  Future<void> _detachTmux(LiveSession session) async {
    final name = session.tmuxName;
    final host = session.host.displayName;
    await widget.sessions.detach(session.id);
    if (!mounted) return;
    showToast(context, 'Detached from $name. It keeps running on $host.');
  }

  /// A database's tab. Its page connects when first built, and lets the
  /// connection go when the tab closes.
  Widget _databasePage(DbTab tab) => !_shown.contains(_dbIdOf(tab))
      ? const SizedBox.shrink()
      : DbBrowserPage(
          key: _pageKeys.putIfAbsent(_dbIdOf(tab), GlobalKey.new),
          db: tab.db,
          title: tab.title,
          open:
              widget.openDatabase ??
              (db, {required confirmHostKey, required onSignIn}) =>
                  DbSession.open(
                    db,
                    secrets: widget.secrets,
                    confirmHostKey: confirmHostKey,
                    onSignIn: onSignIn,
                  ),
        );

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs();
    final databases = widget.sessions.dbTabs;
    final showTransfers = widget.sessions.transfersTab;
    final ids = [
      ...tabs.map(_idOf),
      ...databases.map(_dbIdOf),
      if (showTransfers) _transfersId,
    ];
    _pageKeys.removeWhere((id, _) => !ids.contains(id));
    _groups.keepOnly(ids);
    final activeId = widget.sessions.activeId;
    final activeKind = widget.sessions.activeKind;
    final activePath = widget.sessions.activePath;
    final activeWeb = widget.sessions.activeWeb;
    final activeDb = widget.sessions.activeDb;
    // A database's tab comes after every session's, and the Transfers tab
    // after them all. A tab that no longer exists falls back to the host list
    // rather than an out-of-range index.
    final transfersIndex = tabs.length + databases.length + 1;
    final activeIndex = showTransfers && widget.sessions.transfersActive
        ? transfersIndex
        : activeDb != null && databases.contains(activeDb)
        ? tabs.length + 1 + databases.indexOf(activeDb)
        : tabs.indexWhere(
                (tab) =>
                    tab.session.id == activeId &&
                    tab.kind == activeKind &&
                    tab.path == activePath &&
                    tab.web == activeWeb,
              ) +
              1;
    final active = activeIndex == 0 ? null : ids[activeIndex - 1];

    // What the pages are laid out in: a tab on its own, or a group of them.
    final slots = _groups.slots(ids);
    final showing = slots.indexWhere(
      (slot) => slot == active || slot is TabGroup && slot.ids.contains(active),
    );
    final group = showing < 0 ? null : slots[showing];
    if (group is TabGroup) group.focused = active;

    _shown.removeWhere((id) => !ids.contains(id));
    // Every pane of a group is showing, not only the focused one.
    _shown.addAll(group is TabGroup ? group.ids : [?active]);
    if (activeIndex > 0 && activeIndex <= tabs.length) {
      final tab = tabs[activeIndex - 1];
      // A tab brought back from an earlier run connects the first time it
      // shows, in its sheet, as a new one does.
      if (tab.kind == TabKind.terminal && tab.session.takeAutoConnect()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            connectInSheet(
              context,
              tab.session,
              secrets: widget.secrets,
              inTab: (url) => widget.sessions.openWeb(tab.session.id, url),
            ),
          );
        });
      }
    }

    final pages = <String, Widget>{
      for (final tab in tabs) _idOf(tab): _pageFor(tab),
      for (final tab in databases) _dbIdOf(tab): _databasePage(tab),
      if (showTransfers)
        _transfersId: TransfersPage(
          key: _pageKeys.putIfAbsent(_transfersId, GlobalKey.new),
        ),
    };
    // What a tap on each tab's chip does, for a touch on its pane.
    final selects = <String, VoidCallback>{
      for (final tab in tabs)
        _idOf(tab): () => widget.sessions.select(
          tab.session.id,
          kind: tab.kind,
          path: tab.path,
          web: tab.web,
        ),
      for (final tab in databases)
        _dbIdOf(tab): () => widget.sessions.select(null, db: tab),
      _transfersId: () => widget.sessions.showTransfers(select: true),
    };

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            TabStrip(
              tabs: tabs,
              databases: databases,
              activeIndex: activeIndex,
              onSelect: widget.sessions.select,
              onSelectDatabase: (tab) => widget.sessions.select(null, db: tab),
              onClose: (tab) => switch (tab.kind) {
                TabKind.terminal => _closeShell(tab.session),
                TabKind.chat => widget.sessions.closeChat(tab.session.id),
                TabKind.git => widget.sessions.closeGit(tab.session.id),
                TabKind.diff => widget.sessions.closeDiff(
                  tab.session.id,
                  tab.path!,
                ),
                TabKind.file => widget.sessions.closeFile(
                  tab.session.id,
                  tab.path!,
                ),
                TabKind.web => widget.sessions.closeWeb(
                  tab.session.id,
                  tab.web!,
                ),
              },
              onCloseDatabase: _closeDatabase,
              showTransfers: showTransfers,
              onSelectTransfers: () =>
                  widget.sessions.showTransfers(select: true),
              onCloseTransfers: widget.sessions.closeTransfers,
              // The connect sheet, over the tab, as the terminal page's own
              // Try again opens it; a sign-in opens beside the tab.
              onReconnect: (session) => connectInSheet(
                context,
                session,
                secrets: widget.secrets,
                inTab: (url) => widget.sessions.openWeb(session.id, url),
              ),
              // Another shell on the host, added at the end of the strip and
              // shown.
              onDuplicate: widget.onDuplicate ?? widget.onOpenHost,
              onAttach: _attachTmux,
              onDetach: _detachTmux,
              groups: _groups,
            ),
            Expanded(
              child: IndexedStack(
                index: showing + 1,
                children: [
                  for (final (index, page) in [
                    HostsPage(
                      repository: widget.repository,
                      secrets: widget.secrets,
                      sessions: widget.sessions,
                      onOpenHost: widget.onOpenHost,
                      onOpenLocal: widget.onOpenLocal,
                      onOpenWsl: widget.onOpenWsl,
                    ),
                    for (final slot in slots)
                      slot is TabGroup
                          ? TabGroupView(
                              key: slot.key,
                              group: slot,
                              pages: pages,
                              focused: slot == group ? active : null,
                              onFocus: (id) => selects[id]?.call(),
                            )
                          : pages[slot]!,
                  ].indexed)
                    // Every page stays in the tree so its terminal keeps
                    // scroll, key bar and connection — but only the visible
                    // one may hold focus. Without this the hidden terminals
                    // still have focus nodes, and keystrokes land in whichever
                    // one grabbed focus last: typed commands going to the
                    // wrong host. Shown again, each page puts the focus back
                    // on its own terminal, text or web view.
                    ExcludeFocus(excluding: index != showing + 1, child: page),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Public only so a test can lay the strip out without the pages under it.
@visibleForTesting
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    this.databases = const [],
    required this.activeIndex,
    required this.onSelect,
    this.onSelectDatabase,
    required this.onClose,
    this.onCloseDatabase,
    required this.onReconnect,
    required this.onDuplicate,
    this.onAttach,
    this.onDetach,
    this.showTransfers = false,
    this.onSelectTransfers,
    this.onCloseTransfers,
    this.groups,
  });

  final List<TabRef> tabs;

  /// The tab groups, each drawn as one tab holding its tabs' chips. Null
  /// offers no grouping at all.
  final TabGroups? groups;

  /// The databases open in tabs of their own, after every session's tabs.
  final List<DbTab> databases;

  /// Whether the Transfers tab is on the strip, after all the others.
  final bool showTransfers;
  final VoidCallback? onSelectTransfers;
  final VoidCallback? onCloseTransfers;
  final int activeIndex;
  final void Function(int? id, {TabKind kind, String? path, WebTab? web})
  onSelect;
  final void Function(DbTab tab)? onSelectDatabase;
  final void Function(TabRef tab) onClose;
  final void Function(DbTab tab)? onCloseDatabase;
  final void Function(LiveSession session) onReconnect;
  final void Function(String hostId) onDuplicate;

  /// Opens a tmux session already running on the host, picked once
  /// connected, in a tab of its own. Null leaves Attach out of the menu,
  /// which a test that lays out the strip alone wants.
  final Future<void> Function(LiveSession from)? onAttach;

  /// Closes a tab and leaves its tmux session running. Null leaves Detach
  /// out of the menu.
  final Future<void> Function(LiveSession session)? onDetach;

  @override
  State<TabStrip> createState() => _TabStripState();
}

/// Names a tab for as long as it is open, whatever index it is at.
String _idOf(TabRef tab) =>
    '${tab.kind.name}:${tab.session.id}:${tab.path ?? tab.web?.id ?? ''}';

/// The same, for a database's tab.
String _dbIdOf(DbTab tab) => 'database:${tab.id}';

/// The same, for the Transfers tab: there is only one.
const _transfersId = 'transfers';

class _TabStripState extends State<TabStrip> {
  /// One key per tab, so the selected one can be scrolled into view.
  final Map<String, GlobalKey> _keys = {};
  String? _shown;

  @override
  void didUpdateWidget(covariant TabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealActive();
  }

  /// The strip scrolls, so selecting a tab has to bring it into view.
  /// Otherwise a notification tap selects a tab that is off the right-hand
  /// edge, and from the strip nothing appears to have happened.
  void _revealActive() {
    final ids = [
      ...widget.tabs.map(_idOf),
      ...widget.databases.map(_dbIdOf),
      if (widget.showTransfers) _transfersId,
    ];
    final index = widget.activeIndex - 1;
    if (index < 0 || index >= ids.length) {
      _shown = null;
      return;
    }

    final id = ids[index];
    if (id == _shown) return;
    _shown = id;

    // After the frame: a tab opened in this same build has no context to
    // scroll to yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[id]?.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Runs a pane command from a tab's menu, and says so when tmux turns it
  /// down — on a phone, most often because there is no room for another pane.
  Future<void> _tmux(Future<void> Function() command) async {
    try {
      await command();
    } on TmuxException catch (error) {
      if (!mounted) return;
      showToast(context, 'tmux: $error', type: ToastificationType.error);
    }
  }

  /// What a long press on a shell's tab offers. The pane entries act on the
  /// focused pane, and are there only while tmux is: a plain shell has no
  /// panes to split. An ended shell's close button has become Reconnect, so
  /// closing it is offered here instead.
  List<(String, VoidCallback)> _menuFor(TabRef tab) {
    final session = tab.session;
    final tmux = session.isConnected ? session.tmux : null;
    return [
      ('Duplicate session', () => widget.onDuplicate(session.host.id)),
      if (tmux != null && widget.onAttach != null)
        ('Attach to a session…', () => unawaited(widget.onAttach!(session))),
      // Only where there is a tmux session to leave behind: a plain shell
      // detached from is a shell killed.
      if (tmux != null && widget.onDetach != null)
        ('Detach', () => unawaited(widget.onDetach!(session))),
      if (session.ended) ('Close tab', () => widget.onClose(tab)),
      if (tmux != null) ...[
        ('Split right', () => _tmux(() => tmux.split(sideBySide: true))),
        ('Split down', () => _tmux(() => tmux.split(sideBySide: false))),
        // The last pane goes with the tab, by the tab's own close button.
        if (tmux.panes.length > 1) ('Close pane', () => _tmux(tmux.closePane)),
        // Not on a session somebody made by hand, which the app never sets
        // recording, nor where there is no file browser to read one through:
        // this machine's own shells, which keep none.
        if (tmux.record != null && session.canBrowseFiles)
          ('Pane record', () => _openRecord(session, tmux)),
      ],
    ];
  }

  /// Opens the focused pane's record, as the host has kept it.
  Future<void> _openRecord(LiveSession session, TmuxSession tmux) async {
    final pane = tmux.focused;
    final name = pane == null ? null : await tmux.recordName(pane);
    if (!mounted) return;
    if (pane == null || name == null) {
      showToast(
        context,
        'tmux did not say which pane this is.',
        type: ToastificationType.error,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaneRecordPage(
          reader: PaneRecordReader(
            session.fileBrowser,
            session: session.tmuxName,
            name: name,
          ),
          columns: pane.cells.width,
          rows: pane.cells.height,
        ),
      ),
    );
  }

  /// What a long press on any tab offers towards grouping: putting it in a
  /// pane beside another tab, or group, and taking it out of its own.
  List<(String, VoidCallback)> _groupMenu(
    String id,
    List<Object> slots,
    Map<String, String> names,
    Map<String, VoidCallback> selects,
  ) {
    final groups = widget.groups;
    if (groups == null) return const [];
    return [
      if (slots.length > 1)
        ('Group with…', () => _groupWith(id, slots, names, selects)),
      if (groups.of(id) != null) ('Take out of group', () => groups.leave(id)),
    ];
  }

  /// Asks which tab, or group, [id] goes beside, and shows it there.
  Future<void> _groupWith(
    String id,
    List<Object> slots,
    Map<String, String> names,
    Map<String, VoidCallback> selects,
  ) async {
    final groups = widget.groups!;
    final own = groups.of(id);
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Group ${names[id]} with'),
        children: [
          for (final slot in slots)
            if (slot != id && slot != own)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  context,
                  slot is TabGroup ? slot.ids.first : slot as String,
                ),
                child: Text(
                  slot is TabGroup
                      ? slot.ids.map((id) => names[id]).join(' + ')
                      : names[slot]!,
                ),
              ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    groups.join(id, target);
    selects[id]?.call();
  }

  /// A group on the strip: its button, then its tabs' own chips in pane
  /// order, in one outline, lit while the group is showing.
  Widget _groupChip(
    TabGroup group,
    Map<String, Widget> chips,
    Map<String, VoidCallback> selects,
    String? active,
  ) {
    final theme = Theme.of(context);
    final groups = widget.groups!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: group.ids.contains(active)
              ? theme.colorScheme.primary.withValues(alpha: 0.7)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TabChip(
            icon: group.stacked
                ? Icons.view_agenda_outlined
                : Icons.view_column_outlined,
            label: null,
            tooltip: 'Tab group',
            selected: false,
            onTap: () => selects[group.focused ?? group.ids.first]?.call(),
            menu: [
              (
                group.stacked ? 'Side by side' : 'Stacked',
                () => groups.flip(group),
              ),
              ('Ungroup', () => groups.ungroup(group)),
            ],
          ),
          for (final id in group.ids) chips[id]!,
        ],
      ),
    );
  }

  /// Below this the strip is too narrow to let the new-tab button wander:
  /// Material's compact breakpoint, which is every phone in portrait.
  static const double _wideStrip = 600;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = widget.tabs;
    final databases = widget.databases;
    final ids = [
      ...tabs.map(_idOf),
      ...databases.map(_dbIdOf),
      if (widget.showTransfers) _transfersId,
    ];
    _keys.removeWhere((id, _) => !ids.contains(id));
    final active = widget.activeIndex > 0 && widget.activeIndex <= ids.length
        ? ids[widget.activeIndex - 1]
        : null;
    final slots = widget.groups?.slots(ids) ?? ids;

    // A lone tab takes the whole strip, the way Terminus lays it out: there
    // is nothing to scroll to or to make room for, so capping it would only
    // cut short the one name on the strip.
    final single = ids.length == 1;

    final addTab = _TabChip(
      icon: Icons.add,
      label: null,
      tooltip: 'New tab',
      selected: false,
      onTap: () => widget.onSelect(null),
    );

    // Each tab's chip, name and tap, by id: a group gathers its tabs' chips
    // into one, and its menu asks for their names.
    final chips = <String, Widget>{};
    final names = <String, String>{};
    final selects = <String, VoidCallback>{};
    List<(String, VoidCallback)> grouping(String id) =>
        _groupMenu(id, slots, names, selects);

    for (final tab in tabs) {
      final id = _idOf(tab);
      final name = names[id] = switch (tab.kind) {
        // As a file tab reads: the host, then what the tab is.
        TabKind.chat => '${tab.session.fileTabHost} · Claude',
        TabKind.git => 'Git',
        // The diff's own name already says what it is: "main.dart · diff".
        TabKind.diff => tab.session.diffTabTitle(tab.path!),
        TabKind.file => tab.session.fileTabTitle(tab.path!),
        TabKind.web => tab.web!.title,
        TabKind.terminal => tab.session.title,
      };
      final select = selects[id] = () => widget.onSelect(
        tab.session.id,
        kind: tab.kind,
        path: tab.path,
        web: tab.web,
      );
      chips[id] = _TabChip(
        key: _keys.putIfAbsent(id, GlobalKey.new),
        icon: switch (tab.kind) {
          TabKind.chat => Icons.forum_outlined,
          TabKind.git => Icons.account_tree_outlined,
          TabKind.diff => Icons.difference_outlined,
          TabKind.file => Icons.description_outlined,
          TabKind.web => Icons.public,
          // tmux, said quietly: the same chip, split.
          TabKind.terminal when tab.session.tmux != null =>
            Icons.vertical_split_outlined,
          TabKind.terminal => Icons.terminal,
        },
        label: name,
        cutFirst:
            tab.kind == TabKind.file ||
                tab.kind == TabKind.chat ||
                tab.kind == TabKind.diff
            ? tab.session.fileTabHost
            : null,
        selected: id == active,
        connected: tab.kind == TabKind.terminal && tab.session.isConnected,
        expand: single,
        onTap: select,
        onClose: () => widget.onClose(tab),
        onReconnect: tab.kind == TabKind.terminal && tab.session.ended
            ? () => widget.onReconnect(tab.session)
            : null,
        menu: [
          if (tab.kind == TabKind.terminal) ..._menuFor(tab),
          ...grouping(id),
        ],
      );
    }
    for (final tab in databases) {
      final id = _dbIdOf(tab);
      names[id] = tab.title;
      final select = selects[id] = () => widget.onSelectDatabase?.call(tab);
      chips[id] = _TabChip(
        key: _keys.putIfAbsent(id, GlobalKey.new),
        icon: Icons.storage,
        mark: DbBadge(tab.db.kind, size: _TabChip._iconSize),
        label: tab.title,
        selected: id == active,
        expand: single,
        onTap: select,
        onClose: () => widget.onCloseDatabase?.call(tab),
        menu: grouping(id),
      );
    }
    if (widget.showTransfers) {
      names[_transfersId] = 'Transfers';
      final select = selects[_transfersId] = () =>
          widget.onSelectTransfers?.call();
      // Only this chip follows the transfers, lit while one is on its way
      // as a live shell's is; the strip is built again only as tabs change.
      chips[_transfersId] = ListenableBuilder(
        key: _keys.putIfAbsent(_transfersId, GlobalKey.new),
        listenable: transfers,
        builder: (context, _) => _TabChip(
          icon: Icons.swap_vert,
          label: 'Transfers',
          selected: _transfersId == active,
          connected: transfers.anyRunning,
          expand: single,
          onTap: select,
          onClose: () => widget.onCloseTransfers?.call(),
          menu: grouping(_transfersId),
        ),
      );
    }

    final strip = [
      for (final slot in slots)
        slot is TabGroup
            ? _groupChip(slot, chips, selects, active)
            : chips[slot]!,
    ];

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Wide: the button follows the last tab, the way a desktop browser
          // puts it. Narrow: it stays parked on the right, where a thumb can
          // find it without hunting for the end of a strip that scrolls. A
          // lone tab stretches up to it, so there it is parked either way.
          final followsTabs = !single && constraints.maxWidth >= _wideStrip;

          return Row(
            children: [
              // Pinned: the host list is how a new tab gets opened, so it is never
              // scrolled away or closed. It drops to its icon while you are on a
              // session, handing the room back to the tabs that need it.
              _TabChip(
                icon: Icons.home_outlined,
                label: widget.activeIndex == 0 ? 'Home' : null,
                tooltip: 'Home',
                selected: widget.activeIndex == 0,
                onTap: () => widget.onSelect(null),
              ),
              Expanded(
                child: single
                    ? strip.single
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [...strip, if (followsTabs) addTab],
                        ),
                      ),
              ),
              if (!followsTabs) addTab,
            ],
          );
        },
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.icon,
    this.mark,
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.connected = false,
    this.expand = false,
    this.onClose,
    this.onReconnect,
    this.cutFirst,
    this.menu = const [],
  });

  /// null shows the icon alone — the chip still answers to [tooltip], so it
  /// keeps its name for a screen reader.
  final String? label;
  final String? tooltip;
  final IconData icon;

  /// Drawn in [icon]'s place when it isn't null: a database tab's brand mark,
  /// which carries its own colour rather than the chip's.
  final Widget? mark;
  final bool selected;
  final bool connected;

  /// Fill the width the chip is given instead of fitting its name: the name
  /// takes the room and the close button lands at the far end of the pill.
  final bool expand;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  /// Takes the close button's place once a session's shell has ended, which
  /// is when the tab is more use brought back than thrown away. The header
  /// that used to offer this is gone, so the tab is where it lives.
  final VoidCallback? onReconnect;

  /// The start of [label] that gives way first when the chip is too narrow
  /// for all of it: a file tab's host. The ` · main.dart` after it is what
  /// tells two files on one host apart, so that keeps its room. null cuts the
  /// end, as a shell's name is cut.
  final String? cutFirst;

  /// What a long press on the tab offers — a press it had no other use for:
  /// another session on a shell's host, and tmux's pane commands. Empty on a
  /// file, web or database tab, which have nothing of their own to offer.
  final List<(String, VoidCallback)> menu;

  /// How much of a name a tab may show.
  ///
  /// A phone strip fits roughly one and a half tabs, so the room goes where
  /// it is read: the tab you are on gets enough for `host · file.dart`, the
  /// rest get enough to be recognised and are ellipsised. Anything longer
  /// scrolls into view when selected rather than shrinking every other tab.
  static const double _selectedText = 180;
  static const double _idleText = 110;

  /// Every chip on the strip — the host list, each tab, new tab — is this
  /// tall, and an icon alone gets as much room across as up. The end buttons
  /// come out square and level with the tabs rather than as loose icons of a
  /// different weight beside them.
  static const double _height = 34;
  static const double _iconSize = 16;
  static const double _inset = (_height - _iconSize) / 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    final name = label;
    final cut = cutFirst;
    final room = selected ? _selectedText : _idleText;
    final reconnect = onReconnect != null;
    final onEnd = onReconnect ?? onClose;
    Text text(String data) => Text(
      data,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      softWrap: false,
      style: theme.textTheme.labelLarge?.copyWith(color: foreground),
    );
    final title = name == null
        ? null
        : cut == null || !name.startsWith(cut)
        ? text(name)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: text(cut)),
              // Capped on its own: a Row lays out what does not flex without
              // a limit, so a file name wider than the chip would run past it
              // instead of being cut in its turn.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: room),
                child: text(name.substring(cut.length)),
              ),
            ],
          );

    final chip = Material(
      // The page's own colour marks where you are. Everything else wears the
      // same faint fill, so it reads as a button — without one, the host list
      // collapses to a bare icon the moment a session is showing.
      color: selected
          ? theme.colorScheme.surface
          : theme.colorScheme.onSurface.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        onLongPress: menu.isEmpty ? null : () => _showMenu(context),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            _inset,
            0,
            onEnd == null ? _inset : 2,
            0,
          ),
          child: Row(
            children: [
              mark ??
                  Icon(
                    icon,
                    size: _iconSize,
                    color: connected ? theme.colorScheme.primary : foreground,
                  ),
              if (title != null) ...[
                const SizedBox(width: 6),
                if (expand)
                  Expanded(child: title)
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: room),
                    child: title,
                  ),
              ],
              if (onEnd != null)
                IconButton(
                  tooltip: reconnect ? 'Reconnect' : 'Close ${name ?? tooltip}',
                  onPressed: onEnd,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: Icon(
                    reconnect ? Icons.cable : Icons.close,
                    size: 14,
                    color: foreground,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // Dropped to its icon — the host list while a session is showing — the chip
    // carries no text at all, so a screen reader announces an unnamed button
    // and there is nothing to tap by name. A Tooltip alone does not fix that:
    // it sets Android's tooltipText, which is not the node's name. The tooltip
    // is the name the chip already has, so say it out loud.
    final named = title == null && tooltip != null
        ? Semantics(label: tooltip, button: true, child: chip)
        : chip;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: _height,
        child: tooltip == null
            ? named
            : Tooltip(message: tooltip!, child: named),
      ),
    );
  }

  /// Dropped from the chip's own lower edge rather than from the finger, so
  /// it reads as the pressed tab's menu and leaves the tab itself in view.
  void _showMenu(BuildContext context) {
    final chip = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final corner = chip.localToGlobal(
      chip.size.bottomLeft(Offset.zero),
      ancestor: overlay,
    );
    showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        corner & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final (label, onTap) in menu)
          PopupMenuItem(onTap: onTap, child: Text(label)),
      ],
    );
  }
}
