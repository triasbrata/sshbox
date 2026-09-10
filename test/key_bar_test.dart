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
