import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_brand_badge.dart';
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

  test('resolve prefers id then idLike then kernel', () {
    expect(TuiBrand.resolve('ubuntu').id, 'ubuntu');
    expect(TuiBrand.resolve('rocky', idLike: 'rhel centos fedora').id, 'rhel');
    expect(TuiBrand.resolve(null, kernel: 'Darwin').id, 'macos');
    expect(TuiBrand.resolve(null, kernel: 'Linux').id, 'linux');
    expect(TuiBrand.resolve('mystery').id, 'unknown');
  });

  testWidgets('renders monogram and version', (tester) async {
    await pumpHost(
      tester,
      const TuiBrandBadge(
        brand: TuiBrand.ubuntu,
        version: '24.04',
        active: true,
      ),
    );
    expect(find.text('Ub'), findsOneWidget);
    expect(find.text('24.04'), findsOneWidget);
    // Active corner mark is a 10×10 accent square overlay.
    expect(find.byType(TuiBrandBadge), findsOneWidget);
  });

  testWidgets('unknown brand uses fallback mark', (tester) async {
    await pumpHost(tester, const TuiBrandBadge());
    expect(find.text('∷'), findsOneWidget);
  });

  testWidgets('database brands', (tester) async {
    await pumpHost(
      tester,
      const Row(
        children: [
          TuiBrandBadge(brand: TuiBrand.postgres),
          TuiBrandBadge(brand: TuiBrand.mongo),
          TuiBrandBadge(brand: TuiBrand.redis),
        ],
      ),
    );
    expect(find.text('Pg'), findsOneWidget);
    expect(find.text('Mg'), findsOneWidget);
    expect(find.text('Rd'), findsOneWidget);
  });

  testWidgets('os factory resolves id', (tester) async {
    await pumpHost(tester, TuiBrandBadge.os(id: 'debian', version: '12'));
    expect(find.text('De'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
  });
}
