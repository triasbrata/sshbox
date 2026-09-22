import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_tooltip.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, {required Widget under}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        home: Scaffold(body: Center(child: under)),
      ),
    );
  }

  testWidgets('long-press shows tooltip message', (tester) async {
    await pumpHost(
      tester,
      under: TuiTooltip(message: 'Settings', child: const Text('gear')),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('gear')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Settings'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('hover shows tooltip after wait', (tester) async {
    await pumpHost(
      tester,
      under: TuiTooltip(
        message: 'Close tab',
        waitDuration: const Duration(milliseconds: 100),
        child: const Text('x-btn'),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.text('x-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Close tab'), findsOneWidget);
  });

  testWidgets('TuiIconButton exposes tooltip and fires onPressed', (
    tester,
  ) async {
    var tapped = false;
    await pumpHost(
      tester,
      under: TuiIconButton(
        icon: '⚙',
        tooltip: 'Settings',
        onPressed: () => tapped = true,
      ),
    );

    expect(find.text('⚙'), findsOneWidget);
    await tester.tap(find.text('⚙'));
    expect(tapped, isTrue);

    final gesture = await tester.startGesture(tester.getCenter(find.text('⚙')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Settings'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('empty message skips wrapping', (tester) async {
    await pumpHost(
      tester,
      under: const TuiTooltip(message: '  ', child: Text('bare')),
    );

    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('bare'), findsOneWidget);
  });

  testWidgets('tuiTooltipTheme matches Termul look', (tester) async {
    final theme = tuiTooltipTheme(TermulPalette.paper);
    expect(theme.waitDuration, tuiTooltipWait);
    expect(theme.textStyle?.fontFamily, TermulFonts.mono);
    expect(
      (theme.decoration as BoxDecoration?)?.color,
      TermulPalette.paper.deep,
    );
  });
}
