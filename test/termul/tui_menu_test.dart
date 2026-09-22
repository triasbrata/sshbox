import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_menu.dart';
import 'package:sshbox/src/ui/termul/tui_toast.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  late BuildContext hostContext;

  Future<void> pumpHost(WidgetTester tester, {Widget? under}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        builder: (context, child) => TuiToastHost(child: child!),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return Scaffold(body: under ?? const SizedBox.expand());
          },
        ),
      ),
    );
  }

  testWidgets('showTuiMenu at position returns selected value', (tester) async {
    await pumpHost(tester);

    final result = showTuiMenu<String>(
      hostContext,
      at: const Offset(40, 80),
      entries: const [
        TuiMenuItem(value: 'edit', label: 'Edit'),
        TuiMenuDivider(),
        TuiMenuItem(value: 'delete', label: 'Delete', destructive: true),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await result, 'delete');
  });

  testWidgets('disabled item is not selectable', (tester) async {
    await pumpHost(tester);

    final result = showTuiMenu<String>(
      hostContext,
      at: const Offset(40, 80),
      entries: const [
        TuiMenuItem(value: 'copy', label: 'Copy'),
        TuiMenuItem(value: 'link', label: 'Copy link', enabled: false),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    // Menu still open — disabled tap does nothing.
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(await result, 'copy');
  });

  testWidgets('TuiMenuButton opens below anchor', (tester) async {
    String? picked;
    await pumpHost(
      tester,
      under: Center(
        child: TuiMenuButton<String>(
          entries: const [
            TuiMenuItem(value: 'attach', label: 'Attach tmux'),
            TuiMenuItem(value: 'edit', label: 'Edit'),
          ],
          onSelected: (v) => picked = v,
        ),
      ),
    );

    await tester.tap(find.text('⋮'));
    await tester.pumpAndSettle();
    expect(find.text('Attach tmux'), findsOneWidget);

    await tester.tap(find.text('Attach tmux'));
    await tester.pumpAndSettle();
    expect(picked, 'attach');
  });

  testWidgets('TuiContextMenuRegion opens on long press', (tester) async {
    String? picked;
    await pumpHost(
      tester,
      under: Center(
        child: TuiContextMenuRegion<String>(
          entries: const [TuiMenuItem(value: 'paste', label: 'Paste')],
          onSelected: (v) => picked = v,
          child: const SizedBox(
            key: Key('ctx-target'),
            width: 120,
            height: 80,
            child: ColoredBox(color: Colors.grey),
          ),
        ),
      ),
    );

    await tester.longPress(find.byKey(const Key('ctx-target')));
    await tester.pumpAndSettle();
    expect(find.text('Paste'), findsOneWidget);

    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(picked, 'paste');
  });

  testWidgets('checked item shows mark', (tester) async {
    await pumpHost(tester);

    showTuiMenu<String>(
      hostContext,
      at: const Offset(40, 80),
      entries: const [
        TuiMenuItem(value: 'wrap', label: 'Word wrap', checked: true),
        TuiMenuItem(value: 'map', label: 'Minimap', checked: false),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('✓'), findsOneWidget);
    expect(find.text('Word wrap'), findsOneWidget);
  });
}
