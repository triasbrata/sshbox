import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/git/git_repo.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/tab_groups.dart';
import 'package:sshbox/src/ui/termul/tui_button.dart';
import 'package:sshbox/src/ui/termul/tui_filter_chip.dart';
import 'package:sshbox/src/ui/termul/tui_menu.dart';
import 'package:sshbox/src/ui/termul/tui_switch.dart';
import 'package:sshbox/src/ui/termul/tui_tabs.dart';

/// What the log gained since [mark], without timestamps and levels.
List<String> since(int mark) => appLog.current
    .split('\n')
    .skip(mark)
    .map((l) => l.split(' ').skip(2).join(' '))
    .toList();

/// Names a host, a file, a session, a commit and a query could carry, which
/// no line of the log may ever hold.
const hostLabel = 'prod-db.internal.example';
const fileName = 'secrets-2026.env';
const sessionName = 'my-private-session';
const commitMessage = 'fix the payroll export';
const query = 'SELECT ssn FROM people';

Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

class _Run {
  final asked = <String>[];

  Stream<String> call(String command) async* {
    asked.add(command);
    yield '__jeansh_git_status:0';
  }
}

void main() {
  group('taps', () {
    testWidgets('a button is logged by its fixed name, and where it is', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(TuiButton(label: 'Save', logName: 'Save', onPressed: () {})),
      );
      final mark = appLog.length;
      await tester.tap(find.byType(TuiButton));
      expect(since(mark), ['tap Save (app)']);
    });

    testWidgets('a button labelled with a host is logged as a button', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(TuiButton(label: hostLabel, onPressed: () {})),
      );
      final mark = appLog.length;
      await tester.tap(find.byType(TuiButton));
      expect(since(mark), ['tap button (app)']);
    });

    testWidgets('a disabled button logs nothing', (tester) async {
      await tester.pumpWidget(
        app(const TuiButton(label: 'Save', logName: 'Save')),
      );
      final mark = appLog.length;
      await tester.tap(find.byType(TuiButton), warnIfMissed: false);
      expect(since(mark), isEmpty);
    });

    testWidgets('a switch, a chip, a menu item and a tab', (tester) async {
      var on = false;
      await tester.pumpWidget(
        app(
          StatefulBuilder(
            builder: (context, set) => Column(
              children: [
                TuiSwitch(
                  value: on,
                  logName: 'Wrap lines',
                  onChanged: (v) => set(() => on = v),
                ),
                TuiFilterChip(
                  label: fileName,
                  selected: false,
                  onSelected: (_) {},
                ),
                TuiTabs(tabs: [sessionName, 'Two'], index: 0, onChanged: (_) {}),
                TuiMenuButton<int>(
                  entries: const [
                    TuiMenuItem(value: 1, label: hostLabel),
                    TuiMenuItem(value: 2, label: 'Close tab', logName: 'Close tab'),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      var mark = appLog.length;
      await tester.tap(find.byType(TuiSwitch));
      await tester.tap(find.text(fileName));
      await tester.tap(find.text('Two'));
      expect(since(mark), [
        'tap Wrap lines (app)',
        'tap chip (app)',
        'tap tab 2 (app)',
      ]);

      mark = appLog.length;
      await tester.tap(find.byType(TuiMenuButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(hostLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TuiMenuButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close tab'));
      await tester.pumpAndSettle();
      expect(since(mark).where((l) => l.startsWith('tap ')), [
        'tap menu item (app)',
        'tap Close tab (app)',
      ]);
    });

    testWidgets('a key of the bar is its fixed name, a custom one is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          Column(
            children: [
              KeyButton(label: 'ESC', logName: 'ESC', onTap: () {}),
              KeyButton(
                label: 'my-secret-macro',
                logName: 'custom key',
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      final mark = appLog.length;
      await tester.tap(find.text('ESC'));
      await tester.tap(find.text('my-secret-macro'));
      expect(since(mark), ['tap ESC (app)', 'tap custom key (app)']);
    });
  });

  group('actions', () {
    test('git: stage, stage all, unstage, commit and switch', () async {
      final run = _Run();
      final repo = GitRepo(root: '/app', run: run.call);
      final mark = appLog.length;
      await repo.stage(fileName);
      await repo.stageAll();
      await repo.unstage(fileName);
      await repo.commit(commitMessage);
      await repo.switchTo((
        ref: 'refs/heads/$sessionName',
        name: sessionName,
        current: true,
      ));
      expect(since(mark), [
        'action git stage',
        'action git stage all',
        'action git unstage',
        'action git commit',
        'action git switch',
      ]);
    });

    test('tabs: group, take out and ungroup', () {
      final groups = TabGroups();
      final mark = appLog.length;
      groups
        ..join('b', 'a')
        ..join('c', 'a')
        ..leave('c')
        ..ungroup(groups.of('a')!);
      expect(since(mark), [
        'action tab group',
        'action tab group',
        'action tab take out',
        'action tab ungroup',
      ]);
    });
  });

  test('none of the names a host, a file or a commit carry reach the log', () {
    final text = appLog.current;
    for (final secret in [
      hostLabel,
      fileName,
      sessionName,
      commitMessage,
      query,
      'my-secret-macro',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });
}
