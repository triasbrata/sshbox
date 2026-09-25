import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_toast.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  late BuildContext toastContext;

  Future<void> pumpHost(
    WidgetTester tester, {
    Widget under = const SizedBox.expand(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        builder: (context, child) => TuiToastHost(child: child!),
        home: Builder(
          builder: (context) {
            toastContext = context;
            return under;
          },
        ),
      ),
    );
  }

  Finder card(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(TuiToastCard));

  testWidgets('info toast appears at top and auto-dismisses', (tester) async {
    await pumpHost(tester);
    showTuiToast(
      toastContext,
      title: 'hello',
      duration: const Duration(seconds: 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('hello'), findsOneWidget);
    expect(tester.widget<TuiToastCard>(card('hello')).type, TuiToastType.info);
    expect(tester.getCenter(find.text('hello')).dy, lessThan(120));

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('stacks up to three and dedupes identical copy', (tester) async {
    await pumpHost(tester);
    showTuiToast(
      toastContext,
      title: 'first',
      duration: const Duration(seconds: 5),
    );
    showTuiToast(
      toastContext,
      title: 'second',
      type: TuiToastType.warning,
      duration: const Duration(seconds: 5),
    );
    showTuiToast(
      toastContext,
      title: 'second',
      type: TuiToastType.warning,
      duration: const Duration(seconds: 5),
    );
    await tester.pump();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.byType(TuiToastCard), findsNWidgets(2));
  });

  testWidgets('fourth toast drops the oldest', (tester) async {
    await pumpHost(tester);
    for (var i = 1; i <= 4; i++) {
      showTuiToast(
        toastContext,
        title: 'n$i',
        duration: const Duration(seconds: 10),
      );
    }
    await tester.pump();

    expect(find.text('n4'), findsOneWidget);
    expect(find.text('n3'), findsOneWidget);
    expect(find.text('n2'), findsOneWidget);
    expect(find.text('n1'), findsNothing);
  });

  testWidgets('type is glyph not colour wash; action + close work', (
    tester,
  ) async {
    var tapped = false;
    await pumpHost(tester);
    showTuiToast(
      toastContext,
      title: 'Host key changed',
      body: 'Check the fingerprint.',
      type: TuiToastType.error,
      action: TuiToastAction(label: 'Retry', onPressed: () => tapped = true),
      duration: const Duration(seconds: 30),
    );
    await tester.pump();

    final toast = tester.widget<TuiToastCard>(card('Host key changed'));
    expect(toast.type, TuiToastType.error);
    expect(find.text('x'), findsOneWidget); // error glyph
    expect(find.text('Check the fingerprint.'), findsOneWidget);

    await tester.tap(find.text('RETRY'));
    await tester.pump();
    await tester.pump(); // post-frame action
    expect(tapped, isTrue);
    expect(find.text('Host key changed'), findsNothing);
  });

  testWidgets('close button dismisses early', (tester) async {
    await pumpHost(tester);
    showTuiToast(
      toastContext,
      title: 'Copied',
      type: TuiToastType.success,
      duration: const Duration(seconds: 30),
    );
    await tester.pump();

    await tester.tap(find.text('×'));
    await tester.pump();
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('card alone renders with external progress', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: const Scaffold(
          body: Center(
            child: TuiToastCard(
              title: 'Static',
              body: 'No timer',
              type: TuiToastType.success,
              progress: 0.4,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Static'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
  });

  testWidgets('taps beside the toast reach content underneath', (tester) async {
    var hit = false;
    await pumpHost(
      tester,
      under: GestureDetector(
        onTap: () => hit = true,
        behavior: HitTestBehavior.opaque,
        child: const SizedBox.expand(child: ColoredBox(color: Colors.white)),
      ),
    );
    showTuiToast(
      toastContext,
      title: 'overlay',
      duration: const Duration(seconds: 30),
    );
    await tester.pump();

    // Tap near the bottom of the screen — outside the toast column.
    await tester.tapAt(const Offset(20, 500));
    expect(hit, isTrue);
  });
}
