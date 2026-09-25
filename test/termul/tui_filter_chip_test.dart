import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_filter_chip.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(8), child: child),
        ),
      ),
    );
  }

  testWidgets('multi-select toggles membership', (tester) async {
    var selected = <String>{'a'};
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiFilterChips<String>(
            selected: selected,
            onChanged: (s) => setState(() => selected = s),
            options: const [
              TuiFilterOption(value: 'a', label: 'A', count: 3),
              TuiFilterOption(value: 'b', label: 'B', count: 1),
            ],
          );
        },
      ),
    );

    expect(find.text('A'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(selected, {'a', 'b'});

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(selected, {'b'});
  });

  testWidgets('exclusive keeps one selection', (tester) async {
    var selected = <String>{'a'};
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiFilterChips<String>(
            exclusive: true,
            selected: selected,
            onChanged: (s) => setState(() => selected = s),
            options: const [
              TuiFilterOption(value: 'a', label: 'A'),
              TuiFilterOption(value: 'b', label: 'B'),
            ],
          );
        },
      ),
    );

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(selected, {'b'});
  });

  testWidgets('allowEmpty false blocks last deselect', (tester) async {
    var selected = <String>{'a'};
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiFilterChips<String>(
            allowEmpty: false,
            selected: selected,
            onChanged: (s) => setState(() => selected = s),
            options: const [
              TuiFilterOption(value: 'a', label: 'A'),
              TuiFilterOption(value: 'b', label: 'B'),
            ],
          );
        },
      ),
    );

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(selected, {'a'});
  });

  testWidgets('standalone chip fires onSelected', (tester) async {
    var on = false;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiFilterChip(
            label: 'Tables',
            count: 12,
            selected: on,
            onSelected: (v) => setState(() => on = v),
          );
        },
      ),
    );
    await tester.tap(find.text('Tables'));
    await tester.pump();
    expect(on, isTrue);
    expect(find.text('✓'), findsOneWidget);
  });
}
