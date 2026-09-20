// A spike, to answer one question: can the real Jeansh be driven on a real
// desktop embedder, natively and with no display a person could look at?
//
// Everything under test/ runs under `flutter test`, which reports Android, so
// `isDesktop` is false there and desktop_test.dart fakes the platform with
// debugDefaultTargetPlatformOverride. Nothing has ever exercised the GTK
// embedder, the real plugins, or a real window. This does.
//
//   xvfb-run -a flutter test integration_test/desktop_smoke_test.dart -d linux

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/platform.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app boots on the real desktop embedder', (tester) async {
    // No override: this is whatever the embedder really reports, which is the
    // whole point of running here rather than under flutter test.
    expect(defaultTargetPlatform, TargetPlatform.linux);
    expect(isDesktop, isTrue);

    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Home drew. If a plugin threw on the way — secure storage with no Secret
    // Service, notifications, app_links — this is where it shows.
    expect(find.text('Jeansh'), findsWidgets);
    expect(find.text('Terminal buddy in your pocket'), findsOneWidget);
  });

  testWidgets('a desktop offers the local shell', (tester) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Desktop only: a real pty through flutter_pty. On a phone there is none.
    expect(find.text('Local shell'), findsOneWidget);
  });
}
