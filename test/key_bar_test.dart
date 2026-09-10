import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:xterm2/xterm.dart';

void main() {
  group('KeyBarController.applyModifiers', () {
    late KeyBarController controller;

    setUp(() => controller = KeyBarController());
    tearDown(() => controller.dispose());

    test('passes text through untouched when nothing is armed', () {
      expect(controller.applyModifiers('ls'), 'ls');
    });

    test('folds armed Ctrl into the next letter', () {
      controller.toggleCtrl();
      expect(controller.applyModifiers('c'), '\x03');
    });

    test('treats uppercase the same as lowercase for Ctrl', () {
      controller.toggleCtrl();
      expect(controller.applyModifiers('C'), '\x03');
    });

    test('disarms Ctrl after one character', () {
      controller.toggleCtrl();
      controller.applyModifiers('c');
      expect(controller.ctrl, isFalse);
      expect(controller.applyModifiers('c'), 'c');
    });

    test('prefixes ESC for armed Alt', () {
      controller.toggleAlt();
      expect(controller.applyModifiers('b'), '\x1bb');
    });

    test('applies Ctrl and Alt together', () {
      controller.toggleCtrl();
      controller.toggleAlt();
      expect(controller.applyModifiers('c'), '\x1b\x03');
    });

    test('leaves multi-character input alone under Ctrl', () {
      // Autocomplete and paste arrive as a run of characters; mangling the
      // first one into a control code would corrupt the paste.
      controller.toggleCtrl();
      expect(controller.applyModifiers('hello'), 'hello');
    });

    test('maps Ctrl-Space to NUL and Ctrl-? to DEL', () {
      controller.toggleCtrl();
      expect(controller.applyModifiers(' '), '\x00');
      controller.toggleCtrl();
      expect(controller.applyModifiers('?'), '\x7f');
    });
  });

  group('swipe gestures', () {
    test('ignores a wobble inside the deadzone', () {
      expect(swipeArrow(const Offset(12, 9)), isNull);
    });

    test('picks the arrow from the dominant axis', () {
      expect(swipeArrow(const Offset(60, 10)), 'C');
      expect(swipeArrow(const Offset(-60, 10)), 'D');
      expect(swipeArrow(const Offset(10, 60)), 'B');
      expect(swipeArrow(const Offset(10, -60)), 'A');
    });

    test('a short reach is one press, not a repeat', () {
      expect(swipeRepeatMs(0), isNull);
      expect(swipeRepeatMs(30), isNull);
      expect(swipeRepeatMs(59), isNull);
    });

    test('repeats faster the further the drag reaches', () {
      expect(swipeRepeatMs(60), 2000);
      expect(swipeRepeatMs(130), lessThan(2000));
      expect(swipeRepeatMs(130), greaterThan(300));
      expect(swipeRepeatMs(200), 300);
    });

    test('a drag longer than the screen does not run away', () {
      expect(swipeRepeatMs(5000), 300);
    });

    test('the readout gains a chevron with every step up in speed', () {
      expect(swipeSpeedLevel(30), 1);
      expect(swipeSpeedLevel(60), 2);
      expect(swipeSpeedLevel(200), 3);
      // Three chevrons is the whole readout; a longer reach cannot add a
      // fourth the arm has no room for.
      expect(swipeSpeedLevel(5000), 3);
    });
  });

  group('SwipeKeyPad readout', () {
    /// Drags down from [fromFraction] across the width and reports which half
    /// of the screen the readout chose to sit in.
    Future<double> readoutCentre(WidgetTester tester, double fromFraction) async {
      await tester.pumpWidget(MaterialApp(
        home: SwipeKeyPad(
          terminal: Terminal(),
          onEmit: (_) {},
          // Opaque, so it takes part in the hit test the way a terminal does.
          child: const ColoredBox(color: Colors.black, child: SizedBox.expand()),
        ),
      ));

      final width = tester.getSize(find.byType(SwipeKeyPad)).width;
      final gesture =
          await tester.startGesture(Offset(width * fromFraction, 300));
      // Past the touch slop, so the pan is recognised and the readout comes up.
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      final centre = tester.getCenter(find.byIcon(Icons.arrow_upward)).dx;

      // Release, or the repeat timer outlives the test. The wait runs out the
      // double-tap recogniser's own countdown, which is not ours to cancel.
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      return centre - width / 2;
    }

    testWidgets('sits opposite the hand that is dragging', (tester) async {
      expect(await readoutCentre(tester, 0.2), greaterThan(0));
      expect(await readoutCentre(tester, 0.8), lessThan(0));
    });
  });

  testWidgets('the session buttons come first, ahead of ESC, sized as keys',
      (tester) async {
    // Stand-ins for the buttons the terminal page hands the bar.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: TerminalKeyBar(
          controller: KeyBarController(),
          terminal: Terminal(),
          onEmit: (_) {},
          leading: [
            IconButton(
              tooltip: 'Browse files',
              onPressed: () {},
              icon: const Icon(Icons.folder_outlined),
            ),
            // Disabled, as it is mid-upload: it must still look like a key.
            const IconButton(
              tooltip: 'Upload a file to /tmp',
              onPressed: null,
              icon: Icon(Icons.attach_file),
            ),
          ],
        ),
      ),
    ));

    final xs = [
      find.byTooltip('Browse files'),
      find.byTooltip('Upload a file to /tmp'),
      find.text('ESC'),
      find.text('TAB'),
    ].map((key) => tester.getCenter(key).dx).toList();
    expect(xs, [...xs]..sort());

    // Level with the keys beside them, not the height of the app bar they
    // came from. Width is left alone: it follows the test font's label.
    final esc = find.ancestor(
      of: find.text('ESC'),
      matching: find.byType(Material),
    );
    final keyHeight = tester.getSize(esc.first).height;
    for (final tooltip in ['Browse files', 'Upload a file to /tmp']) {
      expect(tester.getSize(find.byTooltip(tooltip)).height, keyHeight);
    }
  });

  group('CursorPad', () {
    late CursorPad pad;

    setUp(() => pad = CursorPad(stepX: 20, stepY: 28));

    test('stays quiet until the finger crosses a threshold', () {
      expect(pad.advance(const Offset(19, 27)), isEmpty);
    });

    test('emits one key per threshold crossed', () {
      expect(pad.advance(const Offset(20, 0)), ['C']);
      expect(pad.advance(const Offset(60, 0)), ['C', 'C']);
    });

    test('does not re-emit a step already sent', () {
      pad.advance(const Offset(20, 0));
      expect(pad.advance(const Offset(39, 0)), isEmpty);
    });

    test('sends the reverse key when the finger comes back', () {
      pad.advance(const Offset(40, 0));
      expect(pad.advance(const Offset(0, 0)), ['D', 'D']);
    });

    test('reads a downward drag as down, matching screen coordinates', () {
      expect(pad.advance(const Offset(0, 28)), ['B']);
      expect(pad.advance(const Offset(0, -28)), ['A', 'A']);
    });

    test('tracks both axes in one drag', () {
      expect(pad.advance(const Offset(20, 28)), ['C', 'B']);
    });

    test('forgets the previous drag after a reset', () {
      pad.advance(const Offset(40, 0));
      pad.reset();
      expect(pad.advance(const Offset(0, 0)), isEmpty);
    });
  });
}
