import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:sshbox/src/ui/tui.dart';

Widget _app(Widget child) => MaterialApp(
  theme: jeanshTheme(terminalSchemes.first.palette(Brightness.dark)),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a queued message says what it waits for when it has a reason, '
      'and the usual note when it has none', (tester) async {
    await tester.pumpWidget(
      _app(
        const TuiChatBubble(
          text: 'hello',
          delivery: TuiChatDelivery.queued,
          failureReason: 'Waiting for the connection.',
        ),
      ),
    );
    expect(find.text('Waiting for the connection.'), findsOneWidget);
    expect(find.textContaining('Queued: it runs after'), findsNothing);

    await tester.pumpWidget(
      _app(
        const TuiChatBubble(text: 'hello', delivery: TuiChatDelivery.queued),
      ),
    );
    expect(find.textContaining('Queued: it runs after'), findsOneWidget);
  });
}
