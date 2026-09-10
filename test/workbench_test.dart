import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/workbench.dart';

/// The split, on its own.
///
/// Worth testing apart from the terminal precisely because it knows nothing
/// about one: the geometry is the whole behaviour, and checking it here means
/// not needing an SSH session to find out whether a pane got its width.
const _primary = ValueKey('primary');
const _secondary = ValueKey('secondary');

Future<void> _pump(WidgetTester tester, {Widget? secondary}) async {
  // A tablet in landscape, which is the only shape this widget is for.
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Workbench(
          primary: const SizedBox.expand(key: _primary),
          secondary: secondary,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one pane takes the whole width', (tester) async {
    await _pump(tester);

    expect(tester.getSize(find.byKey(_primary)).width, 1280);
    // No seam to drag when there is nothing to drag it against.
    expect(find.byKey(Workbench.seamKey), findsNothing);
  });

  testWidgets('two panes share the width, primary slightly under half',
      (tester) async {
    await _pump(
      tester,
      secondary: const SizedBox.expand(key: _secondary),
    );

    // 42%: the editor is the thing being read closely, the terminal watched.
    expect(tester.getSize(find.byKey(_primary)).width, closeTo(1280 * 0.42, 1));
    expect(find.byKey(_secondary), findsOneWidget);
    // Both at once is the entire point — this is what "side by side" means.
    expect(find.byKey(_primary), findsOneWidget);
  });

  testWidgets('dragging the seam moves the split', (tester) async {
    await _pump(
      tester,
      secondary: const SizedBox.expand(key: _secondary),
    );

    final before = tester.getSize(find.byKey(_primary)).width;
    await tester.drag(find.byKey(Workbench.seamKey), const Offset(160, 0));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(_primary)).width, closeTo(before + 160, 1));
  });

  testWidgets('neither pane can be dragged down to a sliver', (tester) async {
    await _pump(
      tester,
      secondary: const SizedBox.expand(key: _secondary),
    );

    // Shove it far past the end. A pane too narrow to read is worse than a
    // closed one, so the clamp has to hold.
    await tester.drag(find.byKey(Workbench.seamKey), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_primary)).width, closeTo(1280 * 0.25, 1));

    await tester.drag(find.byKey(Workbench.seamKey), const Offset(4000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_primary)).width, closeTo(1280 * 0.75, 1));
  });
}
