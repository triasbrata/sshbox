import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_chat.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(body: child),
      ),
    );
  }

  test('tuiToolGlyph maps known tools', () {
    expect(tuiToolGlyph('Bash'), r'$');
    expect(tuiToolGlyph('Read'), '◇');
    expect(tuiToolGlyph('Unknown'), '▸');
  });

  testWidgets('bubble shows delivery note', (tester) async {
    await pumpHost(
      tester,
      const TuiChatBubble(text: 'hello', delivery: TuiChatDelivery.sending),
    );
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('Sending…'), findsOneWidget);
  });

  testWidgets('tool row expands to show input/result', (tester) async {
    await pumpHost(
      tester,
      const SizedBox(
        width: 360,
        child: TuiToolRow(
          name: 'Read',
          summary: 'a.dart',
          input: 'path: a.dart',
          result: 'ok',
        ),
      ),
    );
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('path: a.dart'), findsNothing);

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.text('path: a.dart'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.text('RESULT'), findsOneWidget);
  });

  testWidgets('running tool shows spinner not glyph', (tester) async {
    await pumpHost(
      tester,
      const TuiToolRow(
        name: 'Bash',
        summary: 'ls',
        status: TuiToolStatus.running,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(r'$'), findsNothing);
  });

  testWidgets('session list sections and select', (tester) async {
    String? picked;
    await pumpHost(
      tester,
      SizedBox(
        width: 240,
        height: 400,
        child: TuiChatSessionList(
          sessions: const [
            TuiChatSession(
              id: 'p',
              title: 'pinned one',
              kind: TuiChatSessionKind.pinned,
            ),
            TuiChatSession(
              id: 'r',
              title: 'live one',
              kind: TuiChatSessionKind.running,
              selected: true,
            ),
            TuiChatSession(
              id: 'f',
              title: 'done one',
              kind: TuiChatSessionKind.finished,
            ),
          ],
          onSelect: (s) => picked = s.id,
        ),
      ),
    );

    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('FINISHED (1)'), findsOneWidget);
    await tester.tap(find.text('done one'));
    expect(picked, 'f');
  });

  testWidgets('answer renders text', (tester) async {
    await pumpHost(
      tester,
      const TuiChatAnswer(text: 'All set.', streaming: true),
    );
    expect(find.text('All set.'), findsOneWidget);
    expect(find.text('▍'), findsOneWidget);
  });
}
