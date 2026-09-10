import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../session/session_manager.dart';
import 'file_editor_page.dart';
import 'hosts_page.dart';
import 'terminal_page.dart';

/// One tab, named by what it shows rather than by an index — indices shift
/// every time a tab opens or closes. [path] is set only for a file tab.
typedef TabRef = ({LiveSession session, TabKind kind, String? path});

/// The app's one screen: a pinned host list on the left, then a tab per open
/// session, and beside each session a tab for every file opened from its
/// files drawer.
///
/// Tabs are a view of [SessionManager] rather than a list of their own —
/// which tab exists, in what order, and which one is showing all come from
/// there, so a notification tap and a tap in the host list still land the same
/// way without this widget knowing about either.
///
/// The pages sit in an [IndexedStack] so switching tabs keeps each terminal's
/// key bar and scroll position, and each file its scroll position, exactly as
/// they were left.
class TabsShell extends StatefulWidget {
  const TabsShell({
    super.key,
    required this.repository,
    required this.secrets,
    required this.sessions,
    required this.onOpenHost,
    required this.pushToken,
  });

  final HostRepository repository;
  final SecretStore secrets;
  final SessionManager sessions;
  final Future<void> Function(String hostId) onOpenHost;
  final String? Function() pushToken;

  @override
  State<TabsShell> createState() => _TabsShellState();
}

class _TabsShellState extends State<TabsShell> {
  @override
  void initState() {
    super.initState();
    widget.sessions.addListener(_onSessionsChanged);
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_onSessionsChanged);
    super.dispose();
  }

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  /// Left to right: each session's shell, then the files opened from it. A
  /// file tab sits next to its session because it is that session it is read
  /// over — closing the shell takes them with it.
  List<TabRef> _tabs() => [
    for (final session in widget.sessions.sessions) ...[
      (session: session, kind: TabKind.terminal, path: null),
      for (final path in session.openFiles)
        (session: session, kind: TabKind.file, path: path),
    ],
  ];

  Widget _pageFor(TabRef tab) => switch (tab.kind) {
    TabKind.terminal => TerminalPage(
      // Keyed by what the tab shows so closing one carries the
      // remaining pages' state along with them instead of leaving it
      // behind at the old index.
      key: ValueKey('terminal:${tab.session.id}'),
      session: tab.session,
      secrets: widget.secrets,
      onOpenFile: (path) => widget.sessions.openFile(tab.session.id, path),
    ),
    TabKind.file => FileEditorPage(
      key: ValueKey('file:${tab.session.id}:${tab.path}'),
      browser: tab.session.fileBrowser,
      path: tab.path!,
      // Non-null tells the editor it is embedded rather than a route: leaving
      // it closes this tab instead of popping the whole shell.
      onClose: () => widget.sessions.closeFile(tab.session.id, tab.path!),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs();
    final activeId = widget.sessions.activeId;
    final activeKind = widget.sessions.activeKind;
    final activePath = widget.sessions.activePath;
    // A tab that no longer exists falls back to the host list rather than an
    // out-of-range index.
    final activeIndex =
        tabs.indexWhere(
          (tab) =>
              tab.session.id == activeId &&
              tab.kind == activeKind &&
              tab.path == activePath,
        ) +
        1;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            TabStrip(
              tabs: tabs,
              activeIndex: activeIndex,
              onSelect: widget.sessions.select,
              onClose: (tab) => switch (tab.kind) {
                TabKind.terminal => widget.sessions.close(tab.session.id),
                TabKind.file => widget.sessions.closeFile(
                  tab.session.id,
                  tab.path!,
                ),
              },
            ),
            Expanded(
              child: IndexedStack(
                index: activeIndex,
                children: [
                  for (final (index, page) in [
                    HostsPage(
                      repository: widget.repository,
                      secrets: widget.secrets,
                      sessions: widget.sessions,
                      onOpenHost: widget.onOpenHost,
                      pushToken: widget.pushToken,
                    ),
                    ...tabs.map(_pageFor),
                  ].indexed)
                    // Every page stays in the tree so its terminal keeps
                    // scroll, key bar and connection — but only the visible
                    // one may hold focus. Without this the hidden terminals
                    // still have focus nodes, and keystrokes land in whichever
                    // one grabbed focus last: typed commands going to the
                    // wrong host.
                    ExcludeFocus(excluding: index != activeIndex, child: page),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Public only so a test can lay the strip out without the pages under it —
/// a terminal page connects over SSH as soon as it is built.
@visibleForTesting
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
  });

  final List<TabRef> tabs;
  final int activeIndex;
  final void Function(int? id, {TabKind kind, String? path}) onSelect;
  final void Function(TabRef tab) onClose;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  /// One key per tab, so the selected one can be scrolled into view.
  final Map<String, GlobalKey> _keys = {};
  String? _shown;

  static String _idOf(TabRef tab) =>
      '${tab.kind.name}:${tab.session.id}:${tab.path ?? ''}';

  @override
  void didUpdateWidget(covariant TabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealActive();
  }

  /// The strip scrolls, so selecting a tab has to bring it into view.
  /// Otherwise a notification tap selects a tab that is off the right-hand
  /// edge, and from the strip nothing appears to have happened.
  void _revealActive() {
    final index = widget.activeIndex - 1;
    if (index < 0 || index >= widget.tabs.length) {
      _shown = null;
      return;
    }

    final id = _idOf(widget.tabs[index]);
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

  /// Below this the strip is too narrow to let the new-tab button wander:
  /// Material's compact breakpoint, which is every phone in portrait.
  static const double _wideStrip = 600;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = widget.tabs;
    final ids = tabs.map(_idOf).toSet();
    _keys.removeWhere((id, _) => !ids.contains(id));

    // A lone tab takes the whole strip, the way Terminus lays it out: there
    // is nothing to scroll to or to make room for, so capping it would only
    // cut short the one name on the strip.
    final single = tabs.length == 1;

    final addTab = _TabChip(
      icon: Icons.add,
      label: null,
      tooltip: 'New tab',
      selected: false,
      onTap: () => widget.onSelect(null),
    );

    final chips = [
      for (final (index, tab) in tabs.indexed)
        _TabChip(
          key: _keys.putIfAbsent(_idOf(tab), GlobalKey.new),
          icon: tab.kind == TabKind.file
              ? Icons.description_outlined
              : Icons.terminal,
          label: tab.kind == TabKind.file
              ? tab.session.fileTabTitle(tab.path!)
              : tab.session.title,
          selected: index + 1 == widget.activeIndex,
          connected: tab.kind == TabKind.terminal && tab.session.isConnected,
          expand: single,
          onTap: () => widget.onSelect(
            tab.session.id,
            kind: tab.kind,
            path: tab.path,
          ),
          onClose: () => widget.onClose(tab),
        ),
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
                icon: Icons.dns_outlined,
                label: widget.activeIndex == 0 ? 'Hosts' : null,
                tooltip: 'Hosts',
                selected: widget.activeIndex == 0,
                onTap: () => widget.onSelect(null),
              ),
              Expanded(
                child: single
                    ? chips.single
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [...chips, if (followsTabs) addTab],
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
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.connected = false,
    this.expand = false,
    this.onClose,
  });

  /// null shows the icon alone — the chip still answers to [tooltip], so it
  /// keeps its name for a screen reader.
  final String? label;
  final String? tooltip;
  final IconData icon;
  final bool selected;
  final bool connected;

  /// Fill the width the chip is given instead of fitting its name: the name
  /// takes the room and the close button lands at the far end of the pill.
  final bool expand;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  /// How much of a name a tab may show.
  ///
  /// A phone strip fits roughly one and a half tabs, so the room goes where
  /// it is read: the tab you are on gets enough for `host > file.dart`, the
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
    final title = name == null
        ? null
        : Text(
            name,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
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
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            _inset,
            0,
            onClose == null ? _inset : 2,
            0,
          ),
          child: Row(
            children: [
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
                    constraints: BoxConstraints(
                      maxWidth: selected ? _selectedText : _idleText,
                    ),
                    child: title,
                  ),
              ],
              if (onClose != null)
                IconButton(
                  tooltip: 'Close ${name ?? tooltip}',
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: Icon(Icons.close, size: 14, color: foreground),
                ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: _height,
        child: tooltip == null ? chip : Tooltip(message: tooltip!, child: chip),
      ),
    );
  }
}
