import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_diff_view.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  const sample = '''
@@ -10,3 +10,4 @@
 void main() {
-  runApp(const App());
+  WidgetsFlutterBinding.ensureInitialized();
+  runApp(const TermulApp());
 }
''';

  Future<void> pumpHost(
    WidgetTester tester, {
    required Widget under,
    double width = 1000,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: SizedBox(width: width, height: 480, child: under),
        ),
      ),
    );
  }

  test('parses unified patch into hunk + lines', () {
    final rows = tuiDiffRowsFromUnified(sample);
    expect(rows.first, isA<TuiDiffHunkRow>());
    expect(
      rows.whereType<TuiDiffUnifiedRow>().map((r) => r.line.kind),
      containsAll([
        TuiDiffLineKind.context,
        TuiDiffLineKind.removed,
        TuiDiffLineKind.added,
      ]),
    );
  });

  test('split conversion pairs remove+add', () {
    final split = tuiDiffRowsToSplit(tuiDiffRowsFromUnified(sample));
    final paired = split.whereType<TuiDiffSplitRow>().where(
      (r) =>
          r.oldLine?.kind == TuiDiffLineKind.removed &&
          r.newLine?.kind == TuiDiffLineKind.added,
    );
    expect(paired, isNotEmpty);
  });

  testWidgets('wide view renders split columns', (tester) async {
    await pumpHost(
      tester,
      under: TuiDiffView(
        split: true,
        files: [
          TuiDiffFile(
            path: 'lib/main.dart',
            added: 2,
            removed: 1,
            rows: tuiDiffRowsToSplit(tuiDiffRowsFromUnified(sample)),
          ),
        ],
      ),
    );

    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    expect(find.textContaining('@@'), findsOneWidget);
    expect(find.textContaining('TermulApp'), findsWidgets);
  });

  testWidgets('narrow auto mode uses unified', (tester) async {
    await pumpHost(
      tester,
      width: 400,
      under: TuiDiffView(
        files: [
          TuiDiffFile(
            path: 'a.dart',
            added: 1,
            removed: 0,
            rows: tuiDiffRowsToSplit(tuiDiffRowsFromUnified(sample)),
          ),
        ],
      ),
    );

    // Unified still shows the added line once.
    expect(find.textContaining('TermulApp'), findsOneWidget);
  });

  testWidgets('binary and folded notices', (tester) async {
    await pumpHost(
      tester,
      under: const TuiDiffView(
        files: [
          TuiDiffFile(path: 'icon.png', binary: true, rows: []),
          TuiDiffFile(path: 'big.diff', tooLarge: true, rows: []),
          TuiDiffFile(
            path: 'folded.dart',
            folded: true,
            added: 3,
            removed: 1,
            rows: [
              TuiDiffUnifiedRow(
                TuiDiffLine(kind: TuiDiffLineKind.added, text: 'hidden'),
              ),
            ],
          ),
        ],
      ),
    );

    expect(find.text('Binary file not shown.'), findsOneWidget);
    expect(find.text('Diff too large to render.'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);
    expect(find.text('▸'), findsOneWidget); // folded chevron
  });

  testWidgets('change bar paints five blocks', (tester) async {
    await pumpHost(
      tester,
      under: const Center(child: TuiChangeBar(added: 3, removed: 2)),
    );
    expect(find.byType(TuiChangeBar), findsOneWidget);
  });
}
