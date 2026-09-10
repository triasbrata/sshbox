import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/magic_key.dart';
import 'package:xterm2/xterm.dart';

void main() {
  group('sectorFor', () {
    test('ignores a wobble inside the dead zone', () {
      expect(sectorFor(const Offset(6, -6), 8), isNull);
    });

    test('reads the compass points', () {
      expect(sectorFor(const Offset(0, -60), 8), 0);
      expect(sectorFor(const Offset(60, 0), 8), 2);
      expect(sectorFor(const Offset(0, 60), 8), 4);
      expect(sectorFor(const Offset(-60, 0), 8), 6);
    });

    test('reads the diagonals', () {
      expect(sectorFor(const Offset(60, -60), 8), 1);
      expect(sectorFor(const Offset(60, 60), 8), 3);
      expect(sectorFor(const Offset(-60, 60), 8), 5);
      expect(sectorFor(const Offset(-60, -60), 8), 7);
    });

    test('snaps a sloppy drag to the nearest sector', () {
      expect(sectorFor(const Offset(12, -60), 8), 0);
    });

    test('wraps round the north seam instead of falling off the end', () {
      // Just west of straight up is still up, not sector 8.
      expect(sectorFor(const Offset(-12, -60), 8), 0);
    });
  });

  group('magicKeys', () {
    test('the arrows follow the compass', () {
      final terminal = Terminal();
      expect(magicKeys[0].send(terminal), '\x1b[A');
      expect(magicKeys[2].send(terminal), '\x1b[C');
      expect(magicKeys[4].send(terminal), '\x1b[B');
      expect(magicKeys[6].send(terminal), '\x1b[D');
    });

    test('switches the arrows to SS3 once an application asks for DECCKM', () {
      final terminal = Terminal();
      terminal.write('\x1b[?1h');
      expect(magicKeys[0].send(terminal), '\x1bOA');
    });
  });

  group('MagicKey', () {
    late List<String> sent;

    setUp(() {
      sent = [];
      SharedPreferences.setMockInitialValues({});
    });

    Future<void> pumpKey(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: MagicKey(terminal: Terminal(), onEmit: sent.add),
                  ),
                ],
              ),
            ),
          ),
        );

    final button = find.byIcon(Icons.keyboard_return);

    testWidgets('a tap sends Enter', (tester) async {
      await pumpKey(tester);
      await tester.tap(button);
      expect(sent, ['\r']);
    });

    /// Puts a finger on the button and keeps it there until the ring opens.
    Future<TestGesture> hold(WidgetTester tester) async {
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      return gesture;
    }

    testWidgets('holding it opens the ring', (tester) async {
      await pumpKey(tester);
      expect(find.text('ESC'), findsNothing);

      final gesture = await hold(tester);
      expect(find.text('ESC'), findsOneWidget);

      await gesture.up();
      await tester.pump();
      expect(sent, isEmpty, reason: 'opening the ring must not send a key');
    });

    testWidgets('holding and sliding sends the key it points at',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      await gesture.moveBy(const Offset(0, -70));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(sent, ['\x1b[A']);
      expect(find.text('ESC'), findsNothing, reason: 'a pick closes the ring');
    });

    testWidgets('let go without sliding and the ring waits to be tapped',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump();

      // Still open, and now its petals are buttons.
      expect(find.text('TAB'), findsOneWidget);
      await tester.tap(find.text('TAB'));
      await tester.pump();

      expect(sent, ['\t']);
      expect(find.text('TAB'), findsNothing);
    });

    testWidgets('a slide brought back to the middle picks nothing',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      // Changed their mind: back inside the dead zone is how you cancel.
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('tapping away from the open ring closes it, sending nothing',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump();
      expect(find.text('ESC'), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pump();

      expect(find.text('ESC'), findsNothing);
      expect(sent, isEmpty);
    });

    testWidgets('tapping the button on an open ring closes it, not Enter',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.text('ESC'), findsNothing);
      expect(sent, isEmpty, reason: '"never mind" must not type into a shell');
    });

    testWidgets('dragging it moves the button and remembers where',
        (tester) async {
      await pumpKey(tester);
      final before = tester.getCenter(button);

      await tester.drag(button, const Offset(-120, -200));
      await tester.pump();

      expect(tester.getCenter(button), isNot(before));
      expect(sent, isEmpty, reason: 'moving it must not send a key');

      // The move is only finished when it survives a rebuild from storage.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('sshbox.magickey.x'), isNotNull);
      expect(prefs.getDouble('sshbox.magickey.y'), isNotNull);
    });

    testWidgets('it is named for what a tap does', (tester) async {
      await pumpKey(tester);
      expect(find.bySemanticsLabel('Send Enter'), findsOneWidget);
    });
  });
}
