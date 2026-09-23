import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/git/git_diff.dart';
import 'package:sshbox/src/ui/git_diff_page.dart';

/// Old line 11 replaced by three, between a line kept above and one below.
const _diff = '''
diff --git a/src/A.kt b/src/A.kt
index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
--- a/src/A.kt
+++ b/src/A.kt
@@ -10,3 +10,5 @@ class A {
 keep
-old line
+new one
+new two
+val running = null
 tail''';

/// The old file the diff was made against: thirty lines, the hunk at 10–12.
final _old = [
  for (var n = 1; n <= 30; n++)
    switch (n) {
      10 => 'keep',
      11 => 'old line',
      12 => 'tail',
      _ => 'line $n',
    },
].join('\n');

Finder _code(String text) => find.text(text, findRichText: true);

void main() {
  late List<String> blobsRead;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    blobsRead = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    String diff = _diff,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: GitDiffPage(
          diff: GitDiff(
            key: 'repo:src/A.kt',
            title: 'A.kt · diff',
            subtitle: 'src/A.kt · repo',
            read: () async => diff,
            blob: (id) async {
              blobsRead.add(id);
              return _old;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide, the old version sits beside the new, each with its own '
      'numbers, and a filler keeps what follows level', (tester) async {
    await pump(tester, width: 1400);

    // Kept lines are on both sides, with both numbers.
    expect(_code('keep'), findsNWidgets(2));
    expect(find.text('10'), findsNWidgets(2));
    expect(_code('tail'), findsNWidgets(2));
    // Old 12 beside new 14: the two lines the old side lacks are fillers.
    expect(find.text('14'), findsOneWidget);

    // The removed line on the left beside the first added one.
    expect(_code('old line'), findsOneWidget);
    expect(_code('new one'), findsOneWidget);
    expect(find.text('-'), findsOneWidget);
    expect(find.text('+'), findsNWidgets(3));
    expect(
      tester.getTopLeft(_code('old line')).dy,
      tester.getTopLeft(_code('new one')).dy,
    );
    expect(
      tester.getTopLeft(_code('old line')).dx,
      lessThan(tester.getTopLeft(_code('new one')).dx),
    );

    // Two fillers, beside the second and third added lines.
    final fillers = find.byKey(const ValueKey('diff-filler'));
    expect(fillers, findsNWidgets(2));
    expect(
      tester.getTopLeft(fillers.first).dy,
      tester.getTopLeft(_code('new two')).dy,
    );
    // And the kept line after them is level on both sides again.
    final tails = _code('tail');
    expect(tester.getTopLeft(tails.first).dy, tester.getTopLeft(tails.last).dy);

    // The hunk's header as git printed it, and the file's own header.
    expect(find.text('@@ -10,3 +10,5 @@ class A {'), findsOneWidget);
    expect(find.text('src/A.kt'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
  });

  testWidgets('the code is coloured by its language', (tester) async {
    await pump(tester, width: 1400);

    final line = tester.widget<RichText>(_code('val running = null'));
    final spans = <TextSpan>[];
    line.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) spans.add(span);
      return true;
    });
    final keyword = spans.firstWhere((span) => span.text == 'val');
    final plain = spans.firstWhere((span) => span.text!.contains('running'));
    expect(keyword.style?.color, isNotNull);
    expect(keyword.style?.color, isNot(plain.style?.color));
  });

  testWidgets('narrow, it is one column with both numbers, and the switch is '
      'remembered for a narrow page alone', (tester) async {
    await pump(tester, width: 600);

    expect(_code('keep'), findsOneWidget);
    // Old and new numbers side by side in one row.
    expect(find.text('10'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('diff-filler')), findsNothing);

    await tester.tap(find.byTooltip('Split view'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('diff-filler')), findsNWidgets(2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gitDiff.split.narrow'), isTrue);
    expect(prefs.getBool('gitDiff.split.wide'), isNull);

    // A new tab at the same width starts the way it was left.
    await tester.pumpWidget(const SizedBox());
    await pump(tester, width: 600);
    expect(find.byKey(const ValueKey('diff-filler')), findsNWidgets(2));
  });

  testWidgets('the lines around a hunk come from the old blob, a tap at a '
      'time', (tester) async {
    await pump(tester, width: 1400);
    expect(_code('line 9'), findsNothing);

    // Nine lines above the hunk: few enough to show in one tap.
    await tester.tap(find.byTooltip('Show 9 hidden lines'));
    await tester.pumpAndSettle();

    expect(blobsRead, ['1111111111111111111111111111111111111111']);
    // Kept lines, so on both sides, numbered the same above the hunk.
    expect(_code('line 1'), findsNWidgets(2));
    expect(_code('line 9'), findsNWidgets(2));

    // Below the hunk, the old file's length is known now: 18 more, in
    // steps of twenty, and numbered two further on the new side.
    await tester.tap(find.byTooltip('Show 18 hidden lines'));
    await tester.pumpAndSettle();
    expect(_code('line 13'), findsNWidgets(2));
    expect(find.text('15'), findsWidgets);
    expect(find.byTooltip('Show 18 hidden lines'), findsNothing);
    // Read once, for the whole file.
    expect(blobsRead, hasLength(1));
  });

  testWidgets('Find counts the matches and Copy diff copies what git printed', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester, width: 1400);

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy diff'));
    await tester.pumpAndSettle();
    expect(copied, _diff);
  });

  testWidgets('a binary file says so rather than drawing nothing', (
    tester,
  ) async {
    await pump(
      tester,
      width: 1400,
      diff: '''
diff --git a/icon.png b/icon.png
index 9999999999999999999999999999999999999999..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100644
Binary files a/icon.png and b/icon.png differ''',
    );

    expect(find.text('icon.png'), findsOneWidget);
    expect(find.text('Binary file, not shown.'), findsOneWidget);
  });

  testWidgets('no changes at all says so', (tester) async {
    await pump(tester, width: 1400, diff: '');
    expect(find.text('No changes'), findsOneWidget);
  });
}
