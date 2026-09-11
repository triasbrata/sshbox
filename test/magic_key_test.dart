import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/magic_key.dart';
import 'package:xterm2/xterm.dart';

void main() {
  final compass = [for (var i = 0; i < 8; i++) 2 * math.pi * i / 8];

  group('petalFor on the full ring', () {
    test('ignores a wobble inside the dead zone', () {
      expect(petalFor(const Offset(6, -6), compass), isNull);
    });

    test('reads the compass points', () {
      expect(petalFor(const Offset(0, -60), compass), 0);
      expect(petalFor(const Offset(60, 0), compass), 2);
      expect(petalFor(const Offset(0, 60), compass), 4);
      expect(petalFor(const Offset(-60, 0), compass), 6);
    });

    test('reads the diagonals', () {
      expect(petalFor(const Offset(60, -60), compass), 1);
      expect(petalFor(const Offset(60, 60), compass), 3);
      expect(petalFor(const Offset(-60, 60), compass), 5);
      expect(petalFor(const Offset(-60, -60), compass), 7);
    });

    test('snaps a sloppy drag to the nearest petal', () {
      expect(petalFor(const Offset(12, -60), compass), 0);
    });

    test('wraps round the north seam instead of falling off the end', () {
      // Just west of straight up is still up.
      expect(petalFor(const Offset(-12, -60), compass), 0);
    });
  });

  group('ringLayout', () {
    const petal = 40.0;
    const screen = Size(800, 1200);

    Offset petalCentre(Offset centre, double angle, double radius) => Offset(
          centre.dx + radius * math.sin(angle),
          centre.dy - radius * math.cos(angle),
        );

    /// Both rings' petals, as if every key had two behind it: the most ring 2
    /// ever holds.
    List<Offset> petalsOf(Offset centre, Size bounds) {
      final ring = ringLayout(centre: centre, bounds: bounds);
      return [
        for (final a in ring.angles) ...[
          petalCentre(centre, a, ring.radius),
          petalCentre(centre, a, ring.outer),
          petalCentre(centre, a + ring.spread, ring.outer),
        ],
      ];
    }

    void expectAllOnScreen(Offset centre, Size bounds) {
      for (final p in petalsOf(centre, bounds)) {
        expect(p.dx - petal / 2, greaterThanOrEqualTo(0), reason: 'left');
        expect(p.dy - petal / 2, greaterThanOrEqualTo(0), reason: 'top');
        expect(p.dx + petal / 2, lessThanOrEqualTo(bounds.width),
            reason: 'right');
        expect(p.dy + petal / 2, lessThanOrEqualTo(bounds.height),
            reason: 'bottom');
      }
    }

    test('takes the compass points when there is room all round', () {
      final ring = ringLayout(centre: const Offset(400, 600), bounds: screen);
      for (var i = 0; i < 8; i++) {
        expect(ring.angles[i], closeTo(compass[i], 1e-9));
      }
      expect(ring.radius, 80);
    });

    test('fans away from the right edge, no petal past it', () {
      expectAllOnScreen(const Offset(770, 600), screen);
    });

    test('fans out of a corner, every petal on screen', () {
      // The default spot for the key is the bottom-right corner.
      expectAllOnScreen(const Offset(760, 1160), screen);
      expectAllOnScreen(const Offset(30, 30), screen);
    });

    test('pushes a fanned ring out so its petals do not overlap', () {
      final points = petalsOf(const Offset(770, 600), screen);
      for (var i = 0; i < points.length; i++) {
        for (var j = i + 1; j < points.length; j++) {
          expect((points[i] - points[j]).distance,
              greaterThanOrEqualTo(petal - 1e-6));
        }
      }
    });

    test('keeps the arrows on their own sides of a fan', () {
      // Against the right edge the ring opens to the left: down stays below
      // up, and left points left.
      final centre = const Offset(770, 600);
      final ring = ringLayout(centre: centre, bounds: screen);
      final up = petalCentre(centre, ring.angles[0], ring.radius);
      final down = petalCentre(centre, ring.angles[4], ring.radius);
      final left = petalCentre(centre, ring.angles[6], ring.radius);
      expect(up.dy, lessThan(down.dy));
      expect(left.dx, lessThan(centre.dx));
    });

    test('in the corner, up is still up and left is still left', () {
      // The key starts in the bottom-right corner, so this is the fan most
      // people see first — and sliding up must not send ESC.
      final centre = const Offset(760, 1160);
      final ring = ringLayout(centre: centre, bounds: screen);
      expect(petalFor(const Offset(0, -60), ring.angles), 0, reason: 'up');
      expect(petalFor(const Offset(-60, 0), ring.angles), 6, reason: 'left');
    });

    test('pointing into the gap a fan leaves picks nothing', () {
      final centre = const Offset(770, 600);
      final ring = ringLayout(centre: centre, bounds: screen);
      // Straight at the edge, where no petal could fit.
      expect(petalFor(const Offset(60, 0), ring.angles), isNull);
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

    /// Puts a finger on the button, or [at] a point on it, and keeps it there
    /// until the ring opens.
    Future<TestGesture> hold(WidgetTester tester, [Offset? at]) async {
      final gesture = await tester.startGesture(at ?? tester.getCenter(button));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      return gesture;
    }

    testWidgets('a slip too small to be a drag still sends Enter',
        (tester) async {
      await pumpKey(tester);
      // Nobody taps a phone without moving a little, and the tap is what they
      // meant — not a move of the button.
      final before = tester.getCenter(button);
      await tester.drag(button, const Offset(0, -8));
      await tester.pump();
      expect(sent, ['\r']);
      expect(tester.getCenter(button), before);
    });

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

    testWidgets('lifting without aiming closes the ring and sends nothing',
        (tester) async {
      await pumpKey(tester);

      final gesture = await hold(tester);
      expect(find.text('ESC'), findsOneWidget);
      await gesture.up();
      await tester.pump();

      expect(find.text('ESC'), findsNothing,
          reason: 'the ring only lives while the finger does');
      expect(sent, isEmpty);
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
      expect(find.text('ESC'), findsNothing);
    });

    /// Slides [by] from where a held finger landed on the key in the middle
    /// of the screen, where both rings are whole, and lifts.
    Future<void> slideFromMiddle(WidgetTester tester, Offset by) async {
      SharedPreferences.setMockInitialValues(
        {'sshbox.magickey.x': 0.5, 'sshbox.magickey.y': 0.5},
      );
      await pumpKey(tester);
      await tester.pump();

      final gesture = await hold(tester);
      await gesture.moveBy(by);
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    testWidgets('sliding further the same way sends the key behind',
        (tester) async {
      // A little way up is ↑; past halfway out to ring 2, PgUp behind it.
      // Straight up as a thumb does it, a few degrees off, is still PgUp.
      await slideFromMiddle(tester, const Offset(8, -135));
      expect(sent, ['\x1b[5~']);
    });

    testWidgets('clockwise of that is the second key behind', (tester) async {
      // About 20° clockwise of straight up.
      await slideFromMiddle(tester, const Offset(46, -127));
      expect(sent, ['\x1b[H'], reason: 'Home, the other key behind ↑');
    });

    testWidgets('floating, ring 2 is still out where it is drawn',
        (tester) async {
      // Far enough to reach ring 2 on a tucked key; not on this one.
      await slideFromMiddle(tester, const Offset(0, -60));
      expect(sent, ['\x1b[A']);
    });

    final box = find.byKey(const ValueKey('magic-key-button'));

    /// The label on the petal lit up as aimed at, or null when none is.
    String? aimed(WidgetTester tester) {
      final lit = find.byWidgetPredicate(
        (w) => w is Material && w.elevation == 8,
      );
      final label = find.descendant(of: lit, matching: find.byType(Text));
      return label.evaluate().isEmpty ? null : tester.widget<Text>(label).data;
    }

    /// Holds a key tucked into the [left] or right side, on the half of it that
    /// shows. Each pull then puts the finger that far out from where it landed
    /// toward the [toward] petal, the way a thumb aims at one, and answers with
    /// the petal lit up.
    Future<(TestGesture, Future<String?> Function(double))> holdTucked(
      WidgetTester tester, {
      required bool left,
      required String toward,
    }) async {
      SharedPreferences.setMockInitialValues({
        'sshbox.magickey.x': left ? 0.0 : 1.0,
        'sshbox.magickey.y': 0.5,
        'sshbox.magickey.docked': true,
      });
      await pumpKey(tester);
      await tester.pump();

      final centre = tester.getRect(box).center;
      final landed = centre + Offset(left ? 10 : -10, 0);
      final finger = await hold(tester, landed);
      final way = tester.getCenter(find.text(toward)) - centre;
      Future<String?> pull(double distance) async {
        await finger.moveTo(landed + way / way.distance * distance);
        await tester.pump();
        return aimed(tester);
      }

      return (finger, pull);
    }

    // Tucked, ring 2 takes over 50 out: the dead zone's 18 and a pull of 32.
    testWidgets('tucked on the left, ring 2 is a short pull right',
        (tester) async {
      final (finger, pull) = await holdTucked(tester, left: true, toward: '→');
      expect(await pull(24), '→', reason: 'just past the dead zone');
      expect(await pull(60), 'END', reason: 'the key behind, nowhere near it');
      expect(await pull(20), '→', reason: 'easing back is ring 1 again');
      await finger.up();
      await tester.pump();
      expect(sent, ['\x1b[C'], reason: 'lifting sends what is lit');
    });

    testWidgets('tucked, a finger on the line keeps the ring it is in',
        (tester) async {
      final (finger, pull) = await holdTucked(tester, left: true, toward: '→');
      expect(await pull(52), 'END');
      expect(await pull(47), 'END', reason: 'ring 2 lets go only 6 inside');
      expect(await pull(42), '→');
      expect(await pull(47), '→', reason: 'and ring 1 holds up to the line');
      await finger.up();
      await tester.pump();
    });

    testWidgets('tucked on the right, it mirrors: ring 2 is a pull left',
        (tester) async {
      final (finger, pull) = await holdTucked(tester, left: false, toward: '←');
      expect(await pull(24), '←');
      expect(await pull(60), 'HOME');
      await finger.up();
      await tester.pump();
      expect(sent, ['\x1b[H']);
    });

    testWidgets('in its corner both rings fan out and stay on screen',
        (tester) async {
      await pumpKey(tester);
      // Pumped at the default spot, the bottom-right corner.
      final screen = tester.getRect(find.byType(MagicKey));

      final gesture = await hold(tester);
      final labels = find.descendant(
        of: find.byType(MagicKey),
        matching: find.byType(Text),
      );
      final count = magicKeys.length +
          magicSubKeys.values.expand((keys) => keys).length;
      expect(labels, findsNWidgets(count), reason: 'both rings are up');
      for (var i = 0; i < count; i++) {
        final petal = tester.getRect(labels.at(i));
        final label = tester.widget<Text>(labels.at(i)).data;
        expect(screen.contains(petal.topLeft), isTrue, reason: label);
        expect(screen.contains(petal.bottomRight), isTrue, reason: label);
      }
      await gesture.up();
      await tester.pump();
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

    testWidgets('thrown at a side, it tucks in half off the screen',
        (tester) async {
      await pumpKey(tester);

      await tester.fling(button, const Offset(-200, 0), 1500);
      await tester.pumpAndSettle();

      expect(tester.getRect(box).center.dx, moreOrLessEquals(0),
          reason: 'its middle sits on the left edge');
      expect(sent, isEmpty, reason: 'throwing it must not send a key');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('sshbox.magickey.docked'), isTrue);
    });

    testWidgets('a tap brings a tucked key back out, clear of the edge',
        (tester) async {
      await pumpKey(tester);
      await tester.fling(button, const Offset(-200, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Show Enter key'), findsOneWidget);

      // On the half that is still showing.
      await tester.tapAt(Offset(10, tester.getRect(box).center.dy));
      await tester.pumpAndSettle();

      expect(tester.getRect(box).left, moreOrLessEquals(16));
      expect(sent, isEmpty, reason: 'fetching it is not a keystroke');

      await tester.tap(button);
      expect(sent, ['\r'], reason: 'once out, it is the Enter key again');
    });

    testWidgets('pushed flat against a side, it tucks in there too',
        (tester) async {
      await pumpKey(tester);
      final screen = tester.getRect(find.byType(MagicKey));

      // A drag with no speed behind it: the edge is what tucks it in, not a
      // throw.
      await tester.drag(button, const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(tester.getRect(box).center.dx, moreOrLessEquals(screen.right));
    });

    testWidgets('left alone it fades, and a touch brings it straight back',
        (tester) async {
      await pumpKey(tester);
      double opacity() => tester
          .widget<FadeTransition>(
            find.descendant(of: box, matching: find.byType(FadeTransition)),
          )
          .opacity
          .value;

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(opacity(), moreOrLessEquals(0.6));

      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      expect(opacity(), 1);
      await gesture.up();
      expect(sent, ['\r'], reason: 'faded, it is still the Enter key');
    });

    testWidgets('it is named for what a tap does', (tester) async {
      await pumpKey(tester);
      expect(find.bySemanticsLabel('Send Enter'), findsOneWidget);
    });
  });
}
