import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_split.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  test('TuiTabGroups join leave flip slots', () {
    final groups = TuiTabGroups();
    groups.join('b', 'a');
    expect(groups.of('a')!.ids, ['a', 'b']);
    expect(groups.slots(['a', 'b', 'c']), [groups.of('a'), 'c']);

    groups.flip(groups.of('a')!);
    expect(groups.of('a')!.stacked, isTrue);

    groups.leave('b');
    expect(groups.of('a'), isNull);
    expect(groups.slots(['a', 'b', 'c']), ['a', 'b', 'c']);
  });

  testWidgets('split view outlines focused pane', (tester) async {
    String? focused = 'a';
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 240,
            child: StatefulBuilder(
              builder: (context, setState) {
                return TuiSplitView(
                  axis: TuiSplitAxis.horizontal,
                  focusedId: focused,
                  onFocus: (id) => setState(() => focused = id),
                  panes: const [
                    TuiSplitPane(id: 'a', child: Text('pane-a')),
                    TuiSplitPane(id: 'b', child: Text('pane-b')),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('pane-a'), findsOneWidget);
    expect(find.text('pane-b'), findsOneWidget);
    await tester.tap(find.text('pane-b'));
    await tester.pump();
    expect(focused, 'b');
  });

  testWidgets('group chip shows members and flip', (tester) async {
    var stacked = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return TuiTabGroupChip(
                stacked: stacked,
                active: true,
                onFlip: () => setState(() => stacked = !stacked),
                children: const [
                  TuiTabChip(label: 'shell', selected: true),
                  TuiTabChip(label: 'files'),
                ],
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('shell'), findsOneWidget);
    expect(find.text('files'), findsOneWidget);
    expect(find.text('▥'), findsOneWidget);

    await tester.tap(find.text('▥'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stacked'));
    await tester.pumpAndSettle();
    expect(find.text('☰'), findsOneWidget);
  });

  testWidgets('fromGroup builds panes from TuiTabGroup', (tester) async {
    final group = TuiTabGroup(['x', 'y'], focused: 'x');
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 200,
            child: TuiSplitView.fromGroup(
              group: group,
              pages: const {'x': Text('X'), 'y': Text('Y')},
            ),
          ),
        ),
      ),
    );
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Y'), findsOneWidget);
  });
}
