import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_checkbox.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  testWidgets('toggles checked state', (tester) async {
    var on = false;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiCheckbox(
            label: 'Active',
            value: on,
            onChanged: (v) => setState(() => on = v ?? false),
          );
        },
      ),
    );

    expect(find.text('✓'), findsNothing);
    await tester.tap(find.text('Active'));
    await tester.pump();
    expect(on, isTrue);
    expect(find.text('✓'), findsOneWidget);
  });

  testWidgets('tristate cycles', (tester) async {
    bool? value = false;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiCheckbox(
            label: 'All',
            value: value,
            tristate: true,
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(value, isTrue);

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(value, isNull);
    expect(find.text('✓'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(value, isFalse);
  });

  testWidgets('disabled ignores taps', (tester) async {
    var on = true;
    await pumpHost(
      tester,
      TuiCheckbox(label: 'Locked', value: on, onChanged: null),
    );
    await tester.tap(find.text('Locked'));
    await tester.pump();
    expect(on, isTrue);
    expect(find.text('✓'), findsOneWidget);
  });

  testWidgets('checkbox row lays out child', (tester) async {
    var on = true;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiCheckboxRow(
            value: on,
            onChanged: (v) => setState(() => on = v ?? false),
            child: const Text('status = open'),
          );
        },
      ),
    );
    expect(find.text('status = open'), findsOneWidget);
    await tester.tap(find.text('✓'));
    await tester.pump();
    expect(on, isFalse);
  });
}
