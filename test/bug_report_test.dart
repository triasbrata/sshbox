import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/telemetry/telemetry.dart';
import 'package:sshbox/src/ui/bug_report.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/toast.dart';
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

/// Stands in for the relay: nothing here reaches the network.
class _Net {
  final sent = <(Uri, String)>[];

  Future<({int status, String body})> post(Uri url, String body) async {
    sent.add((url, body));
    return (status: 200, body: '{"url":"https://github.test/issues/7"}');
  }
}

void main() {
  late _Launcher launcher;
  late _Net net;
  late Telemetry relay;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Jeansh',
      packageName: 'cloud.brata.terminal',
      version: '1.0.62',
      buildNumber: '66',
      buildSignature: '',
    );
    UrlLauncherPlatform.instance = launcher = _Launcher();
    net = _Net();
    relay = Telemetry(post: net.post, host: 'https://t.test');
    telemetryOn.value = true;
  });

  Future<void> open(
    WidgetTester tester, {
    String? about,
    String write = 'the tab froze',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ToastLayer(
          child: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () =>
                    showBugReport(context, about: about, using: relay),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    if (write.isNotEmpty) {
      await tester.enterText(find.byType(TextField), write);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('shows what will be sent, and sends nothing until asked', (
    tester,
  ) async {
    await open(tester, write: '');
    expect(find.text('This is everything that will be sent:'), findsOne);
    // With nothing written there is nothing to send.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Under my name'))
          .onPressed,
      isNull,
    );
    expect(net.sent, isEmpty);
    expect(launcher.opened, isEmpty);
  });

  testWidgets('the preview holds the version and never the host', (
    tester,
  ) async {
    await open(
      tester,
      write: 'cannot open my-box.ts.net',
      about:
          'SocketException: failed for trias@my-box.ts.net at '
          '/home/trias/.ssh/config',
    );
    final shown = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((text) => text.data ?? '')
        .join('\n');
    expect(shown, contains('1.0.62+66'));
    expect(shown, isNot(contains('my-box')));
    expect(shown, isNot(contains('trias')));
    expect(shown, contains('<host>'));
  });

  testWidgets('under my name, it opens GitHub and sends nothing itself', (
    tester,
  ) async {
    await open(tester, write: 'the tab froze on my-box.ts.net');
    await tester.tap(find.text('Under my name'));
    await tester.pumpAndSettle();
    expect(net.sent, isEmpty);
    final url = Uri.parse(launcher.opened.single);
    expect(url.host, 'github.com');
    expect(url.path, '/triasbrata/sshbox/issues/new');
    expect(url.queryParameters['title'], 'the tab froze on <host>');
    expect(url.queryParameters['body'], contains('1.0.62+66'));
    expect(launcher.opened.single, isNot(contains('my-box')));
  });

  testWidgets('a long report is cut to fit in a link, and says it was', (
    tester,
  ) async {
    await open(tester, write: 'the tab froze again and again. ' * 400);
    await tester.tap(find.text('Under my name'));
    await tester.pumpAndSettle();
    expect(launcher.opened.single.length, lessThanOrEqualTo(maxIssueUrl));
    expect(
      Uri.parse(launcher.opened.single).queryParameters['body'],
      contains('cut short'),
    );
  });

  testWidgets('anonymously, it posts to the relay and says where it went', (
    tester,
  ) async {
    await open(tester, write: 'the tab froze');
    await tester.tap(find.text('Anonymously'));
    // The post, then the toast's overlay and its slide in, as the other page
    // tests pump one: pumpAndSettle alone pumps right through its five
    // seconds and finds nothing left on screen.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(launcher.opened, isEmpty);
    final body = jsonDecode(net.sent.single.$2) as Map<String, Object?>;
    expect(net.sent.single.$1.toString(), 'https://t.test/issue');
    expect(body['title'], 'the tab froze');
    // The maintainer has to know nobody can be written back to.
    expect(body['body'], contains('no way to reply'));
    expect(find.textContaining('https://github.test/issues/7'), findsOne);
    await tester.pumpAndSettle();
  });

  testWidgets('it still works with telemetry off — the user pressed it', (
    tester,
  ) async {
    telemetryOn.value = false;
    await open(tester, write: 'the tab froze');
    await tester.tap(find.text('Anonymously'));
    await tester.pumpAndSettle();
    expect(net.sent, hasLength(1));
  });

  group('the switch in Settings', () {
    Future<void> settings(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ToastLayer(child: SettingsPage())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Telemetry'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('is on to begin with, and saves being turned off', (
      tester,
    ) async {
      await telemetryOn.load();
      await settings(tester);
      final row = find.widgetWithText(SwitchListTile, 'Telemetry');
      expect(tester.widget<SwitchListTile>(row).value, isTrue);
      expect(
        find.textContaining('No hostname, username, path or command'),
        findsOne,
      );

      await tester.tap(find.byType(Switch).hitTestable().first);
      await tester.pumpAndSettle();
      expect(telemetryOn.value, isFalse);
      expect(find.textContaining('Nothing is sent'), findsOne);

      // And it is the saved answer next time.
      telemetryOn.value = true;
      await telemetryOn.load();
      expect(telemetryOn.value, isFalse);
    });

    testWidgets('Report a bug sits beside it', (tester) async {
      await settings(tester);
      expect(find.text('Report a bug'), findsOne);
    });
  });
}
