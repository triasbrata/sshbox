import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/markdown_rich_editor.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

/// What one key in Rich text costs on the 83 KB README, run with
/// RICH_BENCH=1. Debug-mode numbers (JIT, asserts on, a widget test's
/// binding, no raster): only their ratios carry over to a release build.
void main() {
  final on = Platform.environment['RICH_BENCH'] != null;

  testWidgets(
    'a key in the README, timed',
    skip: !on,
    semanticsEnabled: false,
    (tester) async {
      final readme = File('README.md').readAsStringSync();
      var text = readme;
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: TermulTheme.of(TermulPalette.paper),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MarkdownRichEditor(
                text: text,
                onChanged: (t, {required coalesce}) => setState(() => text = t),
                blockBuilder: (context, md) => Text(md),
                onOpenLink: (_) {},
                onRefused: (_) {},
                askLink: (_) async => null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final field = find.byType(EditableText);
      await tester.showKeyboard(field);
      final controller = tester.widget<EditableText>(field).controller;
      // Mid-paragraph, halfway down the file.
      final at = readme.indexOf('\n\n', readme.length ~/ 2) - 5;
      controller.selection = TextSelection.collapsed(offset: at);
      await tester.pump();

      final frame = <int>[];
      for (var k = 0; k < 30; k++) {
        final v = controller.value;
        final sel = v.selection;
        final next = v.text.replaceRange(sel.start, sel.end, 'x');

        final w = Stopwatch()..start();
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: sel.start + 1),
          ),
        );
        await tester.pump();
        frame.add(w.elapsedMicroseconds);
      }
      expect(controller.text.length, readme.length + 30);

      if (on) {
        String ms(List<int> xs) {
          final s = [...xs]..sort();
          return 'median ${(s[s.length ~/ 2] / 1000).toStringAsFixed(1)} ms, '
              'p90 ${(s[(s.length * 9) ~/ 10] / 1000).toStringAsFixed(1)} ms';
        }

        // ignore: avoid_print
        print(
          'README ${readme.length} bytes, debug build\n'
          '  a key, whole frame: ${ms(frame)}',
        );
      }
    },
  );
}
