import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';
import 'package:sshbox/src/ui/termul/tui_dialog.dart';

void main() {
  // The macOS desktop's window is short enough that the font picker's 420
  // overflowed the dialog.
  testWidgets('a child taller than the window gives way in a TuiDialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: const TuiDialog(title: 'Fonts', child: SizedBox(height: 420)),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
