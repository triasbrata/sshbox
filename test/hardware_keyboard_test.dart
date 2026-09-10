import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:xterm2/xterm.dart';

void main() {
  // Through the real view, as TerminalPage mounts it, so a second byte sent
  // for the same keypress — the terminal's own Enter — would show up too.
  testWidgets('hardware Shift+Enter sends ESC CR, plain Enter sends CR',
      (tester) async {
    final session = LiveSession(
      host: const HostProfile(
          id: 'h', label: 'box', host: '10.0.2.2', username: 'me'),
    );
    addTearDown(session.dispose);
    final sent = <String>[];
    session.terminal.onOutput = sent.add;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalView(
          session.terminal,
          autofocus: true,
          hardwareKeyboardOnly: true,
        ),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sent, ['\x1b\r', '\r']);
  });
}
