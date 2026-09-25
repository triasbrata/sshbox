import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/right_click.dart';

void main() {
  group('a Ctrl+click', () {
    var menus = 0;
    var taps = 0;

    Future<void> pumpTarget(WidgetTester tester) async {
      menus = 0;
      taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            onSecondaryTapUp: rightClick((_) => menus++),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    /// A mouse click with Ctrl held, through [click] as the app's binding
    /// passes every pointer event.
    Future<void> ctrlClick(WidgetTester tester, ControlClick click) async {
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      for (final event in [
        mouse.addPointer(location: const Offset(100, 100)),
        mouse.down(const Offset(100, 100)),
        mouse.up(),
      ]) {
        await tester.sendEventToBinding(click.convert(event));
      }
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('is a right-click on a Mac, as AppKit\'s own menus take it', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => false));
      expect(menus, 1);
      expect(taps, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('stays a click on a Mac while Ctrl is the link key', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => true));
      expect(menus, 0);
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('stays a click on Linux, where a Ctrl+click is a click', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => false));
      expect(menus, 0);
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

}
