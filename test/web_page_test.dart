import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/web_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

/// Opens everything, and remembers how it was asked to.
class _Launcher extends UrlLauncherPlatform {
  final tried = <(String, PreferredLaunchMode)>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    tried.add((url, options.mode));
    return true;
  }
}

void main() {
  late FakeWebViewPlatform platform;
  late _Launcher launcher;
  late List<(Uri, String?)> reported;

  Future<void> pumpPage(WidgetTester tester, String url) async {
    WebViewPlatform.instance = platform = FakeWebViewPlatform();
    UrlLauncherPlatform.instance = launcher = _Launcher();
    reported = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebPage(
            initialUrl: Uri.parse(url),
            onChanged: (url, title) => reported.add((url, title)),
          ),
        ),
      ),
    );
  }

  testWidgets('loads its link, and names the tab by the page once loaded', (
    tester,
  ) async {
    const url = 'http://box.ts.net:3001/';
    await pumpPage(tester, url);
    final view = platform.view;
    expect(view.loaded, [Uri.parse(url)]);

    view.page.started(url);
    expect(reported.last, (Uri.parse(url), null));

    view.title = 'Vite + React';
    view.page.finished(url);
    await tester.pump();
    expect(reported.last, (Uri.parse(url), 'Vite + React'));
  });

  testWidgets('a mailto: goes to the phone, a download to the browser', (
    tester,
  ) async {
    await pumpPage(tester, 'https://dart.dev/');
    Future<NavigationDecision> go(String url) async => platform.view.page
        .navigate(NavigationRequest(url: url, isMainFrame: true));

    expect(await go('https://dart.dev/get-dart'), NavigationDecision.navigate);
    expect(launcher.tried, isEmpty);

    expect(await go('mailto:me@box'), NavigationDecision.prevent);
    expect(launcher.tried.last, (
      'mailto:me@box',
      PreferredLaunchMode.platformDefault,
    ));

    // Android asks again for an address it is already loading when the
    // answer turns out to be a file: loading it again would only loop.
    expect(await go('https://dart.dev/get-dart'), NavigationDecision.prevent);
    expect(launcher.tried.last, (
      'https://dart.dev/get-dart',
      PreferredLaunchMode.inAppBrowserView,
    ));
  });

  testWidgets('an address typed without a scheme goes over https', (
    tester,
  ) async {
    await pumpPage(tester, 'https://dart.dev/');

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'pub.dev/packages ');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();

    expect(platform.view.loaded.last, Uri.parse('https://pub.dev/packages'));
  });

  testWidgets('hardware keys go to the page rather than moving focus', (
    tester,
  ) async {
    await pumpPage(tester, 'https://dart.dev/');
    await tester.pump();
    final view = FocusManager.instance.primaryFocus;
    expect(view, isNotNull);

    for (final key in [LogicalKeyboardKey.tab, LogicalKeyboardKey.arrowUp]) {
      // Left unhandled here is what hands a key on to the platform view.
      expect(await tester.sendKeyEvent(key), isFalse);
      expect(FocusManager.instance.primaryFocus, same(view));
    }
  });

  group('an HTML file', () {
    var reads = 0;
    Future<void> pumpHtml(WidgetTester tester, {bool fail = false}) async {
      WebViewPlatform.instance = platform = FakeWebViewPlatform();
      UrlLauncherPlatform.instance = launcher = _Launcher();
      reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebPage(
              initialUrl: Uri.parse('about:blank'),
              onChanged: (_, _) {},
              html: () async {
                reads++;
                if (fail) throw StateError('<b>gone</b>');
                return '<h1>Report $reads</h1>';
              },
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<NavigationDecision> go(String url) async => platform.view.page
        .navigate(NavigationRequest(url: url, isMainFrame: true));

    testWidgets('is loaded as text, with no address and no origin', (
      tester,
    ) async {
      await pumpHtml(tester);
      expect(platform.view.htmls, ['<h1>Report 1</h1>']);
      expect(platform.view.loaded, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    });

    testWidgets('Reload reads the file again', (tester) async {
      await pumpHtml(tester);
      await tester.tap(find.byTooltip('Reload'));
      await tester.pump();
      expect(platform.view.htmls, ['<h1>Report 1</h1>', '<h1>Report 2</h1>']);
    });

    testWidgets('a file that cannot be read says so, escaped', (tester) async {
      await pumpHtml(tester, fail: true);
      expect(platform.view.htmls.single, contains('Could not open the file'));
      expect(platform.view.htmls.single, contains('&lt;b&gt;'));
    });

    testWidgets('its own anchors stay, links leave through openUrl', (
      tester,
    ) async {
      await pumpHtml(tester);
      expect(await go('about:blank#top'), NavigationDecision.navigate);

      // An allowed link leaves, to the browser, and the tab stays.
      expect(await go('https://dart.dev/'), NavigationDecision.prevent);
      expect(launcher.tried.last.$1, 'https://dart.dev/');

      // None of these reach the launcher at all.
      launcher.tried.clear();
      for (final url in [
        'file:///etc/passwd',
        'intent://x#Intent;scheme=http;end',
        'sshbox://host/local',
        'javascript:alert(1)',
      ]) {
        expect(await go(url), NavigationDecision.prevent, reason: url);
      }
      await tester.pump();
      expect(launcher.tried, isEmpty);
    });
  });
}
