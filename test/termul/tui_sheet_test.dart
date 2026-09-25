import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_button.dart';
import 'package:sshbox/src/ui/termul/tui_progress.dart';
import 'package:sshbox/src/ui/termul/tui_sheet.dart';
import 'package:sshbox/src/ui/termul/tui_toast.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  late BuildContext hostContext;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        builder: (context, child) => TuiToastHost(child: child!),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
  }

  testWidgets('confirm sheet returns true on confirm', (tester) async {
    await pumpHost(tester);

    final result = showTuiConfirmSheet(
      hostContext,
      title: 'host key',
      message: 'Trust 10.0.0.12?',
      detail: 'First connection.',
      confirmLabel: 'trust',
    );
    await tester.pumpAndSettle();

    expect(find.text('HOST KEY'), findsOneWidget);
    expect(find.text('Trust 10.0.0.12?'), findsOneWidget);
    expect(find.byType(TuiSheetHandle), findsOneWidget);

    await tester.tap(find.text('TRUST'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('destructive confirm uses danger action', (tester) async {
    await pumpHost(tester);

    showTuiConfirmSheet(
      hostContext,
      title: 'host key',
      message: 'Host key changed',
      confirmLabel: 'replace key',
      confirmVariant: TuiButtonVariant.danger,
    );
    await tester.pumpAndSettle();

    expect(find.text('REPLACE KEY'), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
  });

  testWidgets('error sheet retry returns true', (tester) async {
    await pumpHost(tester);

    final result = showTuiErrorSheet(
      hostContext,
      title: 'connection',
      message: 'Connection refused',
      detail: 'Nothing on port 22.',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('RETRY'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('choice sheet returns selected value', (tester) async {
    await pumpHost(tester);

    final result = showTuiChoiceSheet<String>(
      hostContext,
      title: 'tmux',
      message: 'Attach to session',
      options: const [
        (value: 'main', label: 'main', meta: '2 windows'),
        (value: 'dev', label: 'dev', meta: '1 window'),
      ],
      selected: 'main',
    );
    await tester.pumpAndSettle();

    expect(find.text('main'), findsOneWidget);
    expect(find.text('2 windows'), findsOneWidget);

    await tester.tap(find.text('dev'));
    await tester.pumpAndSettle();
    expect(await result, 'dev');
  });

  testWidgets('loading sheet shows spinner label', (tester) async {
    await pumpHost(tester);

    showTuiLoadingSheet(
      hostContext,
      title: 'ssh',
      message: 'prod-west',
      loadingLabel: 'Connecting…',
      isDismissible: true,
      enableDrag: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byType(TuiSpinner), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Connecting…'), findsNothing);
  });

  testWidgets('custom sheet body via showTuiSheet', (tester) async {
    await pumpHost(tester);

    final result = showTuiSheet<String>(
      hostContext,
      builder: (ctx) => TuiSheet(
        title: 'custom',
        message: 'Hello sheet',
        actions: [
          TuiButton(label: 'done', onPressed: () => Navigator.pop(ctx, 'ok')),
        ],
        child: const Text('body-slot'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('body-slot'), findsOneWidget);
    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(await result, 'ok');
  });
}
