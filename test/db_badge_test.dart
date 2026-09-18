import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/ui/db_editor_page.dart';
import 'package:sshbox/src/ui/settings_page.dart' show nerdFontFamily;

void main() {
  test('every kind has a brand mark of its own', () {
    final brands = {for (final kind in DbKind.values) kind: dbBrand(kind)};

    // None falls through to the generic badge. A kind added to DbKind
    // without a mark fails here rather than shipping as a plain database.
    expect(brands.values, everyElement(isNotNull));
    // And no two databases wear the same mark or the same colour.
    expect(
      {for (final brand in brands.values) brand!.glyph},
      hasLength(DbKind.values.length),
    );
    expect(
      {for (final brand in brands.values) brand!.color},
      hasLength(DbKind.values.length),
    );

    // The devicon block of the bundled Nerd Font: PostgreSQL's elephant,
    // MongoDB's leaf, Redis's stack.
    expect(dbBrand(DbKind.postgres)!.glyph, 0xe76e);
    expect(dbBrand(DbKind.mongo)!.glyph, 0xe7a4);
    expect(dbBrand(DbKind.redis)!.glyph, 0xe76d);
  });

  testWidgets('a badge draws its own kind in the Nerd Font, in either theme, '
      'at the card size and the tab chip\'s', (tester) async {
    for (final brightness in Brightness.values) {
      // The Home card's badge, and the smaller one on a tab chip.
      for (final size in [40.0, 16.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Column(
                children: [
                  for (final kind in DbKind.values) DbBadge(kind, size: size),
                ],
              ),
            ),
          ),
        );

        for (final kind in DbKind.values) {
          final mark = find.text(String.fromCharCode(dbBrand(kind)!.glyph));
          expect(mark, findsOneWidget);
          final style = tester.widget<Text>(mark).style!;
          expect(style.fontFamily, nerdFontFamily);
          // White on the brand's own colour, so it reads the same whatever
          // the theme behind it is.
          expect(style.color, Colors.white);
          expect(style.fontSize, lessThanOrEqualTo(size));
        }

        // The badge keeps the side it is given, so it neither breaks the
        // card's row nor outgrows a tab chip.
        expect(
          tester.getSize(find.byType(DbBadge).first),
          Size(size, size),
        );
      }
    }
  });
}
