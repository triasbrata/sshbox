import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/git/git_diff.dart';
import 'package:sshbox/src/git/git_repo.dart';

/// A host that answers each command from a script, and remembers what it was
/// asked. Every answer ends the way the real one does: the status line the
/// repo reads the exit code from.
class _Host {
  _Host(this.answers);

  /// What to say, by the first git subcommand in the command line — or
  /// `find`, for the discovery pass.
  final Map<String, ({List<String> lines, int status})> answers;

  final asked = <String>[];

  Stream<String> run(String command) async* {
    asked.add(command);
    final answer = answers.entries
        .where((entry) => command.contains(entry.key))
        .firstOrNull
        ?.value;
    for (final line in answer?.lines ?? const <String>[]) {
      yield line;
    }
    // The discovery command has no status line of its own: it is read as
    // plain output, so a script for it says so with a negative status.
    if ((answer?.status ?? 0) >= 0) {
      yield '__jeansh_git_status:${answer?.status ?? 0}';
    }
  }
}

void main() {
  group('status', () {
    test('reads the index and the working tree as two columns', () async {
      final host = _Host({
        'porcelain': (
          lines: [
            'M  lib/a.dart',
            ' M lib/b.dart',
            'MM lib/c.dart',
            '?? notes.txt',
            'D  gone.txt',
          ],
          status: 0,
        ),
      });
      final repo = GitRepo(root: '/home/me/app', run: host.run);

      final status = await repo.status();

      expect(status.map((entry) => entry.path), [
        'gone.txt',
        'lib/a.dart',
        'lib/b.dart',
        'lib/c.dart',
        'notes.txt',
      ]);
      // Staged only.
      final a = status.firstWhere((entry) => entry.path == 'lib/a.dart');
      expect(a.staged, GitChange.modified);
      expect(a.worktree, isNull);
      // Changed since it was staged: both columns, which is why the same path
      // can show in both lists.
      final c = status.firstWhere((entry) => entry.path == 'lib/c.dart');
      expect(c.staged, GitChange.modified);
      expect(c.worktree, GitChange.modified);
      // Untracked is a working-tree change and nothing in the index.
      final notes = status.firstWhere((entry) => entry.path == 'notes.txt');
      expect(notes.staged, GitChange.untracked);
      expect(notes.worktree, GitChange.untracked);
    });

    test('names a rename by where it landed', () async {
      final host = _Host({
        'porcelain': (lines: ['R  old.dart -> new.dart'], status: 0),
      });
      final repo = GitRepo(root: '/app', run: host.run);

      final status = await repo.status();

      expect(status.single.path, 'new.dart');
      expect(status.single.staged, GitChange.renamed);
    });

    test('runs against the root, wherever the shell is standing', () async {
      final host = _Host({'status --porcelain': (lines: const [], status: 0)});
      final repo = GitRepo(root: "/home/me/it's mine", run: host.run);

      await repo.status();

      // Quoted, so a space or an apostrophe in the path is still one word.
      expect(host.asked.single, contains(r"-C '/home/me/it'\''s mine'"));
      expect(host.asked.single, contains('--no-pager'));
    });
  });

  group('what git refuses', () {
    test('comes back in git\'s own words', () async {
      final host = _Host({
        'commit': (lines: ['nothing to commit, working tree clean'], status: 1),
      });
      final repo = GitRepo(root: '/app', run: host.run);

      await expectLater(
        repo.commit('a message'),
        throwsA(
          isA<GitException>().having(
            (error) => error.message,
            'message',
            'nothing to commit, working tree clean',
          ),
        ),
      );
    });

    test('a commit with no message never reaches the host', () async {
      final host = _Host(const {});
      final repo = GitRepo(root: '/app', run: host.run);

      await expectLater(repo.commit('  '), throwsA(isA<GitException>()));
      expect(host.asked, isEmpty);
    });
  });

  test('a history whose last line has no newline still reads, through a '
      'real shell', () async {
    // The scripted host above always puts the status marker on a line of its
    // own, which a real shell does not promise: git log --pretty=format:
    // ends its last commit with no newline, and the marker used to land on
    // that line and never be found. So this one runs the very command the
    // repo builds, through sh, with a git that answers as that git does.
    final bin = await Directory.systemTemp.createTemp('git-shell');
    addTearDown(() => bin.delete(recursive: true));
    final git = File('${bin.path}/git')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        r"printf 'c470bf5\tAda\t2 days ago\tfix wrong path\n"
        r"454e7f5\tAda\t3 days ago\tfirst'"
        '\n',
      );
    await Process.run('chmod', ['+x', git.path]);

    Stream<String> run(String command) async* {
      final process = await Process.start(
        'sh',
        ['-c', command],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      yield* process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
    }

    final log = await GitRepo(root: '/app', run: run).log();

    expect(log.map((commit) => commit.sha), ['c470bf5', '454e7f5']);
    expect(log.last.subject, 'first');
  });

  test('the history is read a commit to a line', () async {
    final host = _Host({
      'log': (
        lines: [
          'c470bf5\tTrias\t9 months ago\tfix wrong path',
          '454e7f5\tTrias\t9 months ago\tadd read database\twith a tab in it',
        ],
        status: 0,
      ),
    });
    final repo = GitRepo(root: '/app', run: host.run);

    final log = await repo.log();

    expect(log.first.sha, 'c470bf5');
    expect(log.first.subject, 'fix wrong path');
    expect(log.first.author, 'Trias');
    expect(log.first.when, '9 months ago');
    // A subject may hold the separator; only the first three fields are
    // fixed.
    expect(log.last.subject, 'add read database\twith a tab in it');
  });

  group('finding the repositories', () {
    test('takes the enclosing one and the ones checked out inside', () async {
      final host = _Host({
        'find': (
          lines: [
            '/home/me/work',
            '/home/me/work/packages/api',
            '/home/me/work/packages/web',
          ],
          status: -1,
        ),
      });
      final repos = GitRepos(run: host.run, start: '/home/me/work');

      await repos.discover();

      expect(repos.repos.map((repo) => repo.name), ['work', 'api', 'web']);
      expect(repos.selected?.root, '/home/me/work');
      expect(repos.problem, isNull);
    });

    test('keeps the repository already picked across a second look', () async {
      final host = _Host({
        'find': (lines: ['/w', '/w/a', '/w/b'], status: -1),
      });
      final repos = GitRepos(run: host.run, start: '/w');
      await repos.discover();
      repos.select(repos.repos.firstWhere((repo) => repo.root == '/w/b'));

      await repos.discover();

      expect(repos.selected?.root, '/w/b');
    });

    test('says so when the host has none', () async {
      final host = _Host({'find': (lines: const [], status: -1)});
      final repos = GitRepos(run: host.run, start: '/home/me');

      await repos.discover();

      expect(repos.repos, isEmpty);
      expect(repos.problem, contains('/home/me'));
    });

    test(
      'lets the shell expand the login home, rather than quoting it',
      () async {
        final host = _Host({
          'find': (lines: ['/root/app'], status: -1),
        });
        final repos = GitRepos(run: host.run, start: GitRepos.loginHome);

        await repos.discover();

        // Single quotes would send the shell a folder with a dollar in its
        // name, and nothing would ever be found on a host with no root set.
        expect(host.asked.single, contains(r'"$HOME"'));
        expect(host.asked.single, isNot(contains(r"'$HOME'")));
        expect(repos.repos.single.root, '/root/app');
      },
    );

    test('asks nothing more once the tab that owned it has gone', () async {
      final host = _Host({
        'find': (lines: ['/w'], status: -1),
      });
      final repos = GitRepos(run: host.run, start: '/w');
      await repos.discover();
      final asked = host.asked.length;

      // Closing the git tab disposes it while the page is still listening,
      // and the page's own listener asks for one more search on the way out.
      repos.dispose();

      await repos.discover();
      expect(host.asked, hasLength(asked));
    });
  });

  /// A real git, in a folder of its own, run the way a host runs it: every
  /// command the repo builds goes through sh, so what is proved is what the
  /// shell does with it and not what its text looks like.
  group('on a real git, through a real shell', () {
    late Directory sandbox;
    late Map<String, String> env;

    /// A folder name holding what a shell reads: a quote, a command
    /// substitution, a backtick and a semicolon. Anything that reaches sh
    /// unquoted leaves a file called pwned behind.
    const nasty = r"it's $(touch>pwned) `touch>pwned2`; x";

    Future<void> git(String dir, List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: dir,
        environment: env,
      );
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')}: ${result.stderr}');
      }
    }

    Stream<String> run(String command) async* {
      final process = await Process.start(
        'sh',
        ['-c', command],
        workingDirectory: sandbox.path,
        environment: env,
      );
      yield* process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
    }

    /// Whatever the shell was tricked into making, anywhere in the sandbox.
    List<String> planted() => [
      for (final entity in sandbox.listSync(recursive: true))
        if (entity.path.split('/').last.startsWith('pwned')) entity.path,
    ];

    setUp(() async {
      // Resolved, because git answers with real paths: a Mac's temp folder is
      // reached through a link, and the paths would never compare equal.
      final temp = await Directory.systemTemp.createTemp('git-real');
      sandbox = Directory(await temp.resolveSymbolicLinks());
      // None of this machine's own config: no hooks, no signing.
      env = {
        'HOME': sandbox.path,
        'XDG_CONFIG_HOME': sandbox.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_AUTHOR_NAME': 'Ada',
        'GIT_AUTHOR_EMAIL': 'ada@example.com',
        'GIT_COMMITTER_NAME': 'Ada',
        'GIT_COMMITTER_EMAIL': 'ada@example.com',
      };
    });

    tearDown(() => sandbox.delete(recursive: true));

    /// A repository with one commit on main.
    Future<String> repository(String path) async {
      await Directory(path).create(recursive: true);
      await git(path, ['init', '--quiet', '--initial-branch=main']);
      await git(path, ['commit', '--quiet', '--allow-empty', '-m', 'first']);
      return path;
    }

    test('finds every worktree of a repository, nested deep or outside the '
        'folder, and leaves out one whose folder is gone', () async {
      final base = '${sandbox.path}/$nasty';
      final proj = await repository('$base/proj');
      // Where Claude Code puts them: .git four levels below the repository,
      // one deeper than the search looks.
      await git(proj, [
        'worktree',
        'add',
        '--quiet',
        '-b',
        'agent',
        '.claude/worktrees/agent-x',
      ]);
      // Where `git worktree add ../x` puts them: beside the repository, and
      // outside the folder being browsed altogether.
      final side = '$base/side $nasty';
      await git(proj, ['worktree', 'add', '--quiet', '-b', 'side', side]);
      // A worktree deleted by hand and never pruned: git still lists it, and
      // picking it could only fail.
      await git(proj, [
        'worktree',
        'add',
        '--quiet',
        '-b',
        'gone',
        '$base/gone',
      ]);
      await Directory('$base/gone').delete(recursive: true);

      final repos = GitRepos(run: run, start: proj);
      await repos.discover();

      expect(repos.problem, isNull);
      expect(repos.repos.map((repo) => repo.root), [
        proj,
        '$proj/.claude/worktrees/agent-x',
        side,
      ]);
      expect(repos.repos.map((repo) => repo.mainRoot), [null, proj, proj]);
      expect(repos.selected?.root, proj);
      // Each one answers as the checkout it is.
      expect(await repos.repos.last.branch(), 'side');
      expect(planted(), isEmpty);
    });

    test('starts on the worktree the session is in, not on its '
        'repository', () async {
      final proj = await repository('${sandbox.path}/proj');
      final agent = '$proj/.claude/worktrees/agent-x';
      await git(proj, ['worktree', 'add', '--quiet', '-b', 'agent', agent]);

      final repos = GitRepos(run: run, start: agent);
      await repos.discover();

      expect(repos.repos.map((repo) => repo.root), [proj, agent]);
      expect(repos.selected?.root, agent);
    });

    test('shows a branch it is not on, however the branch is named, and '
        'changes nothing on disk', () async {
      final proj = await repository('${sandbox.path}/proj');
      // A quote, a command substitution, a backtick and a semicolon: every
      // one of them allowed in a branch name.
      const evil = r"q'$(touch>pwned)`touch>pwned2`;x";
      await git(proj, ['switch', '--quiet', '-c', evil]);
      File('$proj/evil.txt').writeAsStringSync('from the evil branch\n');
      await git(proj, ['add', 'evil.txt']);
      await git(proj, ['commit', '--quiet', '-m', 'on the evil branch']);
      await git(proj, ['switch', '--quiet', 'main']);
      // Named like an option. `git branch` refuses a leading dash, update-ref
      // does not, and `git log --output=` writes wherever it is told.
      await git(proj, ['update-ref', 'refs/heads/--output=pwned3', 'HEAD']);

      final repo = GitRepo(root: proj, run: run);
      final branches = await repo.branches();

      expect(branches.map((branch) => branch.name), [
        '--output=pwned3',
        'main',
        evil,
      ]);
      expect(branches.where((branch) => branch.current).single.name, 'main');

      final bad = branches.firstWhere((branch) => branch.name == evil);
      expect((await repo.log(ref: bad.ref)).map((commit) => commit.subject), [
        'on the evil branch',
        'first',
      ]);
      expect(await repo.compare(bad.ref), contains('+from the evil branch'));

      final option = branches.first;
      expect((await repo.log(ref: option.ref)).single.subject, 'first');

      // Looked at, not checked out: the branch and the files are as they
      // were, and the shell made nothing it was not asked to.
      expect(await repo.branch(), 'main');
      expect(File('$proj/evil.txt').existsSync(), isFalse);
      expect(planted(), isEmpty);
    });

    test('every kind of diff reads as git\'s plain format whatever the host '
        'config says, and its old blob holds the lines around its hunks, '
        'however the file is named', () async {
      final proj = await repository('${sandbox.path}/$nasty/proj');
      const name = r"it's $(touch>pwned) `touch>pwned2`; x.kt";
      final file = File('$proj/$name');
      final lines = [for (var n = 1; n <= 40; n++) 'line $n'];
      void write() => file.writeAsStringSync('${lines.join('\n')}\n');
      write();
      await git(proj, ['add', '--', name]);
      await git(proj, ['commit', '--quiet', '-m', 'forty lines']);

      // Everything a host's config can do to a diff that the tab could not
      // read: colour codes, i/ and w/ where a/ and b/ go, and an external
      // tool — this one leaves a file behind if it is ever run.
      await git(proj, ['config', 'color.ui', 'always']);
      await git(proj, ['config', 'diff.mnemonicPrefix', 'true']);
      await git(proj, ['config', 'diff.external', 'touch pwned-by-ext']);

      // Line 20 changed and staged, then line 30 changed on top of it.
      lines[19] = 'line 20, staged';
      write();
      await git(proj, ['add', '--', name]);
      lines[29] = 'line 30, not staged';
      write();

      final repo = GitRepo(root: proj, run: run);

      /// The one file of [text], checked the way the tab relies on it: its
      /// kept lines are the old blob's lines at the same numbers.
      Future<List<String>> old(String text) async {
        expect(text, isNot(contains('\x1b')));
        final diff = parseDiff(text);
        final changed = diff.files.single;
        expect(changed.oldPath, name);
        expect(changed.newPath, name);
        expect(changed.expandable, isTrue);
        // The whole id, not one git abbreviated to what is unique today.
        expect(changed.oldBlob, hasLength(40));
        final blob = (await repo.blob(changed.oldBlob!)).split('\n');
        for (final line in changed.hunks.expand((hunk) => hunk.lines)) {
          if (line.kind == DiffLineKind.context) {
            expect(blob[line.oldNo! - 1], line.text);
          }
        }
        return blob;
      }

      // Unstaged: against the index, which holds the staged line 20.
      final unstaged = await old(await repo.diff(name, staged: false));
      expect(unstaged[19], 'line 20, staged');
      expect(unstaged[29], 'line 30');
      // Staged: against HEAD.
      final staged = await old(await repo.diff(name, staged: true));
      expect(staged[19], 'line 20');

      // A commit: against its parent.
      await git(proj, ['commit', '--quiet', '-m', 'line 20']);
      final sha = (await repo.log()).first.sha;
      final committed = await old(await repo.show(sha));
      expect(committed[19], 'line 20');

      // An untracked file is all new, and has no old side to read.
      File('$proj/new $name').writeAsStringSync('fresh\n');
      final fresh = parseDiff(await repo.diff('new $name', staged: false))
          .files
          .single;
      expect(fresh.isNew, isTrue);
      expect(fresh.path, 'new $name');
      expect(fresh.expandable, isFalse);
      expect(fresh.hunks.single.lines.single.text, 'fresh');

      // An id is held to what an id looks like before it reaches the host.
      await expectLater(
        repo.blob(r"abc'; touch pwned3; '"),
        throwsA(isA<GitException>()),
      );
      await expectLater(
        repo.blob('--output=pwned4'),
        throwsA(isA<GitException>()),
      );

      expect(planted(), isEmpty);
    });
  });
}
