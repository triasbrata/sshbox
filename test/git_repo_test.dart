import 'package:flutter_test/flutter_test.dart';
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
}
