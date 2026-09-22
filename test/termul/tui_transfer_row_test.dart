import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_transfer_row.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, {required Widget under}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        home: Scaffold(body: under),
      ),
    );
  }

  test('formatTuiBytes', () {
    expect(formatTuiBytes(500), '500 B');
    expect(formatTuiBytes(2048), '2.0 KB');
    expect(formatTuiBytes(1024 * 1024), '1.0 MB');
  });

  test('status line for running upload', () {
    expect(
      tuiTransferStatusLine(
        direction: TuiTransferDirection.upload,
        status: TuiTransferStatus.running,
        host: 'prod-west',
        doneBytes: 420000,
        totalBytes: 1000000,
        speedBytesPerSec: 82000,
      ),
      'Uploading to prod-west · 410.2 KB of 976.6 KB · 80.1 KB/s',
    );
  });

  test('status line for failure includes error', () {
    expect(
      tuiTransferStatusLine(
        direction: TuiTransferDirection.download,
        status: TuiTransferStatus.failed,
        host: 'db-1',
        error: 'permission denied',
      ),
      'Download from db-1 failed: permission denied',
    );
  });

  testWidgets('running row shows cancel and progress', (tester) async {
    var cancelled = false;
    await pumpHost(
      tester,
      under: TuiTransferRow(
        name: 'notes.md',
        direction: TuiTransferDirection.upload,
        status: TuiTransferStatus.running,
        host: 'prod-west',
        progress: 0.4,
        onCancel: () => cancelled = true,
      ),
    );

    expect(find.text('notes.md'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
    expect(find.textContaining('Uploading to prod-west'), findsOneWidget);

    await tester.tap(find.text('×'));
    expect(cancelled, isTrue);
  });

  testWidgets('done row offers open', (tester) async {
    var opened = false;
    await pumpHost(
      tester,
      under: TuiTransferRow(
        name: 'dump.sql.gz',
        direction: TuiTransferDirection.download,
        status: TuiTransferStatus.done,
        onOpen: () => opened = true,
      ),
    );

    await tester.tap(find.text('OPEN'));
    expect(opened, isTrue);
  });

  testWidgets('failed row offers retry', (tester) async {
    var retried = false;
    await pumpHost(
      tester,
      under: TuiTransferRow(
        name: 'secret.env',
        direction: TuiTransferDirection.download,
        status: TuiTransferStatus.failed,
        error: 'permission denied',
        onRetry: () => retried = true,
      ),
    );

    expect(find.textContaining('permission denied'), findsOneWidget);
    await tester.tap(find.text('RETRY'));
    expect(retried, isTrue);
  });
}
