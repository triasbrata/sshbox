import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_magic_key.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  final compass = [for (var i = 0; i < 8; i++) 2 * math.pi * i / 8];

  group('tuiMagicPetalFor', () {
    test('ignores dead zone wobble', () {
      expect(tuiMagicPetalFor(const Offset(6, -6), compass), isNull);
    });

    test('reads compass points', () {
      expect(tuiMagicPetalFor(const Offset(0, -60), compass), 0);
      expect(tuiMagicPetalFor(const Offset(60, 0), compass), 2);
      expect(tuiMagicPetalFor(const Offset(0, 60), compass), 4);
      expect(tuiMagicPetalFor(const Offset(-60, 0), compass), 6);
    });

    test('reads diagonals', () {
      expect(tuiMagicPetalFor(const Offset(60, -60), compass), 1);
      expect(tuiMagicPetalFor(const Offset(60, 60), compass), 3);
      expect(tuiMagicPetalFor(const Offset(-60, 60), compass), 5);
      expect(tuiMagicPetalFor(const Offset(-60, -60), compass), 7);
    });
  });

  group('tuiMagicRingLayout', () {
    const screen = Size(800, 1200);

    test('compass when there is room all round', () {
      final ring = tuiMagicRingLayout(
        centre: const Offset(400, 600),
        bounds: screen,
      );
      for (var i = 0; i < 8; i++) {
        expect(ring.angles[i], closeTo(compass[i], 1e-9));
      }
      expect(ring.radius, 80);
    });

    test('fans away from the right edge', () {
      final centre = const Offset(770, 600);
      final ring = tuiMagicRingLayout(centre: centre, bounds: screen);
      expect(tuiMagicPetalFor(const Offset(60, 0), ring.angles), isNull);
      expect(tuiMagicPetalFor(const Offset(0, -60), ring.angles), 0);
    });
  });

  test('default ring labels', () {
    expect(tuiMagicKeys.map((k) => k.label), [
      '↑',
      'ESC',
      '→',
      'TAB',
      '↓',
      '^C',
      '←',
      '^D',
    ]);
    expect(tuiMagicSubKeys['↑']!.first.label, 'PGUP');
  });

  testWidgets('tap emits enter label', (tester) async {
    String? emitted;
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: TuiMagicKey(
              initialSpot: const Offset(0.5, 0.5),
              onEmit: (l) => emitted = l,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('tui-magic-key-button')));
    await tester.pump();
    expect(emitted, tuiMagicEnterLabel);
  });

  testWidgets('long press opens petals', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: TuiMagicKey(
              initialSpot: const Offset(0.5, 0.5),
              onEmit: (_) {},
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(
      find.byKey(const ValueKey('tui-magic-key-button')),
    );
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
    await gesture.up();
    await tester.pump();
  });
}
