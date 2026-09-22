import 'dart:async';

import 'package:flutter/material.dart';

import '../files/file_browser.dart' show RemotePath;
import '../git/git_diff.dart';
import '../git/git_repo.dart';
import '../session/session_manager.dart';
import 'toast.dart';

/// The repositories on the host, beside that host's shell — what the editors
/// put in their side panel: what has changed, what is staged, the history, and
/// a box to commit from.
///
/// It owns nothing of the connection: every command goes out through the
/// session, so a tab left open across a reconnect works again the moment the
/// shell is back, and closing the tab lets the repositories go.
class GitPage extends StatefulWidget {
  const GitPage({
    super.key,
    required this.session,
    this.onClose,
    this.onOpenDiff,
  });

  final LiveSession session;

  /// Shuts the drawer this panel is in, where Settings opens it as one. Left
  /// out in a tab, whose ✕ on the strip is how it closes.
  final VoidCallback? onClose;

  /// Opens a diff in a file tab beside the shell. Left out, tapping a change
  /// or a commit does nothing — no panel of this app's ever leaves it out.
  final void Function(GitDiff diff)? onOpenDiff;

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

  /// The branches History can show, empty where git cannot list them.
  List<GitBranch> _branches = const [];

  /// The full ref History shows the commits of; null for the checkout's own.
  /// Only looked at: nothing is checked out, so the files on the host, and
  /// whatever is running over them, stay exactly as they are.
  String? _viewing;

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
    // A branch looked at in one repository means nothing in the next.
    if (repo.root != _loaded) _viewing = null;
    final viewing = _viewing;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await repo.status();
      final branches = await _branchesOf(repo);
      // One deleted since it was picked goes back to the checkout's history.
      final shown = branches.any((b) => b.ref == viewing) ? viewing : null;
      final log = await repo.log(ref: shown);
      final branch = await repo.branch();
      if (!mounted) return;
      // Another repository or branch was picked while these were read: its
      // own reload is the one whose answer belongs on screen.
      if (_repos.selected?.root != repo.root || _viewing != viewing) return;
      setState(() {
        _status = status;
        _log = log;
        _branch = branch;
        _branches = branches;
        _viewing = shown;
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

  /// The branches to offer, or none where git will not list them — a git
  /// older than `for-each-ref`'s `%(HEAD)` — which leaves History showing
  /// the checkout's own, as it did before it could show any other, rather
  /// than failing the whole panel over something extra.
  static Future<List<GitBranch>> _branchesOf(GitRepo repo) async {
    try {
      return await repo.branches();
    } on GitException {
      return const [];
    }
  }

  /// Shows another branch's history, or the checkout's again for null.
  void _view(String? ref) {
    if (ref == _viewing) return;
    setState(() => _viewing = ref);
    unawaited(_reload());
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

  /// The diff of a path, or of a commit, handed to a tab of its own: a diff
  /// is wide and long, and wants the whole width to be set side by side,
  /// while this panel keeps the lists, which are what the user comes back to.
  ///
  /// The command, not its answer, is what the tab is given, so its Reload runs
  /// git again; and it is bound to [repo] rather than to the panel, so a diff
  /// goes on working after the panel is closed or another repository is
  /// picked in it — the lines around a hunk it reads from [repo] too.
  void _show(
    GitRepo repo, {
    required String key,
    required String title,
    required String subtitle,
    required Future<String> Function() read,
  }) => widget.onOpenDiff?.call(
    GitDiff(
      key: key,
      title: title,
      subtitle: subtitle,
      read: read,
      blob: repo.blob,
    ),
  );

  /// The diff of one changed path, staged or not.
  void _showFile(GitRepo repo, String path, {required bool staged}) => _show(
    repo,
    key: '${repo.root}:$path${staged ? ':staged' : ''}',
    title: '${RemotePath.basename(path)} · ${staged ? 'staged diff' : 'diff'}',
    subtitle: '$path · ${RemotePath.basename(repo.root)}',
    read: () => repo.diff(path, staged: staged),
  );

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
                    // A worktree's folder is named after whatever made it —
                    // Claude Code calls them agent-a4c3… — so whose it is has
                    // to be said beside it.
                    child: Text.rich(
                      TextSpan(
                        text: option.name,
                        children: [
                          if (option.mainRoot case final main?)
                            TextSpan(
                              text:
                                  '  worktree of ${RemotePath.basename(main)}',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
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
                          onOpen: () =>
                              _showFile(repo, entry.path, staged: true),
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
                          onOpen: () =>
                              _showFile(repo, entry.path, staged: false),
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
    final viewing = _branches.where((b) => b.ref == _viewing).firstOrNull;
    return Column(
      children: [
        if (_branches.isNotEmpty) _branchPicker(),
        if (viewing != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.compare_arrows, size: 20),
            title: Text('Changes on ${viewing.name}'),
            subtitle: Text('since it parted from $_branch'),
            onTap: () => _show(
              repo,
              key: '${repo.root}:HEAD...${viewing.ref}',
              title: '${viewing.name} · diff',
              subtitle: 'since it parted from $_branch',
              read: () => repo.compare(viewing.ref),
            ),
          ),
        Expanded(
          child: _log.isEmpty
              ? const _Message(text: 'No commits yet')
              : ListView.builder(
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
                      subtitle: Text(
                        '${commit.author} · ${commit.when} · ${commit.sha}',
                      ),
                      onTap: () => _show(
                        repo,
                        key: '${repo.root}:${commit.sha}',
                        title: '${commit.sha} · diff',
                        subtitle: commit.subject,
                        read: () => repo.show(commit.sha),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Which branch's commits History lists. It sits here rather than on the
  /// branch in the header, which is the checkout: Changes and the commit box
  /// act on that one whatever is being looked at, and the header must go on
  /// saying so. Picking a branch only reads it — a checkout would change the
  /// files under whatever runs on the host, and refuse or lose work while
  /// there are changes.
  Widget _branchPicker() {
    final checkedOut = _branches.where((b) => b.current).firstOrNull;
    // A detached head has no branch to stand for it, so it gets an entry of
    // its own, named by its sha, to come back to.
    const detached = '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Row(
        children: [
          const Icon(Icons.call_split, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _viewing ?? checkedOut?.ref ?? detached,
                items: [
                  if (checkedOut == null)
                    DropdownMenuItem(
                      value: detached,
                      child: Text('$_branch (checked out)'),
                    ),
                  for (final b in _branches)
                    DropdownMenuItem(
                      value: b.ref,
                      child: Text(
                        b.current ? '${b.name} (checked out)' : b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (ref) => _view(
                  ref == null || ref == detached || ref == checkedOut?.ref
                      ? null
                      : ref,
                ),
              ),
            ),
          ),
        ],
      ),
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
