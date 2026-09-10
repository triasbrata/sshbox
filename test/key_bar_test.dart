import 'package:flutter/gestures.dart';
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
    /// Holds, then drags down from [fromFraction] across the width, and reports
    /// which half of the screen the readout chose to sit in.
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
      // Held until the arrows arm, which is what brings the readout up.
      await tester.pump(kLongPressTimeout);
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

  group('SwipeKeyPad over a terminal', () {
    late List<String> sent;
    late TerminalController selection;
    late ScrollController scroll;
    late int tapped;

    /// A real TerminalView, because what is under test is how the pad shares
    /// the gesture arena with xterm2's own scroll and long press. Returns the
    /// middle of the terminal, where every gesture lands.
    Future<Offset> pumpPad(WidgetTester tester) async {
      final terminal = Terminal();
      // Enough lines that there is scrollback to drag through.
      terminal.write(List.generate(200, (i) => 'line $i').join('\r\n'));
      sent = [];
      tapped = 0;
      selection = TerminalController();
      scroll = ScrollController();
      addTearDown(selection.dispose);
      addTearDown(scroll.dispose);

      await tester.pumpWidget(MaterialApp(
        home: SwipeKeyPad(
          terminal: terminal,
          onEmit: sent.add,
          child: TerminalView(
            terminal,
            controller: selection,
            scrollController: scroll,
            hardwareKeyboardOnly: true,
            onTapUp: (_, _) => tapped++,
          ),
        ),
      ));
      return tester.getCenter(find.byType(TerminalView));
    }

    testWidgets('a plain drag scrolls and sends nothing', (tester) async {
      final centre = await pumpPad(tester);
      final before = scroll.offset;

      final gesture = await tester.startGesture(centre);
      // Sideways first, the way a thumb often sets off: that alone used to be
      // enough for the pad to take the drag for arrows.
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(0, 200));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(sent, isEmpty);
      expect(scroll.offset, lessThan(before));
    });

    testWidgets('a long press then a drag sends the arrow, and selects nothing',
        (tester) async {
      final centre = await pumpPad(tester);

      final gesture = await tester.startGesture(centre);
      await tester.pump(kLongPressTimeout);
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(sent, ['\x1b[C']);
      expect(selection.selection, isNull);
    });

    testWidgets('a tap still reaches the terminal, and a double tap sends Tab',
        (tester) async {
      final centre = await pumpPad(tester);

      await tester.tapAt(centre);
      // A lone tap lands once the double-tap window has run out.
      await tester.pump(kDoubleTapTimeout);
      expect(tapped, 1);

      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapTimeout);
      expect(sent, ['\t']);
      expect(tapped, 1);
    });
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
