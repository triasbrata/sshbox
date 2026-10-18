// How long a key takes in Markdown Rich text, measured where it is real: run
// in profile on the desktop lane (e2e.yml) through flutter drive, which
// `flutter test` cannot do:
//
//   flutter drive --profile -d linux \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/rich_text_perf_test.dart
//
// A measure, never a gate: it prints `perf:` lines and passes unless the
// typing itself went missing. The editor alone, with nothing else of the app,
// so what is timed is the editor.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/src/ui/markdown_rich_editor.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

/// A document of [sections] sections in a README's mix: headings, prose
/// with marks and links, a list with a task, a fence and a table now and
/// then.
String _doc(int sections) => [
  for (var i = 0; i < sections; i++)
    '## Section $i\n'
        '\n'
        'Some **bold** text, _italic_, `code` and a '
        '[link](https://example.com/$i) in a paragraph long enough to wrap '
        'onto a second line on most screens.\n'
        '\n'
        '- one\n'
        '- [ ] two\n'
        '${i % 5 == 0 ? '\n```sh\necho $i\n```\n' : ''}'
        '${i % 7 == 0 ? '\n| a | b |\n|---|---|\n| $i | x |\n' : ''}',
].join('\n');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  int at(List<int> sorted, double q) =>
      sorted.isEmpty ? -1 : sorted[((sorted.length - 1) * q).round()];

  for (final (name, sections) in [('500 lines', 60), ('1.5k lines', 180)]) {
    testWidgets('perf: a key in Rich text, $name', (tester) async {
      var text = _doc(sections);
      final lines = '\n'.allMatches(text).length;
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
      await tester.pumpAndSettle();
      final field = find.byType(EditableText);
      await tester.showKeyboard(field);
      final c = tester.widget<EditableText>(field).controller;
      // Mid-document, at the end of a paragraph.
      final caret = c.text.indexOf('screens.', c.text.length ~/ 2) + 8;
      c.selection = TextSelection.collapsed(offset: caret);
      await tester.pumpAndSettle();

      final timings = <ui.FrameTiming>[];
      void heard(List<ui.FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(heard);
      final keys = <int>[];
      for (var i = 0; i < 40; i++) {
        final v = c.value;
        final p = v.selection.baseOffset;
        final sw = Stopwatch()..start();
        // What a key does to the field: the text one letter longer.
        c.value = TextEditingValue(
          text: v.text.replaceRange(p, p, 'x'),
          selection: TextSelection.collapsed(offset: p + 1),
        );
        await tester.pump();
        keys.add(sw.elapsedMicroseconds);
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      SchedulerBinding.instance.removeTimingsCallback(heard);

      int ms(Duration d) => d.inMicroseconds;
      final build = [for (final t in timings) ms(t.buildDuration)]..sort();
      final raster = [for (final t in timings) ms(t.rasterDuration)]..sort();
      keys.sort();
      String f(int us) => (us / 1000).toStringAsFixed(1);
      debugPrint(
        'perf: rich text, $name ($lines lines, ${text.length} chars), '
        '${kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug'}: '
        'a key, change to frame drawn: p50 ${f(at(keys, .5))} ms '
        'p90 ${f(at(keys, .9))} ms max ${f(at(keys, 1))} ms; '
        '${timings.length} frames: build p50 ${f(at(build, .5))} ms '
        'p90 ${f(at(build, .9))} ms, raster p50 ${f(at(raster, .5))} ms '
        'p90 ${f(at(raster, .9))} ms',
      );
      expect(text.length, _doc(sections).length + 40, reason: 'keys lost');
    });
  }
}
