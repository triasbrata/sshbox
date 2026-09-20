import 'dart:async';

import 'package:flutter/material.dart';

import '../git/git_repo.dart';
import '../session/session_manager.dart';
import 'settings_page.dart' show terminalSettings;
import 'toast.dart';

/// The repositories on the host, beside that host's shell — what the editors
/// put in their side panel: what has changed, what is staged, the history, and
/// a box to commit from.
///
/// It owns nothing of the connection: every command goes out through the
/// session, so a tab left open across a reconnect works again the moment the
/// shell is back, and closing the tab lets the repositories go.
class GitPage extends StatefulWidget {
  const GitPage({super.key, required this.session, this.onClose});

  final LiveSession session;

  /// Shuts the drawer this panel is in, where Settings opens it as one. Left
  /// out in a tab, whose ✕ on the strip is how it closes.
  final VoidCallback? onClose;

  @override
  State<GitPage> createState() => _GitPageState();
}

class _GitPageState extends State<GitPage> {
  late final GitRepos _repos = widget.session.repos;
  final _message = TextEditingController();

  List<GitStatusEntry> _status = const [];
  List<GitCommitEntry> _log = const [];
  String _branch = '';
  String? _error;
  bool _busy = false;

  /// The repository the lists below were read from, so a repository picked in
  /// the header loads its own rather than showing the last one's.
  String? _loaded;

  @override
  void initState() {
    super.initState();
    _repos.addListener(_onRepos);
    widget.session.addListener(_onSession);
    unawaited(_discover());
  }

  @override
  void dispose() {
    _repos.removeListener(_onRepos);
    widget.session.removeListener(_onSession);
    _message.dispose();
    super.dispose();
  }

  void _onRepos() {
    if (!mounted) return;
    setState(() {});
    final root = _repos.selected?.root;
    if (root != null && root != _loaded) unawaited(_reload());
  }

  /// A reconnect finds the repositories again: the shell that answered the
  /// first search is gone, and the host may not be the same one.
  bool _wasConnected = false;
  void _onSession() {
    if (!mounted) return;
    // The tab closing notifies too, and by then the session has let go of its
    // repositories: asking for another search there is asking a disposed
    // object. Asked of the repositories rather than of the tab, because this
    // panel also opens in the terminal's drawer, where there is no tab at all.
    if (_repos.disposed) return;
    final connected = widget.session.isConnected;
    if (connected && !_wasConnected) unawaited(_discover());
    _wasConnected = connected;
    setState(() {});
  }

  Future<void> _discover() async {
    if (!widget.session.isConnected) return;
    await _repos.discover();
  }

  /// Reads the status, the branch and the history of the repository now
  /// picked. One place, so every action that changes the repository ends by
  /// calling it and the two tabs never disagree.
  Future<void> _reload() async {
    final repo = _repos.selected;
    if (repo == null || !widget.session.isConnected) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await repo.status();
      final log = await repo.log();
      final branch = await repo.branch();
      if (!mounted) return;
      setState(() {
        _status = status;
        _log = log;
        _branch = branch;
        _loaded = repo.root;
      });
    } on GitException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs one action on the repository and reloads, saying why when git
  /// refuses — "nothing to commit", a hook that failed, a path already gone.
  Future<void> _act(Future<void> Function(GitRepo repo) action) async {
    final repo = _repos.selected;
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      await action(repo);
      await _reload();
    } on GitException catch (error) {
      if (mounted) {
        showToast(context, error.message, type: ToastificationType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final message = _message.text;
    await _act((repo) async {
      final said = await repo.commit(message);
      _message.clear();
      if (mounted) showToast(context, said.split('\n').first);
    });
  }

  /// The diff of a path, or of a commit, on a page of its own over this one:
  /// a diff is wide and long, and the lists are what the user comes back to.
  Future<void> _show(String title, Future<String> body) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DiffPage(title: title, body: body),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = _repos.selected;
    final staged = [
      for (final entry in _status)
        if (entry.staged != null && entry.staged != GitChange.untracked) entry,
    ];
    final unstaged = [
      for (final entry in _status)
        if (entry.worktree != null) entry,
    ];

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _header(theme, repo),
              const TabBar(
                tabs: [
                  Tab(text: 'Changes'),
                  Tab(text: 'History'),
                ],
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: TabBarView(
                  children: [
                    _changes(theme, repo, staged: staged, unstaged: unstaged),
                    _history(theme, repo),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, GitRepo? repo) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
    child: Row(
      children: [
        const Icon(Icons.account_tree_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: repo?.root,
              hint: const Text('Select a repository…'),
              items: [
                for (final option in _repos.repos)
                  DropdownMenuItem(
                    value: option.root,
                    child: Text(
                      option.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (root) {
                final picked = _repos.repos
                    .where((option) => option.root == root)
                    .firstOrNull;
                if (picked != null) _repos.select(picked);
              },
            ),
          ),
        ),
        if (_branch.isNotEmpty) ...[
          const SizedBox(width: 8),
          // Flexible, because a branch name has no length: full width it fits,
          // but in the drawer on a phone a long one pushed the buttons beside
          // it off the edge of the screen.
          Flexible(
            child: Text(
              _branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
        IconButton(
          tooltip: 'Refresh',
          onPressed: _busy ? null : () => unawaited(_reload()),
          icon: const Icon(Icons.refresh),
        ),
        if (widget.onClose != null)
          IconButton(
            tooltip: 'Close',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
      ],
    ),
  );

  Widget _changes(
    ThemeData theme,
    GitRepo? repo, {
    required List<GitStatusEntry> staged,
    required List<GitStatusEntry> unstaged,
  }) {
    final problem = _error ?? _repos.problem;
    if (repo == null || problem != null) {
      return _Message(
        text: problem ?? 'Looking for repositories…',
        onRetry: () => unawaited(_discover()),
      );
    }

    return Column(
      children: [
        Expanded(
          child: staged.isEmpty && unstaged.isEmpty
              ? const _Message(text: 'No changes to commit')
              : ListView(
                  children: [
                    if (staged.isNotEmpty) ...[
                      _SectionRow(
                        title: 'Staged',
                        count: staged.length,
                        action: null,
                      ),
                      for (final entry in staged)
                        _FileRow(
                          entry: entry,
                          change: entry.staged!,
                          icon: Icons.remove,
                          tooltip: 'Unstage',
                          onAct: () => unawaited(
                            _act((repo) => repo.unstage(entry.path)),
                          ),
                          onOpen: () => unawaited(
                            _show(
                              entry.path,
                              repo.diff(entry.path, staged: true),
                            ),
                          ),
                        ),
                    ],
                    if (unstaged.isNotEmpty) ...[
                      _SectionRow(
                        title: 'Changes',
                        count: unstaged.length,
                        action: (
                          label: 'Stage All',
                          onPressed: () =>
                              unawaited(_act((repo) => repo.stageAll())),
                        ),
                      ),
                      for (final entry in unstaged)
                        _FileRow(
                          entry: entry,
                          change: entry.worktree!,
                          icon: Icons.add,
                          tooltip: 'Stage',
                          onAct: () =>
                              unawaited(_act((repo) => repo.stage(entry.path))),
                          onOpen: () => unawaited(
                            _show(
                              entry.path,
                              repo.diff(entry.path, staged: false),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _message,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Enter commit message',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    // Only what is staged goes in, as the editors do it: the
                    // list above says exactly what that is.
                    onPressed: _busy || staged.isEmpty
                        ? null
                        : () => unawaited(_commit()),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Commit'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _history(ThemeData theme, GitRepo? repo) {
    if (repo == null) return const _Message(text: 'No repository');
    if (_log.isEmpty) {
      return const _Message(text: 'No commits yet');
    }
    return ListView.builder(
      itemCount: _log.length,
      itemBuilder: (context, i) {
        final commit = _log[i];
        return ListTile(
          dense: true,
          title: Text(
            commit.subject,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${commit.author} · ${commit.when} · ${commit.sha}'),
          onTap: () => unawaited(_show(commit.sha, repo.show(commit.sha))),
        );
      },
    );
  }
}

/// A heading over one of the two lists, with the count and, for the unstaged
/// list, Stage All beside it.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.title,
    required this.count,
    required this.action,
  });

  final String title;
  final int count;
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
      child: Row(
        children: [
          Text(
            '$title ($count)',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (action != null)
            TextButton(
              onPressed: action!.onPressed,
              child: Text(action!.label),
            ),
        ],
      ),
    );
  }
}

/// One changed path: its letter, its name, and the one button that moves it
/// in or out of the index.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.entry,
    required this.change,
    required this.icon,
    required this.tooltip,
    required this.onAct,
    required this.onOpen,
  });

  final GitStatusEntry entry;
  final GitChange change;
  final IconData icon;
  final String tooltip;
  final VoidCallback onAct;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Green for what is added, red for what is gone, the accent for the rest:
    // the same reading as the letters down an editor's gutter.
    final colour = switch (change) {
      GitChange.added || GitChange.untracked => Colors.green,
      GitChange.deleted => theme.colorScheme.error,
      GitChange.conflicted => Colors.orange,
      _ => theme.colorScheme.primary,
    };

    return ListTile(
      dense: true,
      leading: Tooltip(
        message: change.label,
        child: Text(
          change.code,
          style: theme.textTheme.titleMedium?.copyWith(color: colour),
        ),
      ),
      title: Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: tooltip,
        onPressed: onAct,
        icon: Icon(icon, size: 20),
      ),
      onTap: onOpen,
    );
  }
}

/// Whatever there is to say when there is no list to draw: nothing changed,
/// no repository, or why the search failed, with a way to try again.
class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A diff, drawn in the terminal's own font at the terminal's own size, with
/// added and removed lines coloured — the one place in the app where reading
/// column by column matters as much as it does in the shell.
class _DiffPage extends StatelessWidget {
  const _DiffPage({required this.title, required this.body});

  final String title;
  final Future<String> body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<String>(
        future: body,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final error = snapshot.error;
          if (error != null) return _Message(text: '$error');
          final text = snapshot.data ?? '';
          if (text.trim().isEmpty) {
            return const _Message(text: 'Nothing to show');
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ValueListenableBuilder(
                valueListenable: terminalSettings,
                builder: (context, style, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in text.split('\n'))
                      Text(
                        line,
                        // The terminal's font and size, but its own colours:
                        // what [terminalSettings] holds is xterm2's style for
                        // a whole terminal, not a text style.
                        style: TextStyle(
                          fontFamily: style.fontFamily,
                          fontSize: style.fontSize,
                          color: switch (line) {
                            _ when line.startsWith('+++') => null,
                            _ when line.startsWith('---') => null,
                            _ when line.startsWith('+') => Colors.green,
                            _ when line.startsWith('-') =>
                              theme.colorScheme.error,
                            _ when line.startsWith('@@') =>
                              theme.colorScheme.primary,
                            _ => null,
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
