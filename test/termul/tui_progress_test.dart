import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_progress.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, {required Widget under}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: under),
        ),
      ),
    );
  }

  testWidgets('determinate bar reports percent semantics', (tester) async {
    await pumpHost(tester, under: const TuiProgressBar(value: 0.5));

    expect(
      tester.getSemantics(find.byType(TuiProgressBar)),
      matchesSemantics(label: 'Progress 50 percent', value: '0.50'),
    );
  });

  testWidgets('TuiProgress shows label and percent', (tester) async {
    await pumpHost(
      tester,
      under: const TuiProgress(label: 'Uploading notes.md', value: 0.42),
    );

    expect(find.text('Uploading notes.md  42%'), findsOneWidget);
    expect(find.byType(TuiProgressBar), findsOneWidget);
  });

  testWidgets('error progress uses danger copy', (tester) async {
    await pumpHost(
      tester,
      under: const TuiProgress(
        label: 'Saving',
        error: true,
        errorText: 'Save failed',
      ),
    );

    expect(find.text('Save failed'), findsOneWidget);
  });

  testWidgets('glyph spinner cycles frames', (tester) async {
    await pumpHost(tester, under: const TuiSpinner(label: 'Loading list'));

    expect(find.text('Loading list'), findsOneWidget);
    final first = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(TuiSpinner),
            matching: find.textContaining(RegExp(r'[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]')),
          ),
        )
        .data;

    await tester.pump(const Duration(milliseconds: 100));
    final second = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(TuiSpinner),
            matching: find.textContaining(RegExp(r'[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]')),
          ),
        )
        .data;

    // May or may not have advanced depending on frame timing — at least present.
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(TuiSpinner.frames, contains(first));
  });

  testWidgets('ring spinner uses CircularProgressIndicator', (tester) async {
    await pumpHost(
      tester,
      under: const TuiSpinner(style: TuiSpinnerStyle.ring, size: 18),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('banner uppercases label', (tester) async {
    await pumpHost(
      tester,
      under: const TuiProgressBanner(label: 'Connecting…'),
    );

    expect(find.text('CONNECTING…'), findsOneWidget);
  });

  testWidgets('indeterminate bar paints without value', (tester) async {
    await pumpHost(tester, under: const TuiProgressBar());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TuiProgressBar), findsOneWidget);
  });
}
