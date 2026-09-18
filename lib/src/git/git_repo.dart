import 'dart:async';

import 'package:flutter/foundation.dart';

/// Runs a command wherever the session runs — over SSH for a saved host, in a
/// process beside the app for a local shell — and hands back its output a line
/// at a time, as `CommandCapable.run` does.
typedef GitRunner = Stream<String> Function(String command);

/// What git said when it would not do what was asked. Carries git's own words
/// rather than a message of ours: "nothing to commit, working tree clean" and
/// "Your branch is behind" are what the user needs to read.
class GitException implements Exception {
  const GitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How a file stands in a repository, as git's short status writes it: one
/// letter for the index and one for the working tree.
enum GitChange {
  added('A', 'Added'),
  modified('M', 'Modified'),
  deleted('D', 'Deleted'),
  renamed('R', 'Renamed'),
  copied('C', 'Copied'),
  untracked('?', 'Untracked'),
  conflicted('U', 'Conflicted');

  const GitChange(this.code, this.label);

  final String code;
  final String label;

  static GitChange? of(String code) {
    for (final change in values) {
      if (change.code == code) return change;
    }
    return null;
  }
}

/// One path git has something to say about, and what it says about the index
/// and the working tree separately — the same file can be both staged and
/// changed again since, which is why these are two fields and not one.
typedef GitStatusEntry = ({
  String path,
  GitChange? staged,
  GitChange? worktree,
});

/// One commit, as the History tab lists it.
typedef GitCommitEntry = ({
  String sha,
  String subject,
  String author,
  String when,
});

/// A git repository reached through a session's shell.
///
/// Every command is `git -C <root>`, so nothing depends on where the shell
/// happens to be standing, and a command run here never changes that.
class GitRepo {
  const GitRepo({required this.root, required this.run});

  /// The repository's top level, absolute on the host.
  final String root;

  /// How a command reaches the host this repository is on.
  final GitRunner run;

  /// The last path segment, which is what the picker shows.
  String get name {
    final trimmed = root.endsWith('/')
        ? root.substring(0, root.length - 1)
        : root;
    final cut = trimmed.lastIndexOf('/');
    return cut == -1 ? trimmed : trimmed.substring(cut + 1);
  }

  /// Runs one git command and returns everything it wrote, stdout and stderr
  /// together, with a non-zero exit turned into a [GitException].
  ///
  /// The exit status comes back as a line of its own after the output, because
  /// `run` carries only what the command wrote — there is no status in the
  /// stream itself. `--no-pager` because a host whose git is configured to
  /// page would otherwise sit waiting for a terminal that is not there.
  Future<String> _git(List<String> arguments) async {
    final command =
        'git --no-pager -C ${_quote(root)} '
        '${arguments.map(_quote).join(' ')} 2>&1; '
        'printf "$_status%s\\n" "\$?"';
    final lines = await run(command).toList();
    var status = -1;
    final output = <String>[];
    for (final line in lines) {
      if (line.startsWith(_status)) {
        status = int.tryParse(line.substring(_status.length).trim()) ?? -1;
        continue;
      }
      output.add(line);
    }
    final text = output.join('\n').trimRight();
    if (status != 0) {
      throw GitException(
        text.trim().isEmpty ? 'git exited with status $status.' : text.trim(),
      );
    }
    return text;
  }

  /// Marks the exit status line. Long and unlikely enough that a file's own
  /// contents cannot be mistaken for it.
  static const _status = '__jeansh_git_status:';

  /// The branch checked out, or the short sha when the head is detached.
  Future<String> branch() async {
    final name = await _git(['rev-parse', '--abbrev-ref', 'HEAD']);
    if (name.trim() != 'HEAD') return name.trim();
    return (await _git(['rev-parse', '--short', 'HEAD'])).trim();
  }

  /// Every path git has something to say about, staged and unstaged alike.
  ///
  /// `--porcelain=v1` rather than the human format: it is promised not to
  /// change between git versions, and it says the index and the working tree
  /// in two columns, which is what the two lists on the page are.
  Future<List<GitStatusEntry>> status() async {
    final text = await _git(['status', '--porcelain=v1', '--untracked-files']);
    final entries = <GitStatusEntry>[];
    for (final line in text.split('\n')) {
      if (line.length < 4) continue;
      final index = line.substring(0, 1);
      final worktree = line.substring(1, 2);
      var path = line.substring(3);
      // A rename is written `old -> new`; the new name is the one to show and
      // the one every other command takes.
      final arrow = path.indexOf(' -> ');
      if (arrow != -1) path = path.substring(arrow + 4);
      entries.add((
        path: path,
        staged: GitChange.of(index),
        worktree: GitChange.of(worktree),
      ));
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return entries;
  }

  /// The diff of one path: what is staged for it, or what is not.
  ///
  /// An untracked file has nothing to diff against, so it is shown as an
  /// addition of the whole file, which is what committing it would record.
  Future<String> diff(String path, {required bool staged}) async {
    if (!staged) {
      final tracked = await _tracked(path);
      if (!tracked) {
        return _git(['diff', '--no-index', '--', '/dev/null', path]).catchError(
          // `--no-index` exits 1 whenever the two differ, which is always here.
          (Object error) => error is GitException ? error.message : '',
        );
      }
    }
    return _git(['diff', if (staged) '--staged', '--', path]);
  }

  Future<bool> _tracked(String path) async {
    try {
      await _git(['ls-files', '--error-unmatch', '--', path]);
      return true;
    } on GitException {
      return false;
    }
  }

  /// The newest commits first, as the History tab lists them.
  Future<List<GitCommitEntry>> log({int limit = 50}) async {
    final text = await _git([
      'log',
      '--max-count=$limit',
      // Tabs, because a subject can hold anything else.
      '--pretty=format:%h\t%an\t%ar\t%s',
    ]);
    final commits = <GitCommitEntry>[];
    for (final line in text.split('\n')) {
      final parts = line.split('\t');
      if (parts.length < 4) continue;
      commits.add((
        sha: parts[0],
        author: parts[1],
        when: parts[2],
        subject: parts.sublist(3).join('\t'),
      ));
    }
    return commits;
  }

  /// What one commit changed, as its own diff.
  Future<String> show(String sha) =>
      _git(['show', '--stat', '--patch', '--format=%s%n%n%an, %ar%n', sha]);

  Future<void> stage(String path) => _git(['add', '--', path]);

  /// Takes a path back out of the index, leaving the working tree alone.
  Future<void> unstage(String path) =>
      _git(['restore', '--staged', '--', path]);

  Future<void> stageAll() => _git(['add', '--all']);

  /// Commits what is staged. Nothing staged is git's own error, and it says
  /// so in words worth showing.
  Future<String> commit(String message) async {
    if (message.trim().isEmpty) {
      throw const GitException('A commit needs a message.');
    }
    return _git(['commit', '--message', message]);
  }

  /// Single quotes suspend every expansion the shell does; the dance in the
  /// middle is how a single quote itself gets through.
  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}

/// The repositories a session can see, and which one the page is looking at.
///
/// Discovery is deliberately shallow: the repository the session's own folder
/// is in, and the ones checked out inside it — a monorepo's packages, or a
/// folder of projects, the way Zed lists them. Anything deeper is a find that
/// walks a whole home directory over SSH, which is not worth the wait.
class GitRepos extends ChangeNotifier {
  GitRepos({required this.run, required this.start});

  /// How a command reaches the host these repositories are on.
  final GitRunner run;

  /// Where the search begins: the host's file tree root, else [loginHome].
  final String start;

  /// The login home, for a host with no file tree root of its own.
  ///
  /// It stays a shell word rather than a path because only the host knows
  /// where its home is. [_roots] is what keeps it one: quoting it the way a
  /// path is quoted would send `cd '$HOME'`, which is a folder with a dollar
  /// in its name, and the search would find nothing on every host that has
  /// no root set.
  static const loginHome = r'$HOME';

  List<GitRepo> _repos = const [];
  List<GitRepo> get repos => _repos;

  GitRepo? _selected;
  GitRepo? get selected => _selected;

  /// Null until the first [discover], then git's reason when there is none to
  /// show: no git on the host, or nothing checked out under [start].
  String? _problem;
  String? get problem => _problem;

  bool _loading = false;
  bool get loading => _loading;

  /// Closing the git tab disposes this while the page that draws it is still
  /// listening: the session notifies as the tab goes, the page hears it and
  /// asks for another search, and a [ChangeNotifier] used after disposal
  /// throws. Every way in checks this rather than the page having to know how
  /// it was torn down.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void select(GitRepo repo) {
    if (_disposed) return;
    if (_selected?.root == repo.root) return;
    _selected = repo;
    notifyListeners();
  }

  /// Finds the repositories and keeps the one already picked if it is still
  /// among them — a rediscovery after a commit must not throw the user back
  /// to the first repo in the list.
  Future<void> discover() async {
    if (_disposed || _loading) return;
    _loading = true;
    _problem = null;
    notifyListeners();
    try {
      final roots = await _roots();
      _repos = [for (final root in roots) GitRepo(root: root, run: run)];
      final kept = _selected;
      _selected =
          _repos.where((repo) => repo.root == kept?.root).firstOrNull ??
          _repos.firstOrNull;
      if (_repos.isEmpty) {
        _problem = start == loginHome
            ? 'No git repository in your home folder on this host.'
            : 'No git repository under $start.';
      }
    } on GitException catch (error) {
      _problem = error.message;
      _repos = const [];
      _selected = null;
    } catch (error) {
      _problem = '$error';
      _repos = const [];
      _selected = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// The enclosing repository first, then every `.git` one or two folders
  /// down. `-prune` so a repository's own history is not walked, which is
  /// where the time would go.
  Future<List<String>> _roots() async {
    // Double quotes for the home, which the shell must expand and which may
    // still hold a space; single quotes for a path, which it must not touch.
    final quoted = start == loginHome ? '"$loginHome"' : GitRepo._quote(start);
    final command =
        'cd $quoted 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null; '
        "find $quoted -mindepth 2 -maxdepth 3 -name .git -prune "
        r"-exec dirname {} \; 2>/dev/null";
    final seen = <String>{};
    await for (final line in run(command)) {
      final path = line.trim();
      if (path.isEmpty || !path.startsWith('/')) continue;
      seen.add(path);
    }
    final roots = seen.toList()..sort();
    return roots;
  }
}
