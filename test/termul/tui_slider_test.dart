import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_slider.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: 280, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('slider reports drag value', (tester) async {
    var value = 12.0;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiSlider(
            label: 'Font size',
            value: value,
            min: 9,
            max: 24,
            divisions: 15,
            valueLabel: '${value.round()}px',
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    expect(find.text('12px'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('tui-slider-track')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    expect(value, greaterThan(12));
    expect(find.text('${value.round()}px'), findsOneWidget);
  });

  testWidgets('slider disabled ignores input', (tester) async {
    const value = 16.0;
    await pumpHost(
      tester,
      const TuiSlider(
        label: 'Locked',
        value: value,
        min: 9,
        max: 24,
        valueLabel: '16px',
        onChanged: null,
      ),
    );
    await tester.drag(
      find.byKey(const Key('tui-slider-track')),
      const Offset(120, 0),
    );
    await tester.pump();
    expect(find.text('16px'), findsOneWidget);
  });

  testWidgets('stepper increments and decrements', (tester) async {
    var value = 13.0;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiStepper(
            label: 'Editor',
            value: value,
            min: 9,
            max: 24,
            step: 1,
            valueLabel: '${value.round()}px',
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    await tester.tap(find.text('+'));
    await tester.pump();
    expect(value, 14);

    await tester.tap(find.text('−'));
    await tester.pump();
    expect(value, 13);
  });

  testWidgets('stepper clamps at min and max', (tester) async {
    var value = 9.0;
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiStepper(
            value: value,
            min: 9,
            max: 11,
            step: 1,
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    await tester.tap(find.text('−'));
    await tester.pump();
    expect(value, 9);

    await tester.tap(find.text('+'));
    await tester.pump();
    expect(value, 10);
    await tester.tap(find.text('+'));
    await tester.pump();
    expect(value, 11);
    await tester.tap(find.text('+'));
    await tester.pump();
    expect(value, 11);
  });
}
