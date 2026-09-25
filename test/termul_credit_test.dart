import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Opens everything, and remembers what it was asked to open.
class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

void main() {
  test("termul's MIT notice is on the licences page, as every build ships "
      'it', () async {
    LicenseRegistry.reset();
    registerTermulLicense();

    final termul = (await LicenseRegistry.licenses.toList()).where(
      (entry) => entry.packages.contains('termul'),
    );
    expect(termul, hasLength(1));
    final text = termul.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Copyright (c) 2026 TUI-Termul'));
    expect(text, contains('Permission is hereby granted, free of charge'));
  });

  testWidgets('Settings credits termul and its author, each a link, beside '
      'the licences', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    final credit = find.bySemanticsLabel(
      'Design based on termul by Iyan Qalbi',
    );
    await tester.scrollUntilVisible(
      credit,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Whole, not just its top edge in view: Settings is a long list.
    await tester.ensureVisible(credit);
    await tester.pumpAndSettle();
    await tester.tap(credit);
    await tester.pumpAndSettle();
    final author = find.bySemanticsLabel('Iyan Qalbi on GitHub');
    await tester.ensureVisible(author);
    await tester.pumpAndSettle();
    await tester.tap(author);
    await tester.pumpAndSettle();
    expect(launcher.opened, [termulUrl, termulAuthorUrl]);

    final licences = find.bySemanticsLabel('Open-source licences');
    await tester.scrollUntilVisible(
      licences,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(licences);
    await tester.pumpAndSettle();
    await tester.tap(licences);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
