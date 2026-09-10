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

    testWidgets('a drag sends the key it pointed at', (tester) async {
      await pumpKey(tester);
      await tester.drag(button, const Offset(0, -70));
      await tester.pump();
      expect(sent, ['\x1b[A']);
    });

    testWidgets('a slip too small to be a drag still sends Enter',
        (tester) async {
      await pumpKey(tester);
      // Nobody taps a phone without moving a little, and the tap is what they
      // meant.
      await tester.drag(button, const Offset(0, -8));
      await tester.pump();
      expect(sent, ['\r']);
    });

    testWidgets('a drag brought back to the middle sends nothing',
        (tester) async {
      await pumpKey(tester);

      final gesture = await tester.startGesture(tester.getCenter(button));
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      // Changed their mind: back inside the dead zone is how you cancel.
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('holding it moves the button and remembers where', (tester) async {
      await pumpKey(tester);
      final before = tester.getCenter(button);

      final gesture = await tester.startGesture(before);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(-120, -200));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(tester.getCenter(button), isNot(before));
      expect(sent, isEmpty, reason: 'picking it up must not send a key');

      // The move is only finished when it survives a rebuild from storage.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('sshbox.magickey.x'), isNotNull);
      expect(prefs.getDouble('sshbox.magickey.y'), isNotNull);
    });
  });
}
