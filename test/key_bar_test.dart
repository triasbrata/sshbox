import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/key_bar.dart';

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
  });
}
