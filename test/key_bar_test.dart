import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      final controller = TerminalController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: SwipeKeyPad(
          terminal: Terminal(),
          controller: controller,
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

  group('SwipeKeyPad over a terminal', () {
    late Terminal terminal;
    late List<String> sent;
    late TerminalController selection;
    late ScrollController scroll;
    late int tapped;

    /// A real TerminalView, because what is under test is how the pad shares
    /// the gesture arena with xterm2's own scroll and long press. Returns the
    /// middle of the terminal, which is blank: every line is short.
    Future<Offset> pumpPad(WidgetTester tester) async {
      terminal = Terminal();
      // Enough lines that there is scrollback to drag through.
      terminal.write(List.generate(200, (i) => 'line $i').join('\r\n'));
      sent = [];
      tapped = 0;
      selection = TerminalController();
      scroll = ScrollController();
      addTearDown(selection.dispose);
      addTearDown(scroll.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SwipeKeyPad(
            terminal: terminal,
            controller: selection,
            onEmit: sent.add,
            child: TerminalView(
              terminal,
              controller: selection,
              scrollController: scroll,
              hardwareKeyboardOnly: true,
              onTapUp: (_, _) => tapped++,
            ),
          ),
        ),
      ));
      return tester.getCenter(find.byType(TerminalView));
    }

    /// The row five above the prompt, which reads `line 194`.
    int row() => terminal.buffer.absoluteCursorY - 5;

    /// The middle of cell [x] on that row, or [down] rows below it.
    Offset cell(WidgetTester tester, int x, [int down = 0]) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return render.localToGlobal(
        render.getOffset(CellOffset(x, row() + down)) +
            render.cellSize.center(Offset.zero),
      );
    }

    /// The foot of the gap before cell [x] on that row: where a handle at
    /// that end of a selection points.
    Offset foot(WidgetTester tester, int x) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return render.localToGlobal(
        render.getOffset(CellOffset(x, row())) +
            Offset(0, render.cellSize.height),
      );
    }

    /// Where the handle on [side] points: the corner of Flutter's own handle
    /// that its anchor names.
    Offset handlePoint(WidgetTester tester, TextSelectionHandleType side) {
      final handle = find.descendant(
        of: find.byKey(ValueKey(side)),
        matching: find.byType(CustomPaint),
      );
      return tester.getRect(handle).topLeft +
          materialTextSelectionControls.getHandleAnchor(side, 0);
    }

    /// Long-presses `line` on that row and lifts, which selects the word.
    Future<void> selectWord(WidgetTester tester) async {
      final hold = await tester.startGesture(cell(tester, 1));
      await tester.pump(kLongPressTimeout);
      await hold.up();
      await tester.pump();
    }

    String? selected() {
      final range = selection.selection;
      return range == null ? null : terminal.buffer.getText(range);
    }

    testWidgets('a long press on a word selects it, and a drag while held '
        'widens it', (tester) async {
      await pumpPad(tester);

      final gesture = await tester.startGesture(cell(tester, 1));
      await tester.pump(kLongPressTimeout);
      expect(selected(), 'line');

      await gesture.moveTo(cell(tester, 6));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(selected(), 'line 194');
      expect(sent, isEmpty);
    });

    testWidgets(
        "once lifted, Flutter's own handles point at the word's first cell "
        'and the gap after its last', (tester) async {
      await pumpPad(tester);
      await selectWord(tester);

      expect(selected(), 'line');
      expect(
        handlePoint(tester, TextSelectionHandleType.left),
        offsetMoreOrLessEquals(foot(tester, 0)),
      );
      expect(
        handlePoint(tester, TextSelectionHandleType.right),
        offsetMoreOrLessEquals(foot(tester, 4)),
      );
    });

    testWidgets('dragging the end handle right takes in the cells it passes',
        (tester) async {
      await pumpPad(tester);
      await selectWord(tester);
      final width = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal
          .cellSize
          .width;

      final drag = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey(TextSelectionHandleType.right)),
        ),
      );
      await drag.moveBy(Offset(width * 3, 0));
      await tester.pump();
      // Kept out from under the finger while it drags.
      expect(find.text('Copy'), findsNothing);

      await drag.up();
      await tester.pump();
      expect(selected(), 'line 19');
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets(
        'the end handle taken up past the start keeps its drag while output '
        'carries the other end out of sight', (tester) async {
      await pumpPad(tester);
      await selectWord(tester);

      final drag = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey(TextSelectionHandleType.right)),
        ),
      );
      // Up past the start, so the finger's handle is now the one at the far
      // end, and then output enough to push that end out of the top.
      await drag.moveTo(cell(tester, 4, -3));
      await tester.pump();
      terminal.write('\r\nmore' * 100);
      await tester.pump();
      await tester.pump();

      // Still its drag: lifting brings the toolbar back.
      await drag.up();
      await tester.pump();
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets(
        'a drag that misses the handles scrolls, keeps the selection, and the '
        'handles go with the text', (tester) async {
      final centre = await pumpPad(tester);
      await selectWord(tester);
      final before = scroll.offset;

      // Short enough that the selected row stays on screen.
      final drag = await tester.startGesture(centre);
      for (var i = 0; i < 3; i++) {
        await drag.moveBy(const Offset(0, 20));
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(scroll.offset, lessThan(before));
      expect(selected(), 'line');
      expect(
        handlePoint(tester, TextSelectionHandleType.left),
        offsetMoreOrLessEquals(foot(tester, 0)),
      );
    });

    testWidgets(
        'the toolbar offers Copy and Select all, and Copy puts the selection '
        'on the clipboard and lets it go', (tester) async {
      final copied = <Object?>[];
      final platform = tester.binding.defaultBinaryMessenger;
      platform.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call.arguments);
        return null;
      });
      addTearDown(
        () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pumpPad(tester);
      await selectWord(tester);
      expect(find.text('Select all'), findsOneWidget);

      await tester.tap(find.text('Copy'));
      // A frame for the toast's overlay, one to start its slide, and the slide.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(copied, [
        {'text': 'line'},
      ]);
      expect(selection.selection, isNull);
      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      // The toast's countdown run out, rather than left running past the test.
      await tester.pumpAndSettle();
    });

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

    testWidgets(
        'a long press on blank space then a drag sends the arrow, and '
        'selects nothing', (tester) async {
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

  group('decodeKeyText', () {
    test('reads the escapes for keys with no character of their own', () {
      // Enter is a carriage return, as the Enter key sends it.
      expect(decodeKeyText(r'ls\n'), 'ls\r');
      expect(decodeKeyText(r'\e[15~'), '\x1b[15~');
      expect(decodeKeyText(r'a\tb\rc\\d\x03\x7F'), 'a\tb\rc\\d\x03\x7f');
      expect(decodeKeyText('git status'), 'git status');
    });

    test('refuses an escape it does not know, and says which', () {
      for (final typed in [r'ls\q', r'\x4', r'\xZZ', r'trailing\']) {
        expect(() => decodeKeyText(typed), throwsFormatException,
            reason: typed);
      }
      expect(
        () => decodeKeyText(r'ls\q'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains(r'\q'))),
      );
    });
  });

  testWidgets('a custom key shows its label, and types its text decoded',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: TerminalKeyBar(
          controller: KeyBarController(),
          terminal: Terminal(),
          onEmit: sent.add,
          keys: const ['custom:ls', 'esc', 'custom:f5'],
          customKeys: const {
            'custom:ls': (label: 'LS', send: r'ls\n'),
            'custom:f5': (label: 'F5', send: r'\e[15~'),
          },
        ),
      ),
    ));

    await tester.tap(find.text('LS'));
    await tester.tap(find.text('ESC'));
    await tester.tap(find.text('F5'));
    expect(sent, ['ls\r', '\x1b', '\x1b[15~']);
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
