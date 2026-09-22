import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_dropdown.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  testWidgets('shows label, value, and opens options', (tester) async {
    String? value = 'a';
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiDropdown<String>(
            label: 'Jump host',
            value: value,
            searchable: false,
            options: const [
              TuiDropdownOption(value: 'a', label: 'bastion'),
              TuiDropdownOption(value: 'b', label: 'edge-west'),
            ],
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    expect(find.text('JUMP HOST'), findsOneWidget);
    expect(find.text('bastion'), findsOneWidget);

    await tester.tap(find.text('bastion'));
    await tester.pumpAndSettle();
    expect(find.text('edge-west'), findsOneWidget);

    await tester.tap(find.text('edge-west'));
    await tester.pumpAndSettle();
    expect(value, 'b');
    expect(find.text('edge-west'), findsOneWidget);
  });

  testWidgets('search filters long lists', (tester) async {
    await pumpHost(
      tester,
      TuiDropdown<String>(
        label: 'Host',
        value: null,
        searchable: true,
        options: [
          for (var i = 0; i < 12; i++)
            TuiDropdownOption(value: 'h$i', label: 'host-$i'),
        ],
        onChanged: (_) {},
      ),
    );

    await tester.tap(find.text('Select…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('host-0'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'host-11');
    await tester.pump();
    expect(find.text('host-11'), findsWidgets); // field + row
    expect(find.text('host-0'), findsNothing);
  });

  testWidgets('allowClear returns null', (tester) async {
    String? value = 'a';
    await pumpHost(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          return TuiDropdown<String>(
            label: 'Jump',
            value: value,
            allowClear: true,
            emptyLabel: 'Direct',
            searchable: false,
            options: const [TuiDropdownOption(value: 'a', label: 'bastion')],
            onChanged: (v) => setState(() => value = v),
          );
        },
      ),
    );

    await tester.tap(find.text('bastion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();
    expect(value, isNull);
    expect(find.text('Select…'), findsOneWidget);
  });

  testWidgets('error and disabled states', (tester) async {
    await pumpHost(
      tester,
      const TuiDropdown<String>(
        label: 'Host',
        value: null,
        hint: 'Choose…',
        errorText: 'Required',
        enabled: false,
        options: [TuiDropdownOption(value: 'a', label: 'a')],
      ),
    );
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Choose…'), findsOneWidget);
    await tester.tap(find.text('Choose…'));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
  });
}
