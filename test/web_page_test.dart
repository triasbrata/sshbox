import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/html_site.dart';
import 'package:sshbox/src/ui/web_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_file_browser.dart';
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

    await _touch(tester);
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

  group('a page that does not load', () {
    const message = 'Could not load the page: ';

    testWidgets('says why, and Reload comes back where Stop was', (
      tester,
    ) async {
      await pumpPage(tester, 'https://dart.dev/');
      platform.view.page.progress(40);
      await tester.pump();
      expect(find.byTooltip('Stop'), findsOneWidget);

      platform.view.page.failed(
        const WebResourceError(
          errorCode: -1004,
          description: 'Could not connect to the server.',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(
        find.text('${message}Could not connect to the server.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Stop'), findsNothing);
      expect(find.byTooltip('Reload'), findsOneWidget);

      // Loading again clears it.
      await tester.tap(find.byTooltip('Reload'));
      await tester.pump();
      expect(find.textContaining(message), findsNothing);
    });

    testWidgets('a picture or frame that fails is not the page failing', (
      tester,
    ) async {
      await pumpPage(tester, 'https://dart.dev/');
      for (final main in [false, null]) {
        platform.view.page.failed(
          WebResourceError(
            errorCode: -1,
            description: 'x',
            isForMainFrame: main,
          ),
        );
      }
      await tester.pump();
      expect(find.textContaining(message), findsNothing);
    });

    testWidgets('a load that says nothing for 30 s is said to be stuck', (
      tester,
    ) async {
      await pumpPage(tester, 'https://dart.dev/');
      await tester.pump(const Duration(seconds: 29));
      expect(find.textContaining(message), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('${message}no answer in 30 s'), findsOneWidget);
      expect(platform.view.scripts, contains('window.stop()'));
    });

    testWidgets('progress holds the clock off, and finishing stops it', (
      tester,
    ) async {
      await pumpPage(tester, 'https://dart.dev/');
      await tester.pump(const Duration(seconds: 20));
      platform.view.page.progress(50);
      await tester.pump(const Duration(seconds: 20));
      expect(find.textContaining(message), findsNothing);

      platform.view.page.finished('https://dart.dev/');
      await tester.pump(const Duration(seconds: 60));
      expect(find.textContaining(message), findsNothing);
    });
  });

  group('a page that navigates by itself', () {
    var now = DateTime(2026, 10, 11, 12);
    setUp(() => webGestureClock = () => now);
    tearDown(() => webGestureClock = DateTime.now);

    Future<NavigationDecision> go(String url, {bool main = true}) async =>
        platform.view.page.navigate(
          NavigationRequest(url: url, isMainFrame: main),
        );

    testWidgets('opens no other app until the page is touched', (tester) async {
      await pumpPage(tester, 'https://dart.dev/');
      // A meta refresh or a timer, over and over: nothing is launched.
      for (final url in ['mailto:me@box', 'tel:123']) {
        expect(await go(url), NavigationDecision.prevent, reason: url);
      }
      expect(launcher.tried, isEmpty);

      // A touch lets the next one through, once the page is on its way out.
      await _touch(tester);
      expect(await go('mailto:me@box'), NavigationDecision.prevent);
      expect(launcher.tried.map((t) => t.$1), ['mailto:me@box']);

      // And only for about a second.
      launcher.tried.clear();
      now = now.add(const Duration(milliseconds: 900));
      await go('tel:1');
      expect(launcher.tried.length, 1);
      now = now.add(const Duration(milliseconds: 200));
      await go('tel:2');
      expect(launcher.tried.length, 1);
    });

    testWidgets('Enter or Space on the page counts as a gesture', (
      tester,
    ) async {
      await pumpPage(tester, 'https://dart.dev/');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await go('tel:1');
      expect(launcher.tried, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await go('tel:2');
      expect(launcher.tried.map((t) => t.$1), ['tel:2']);
    });

    testWidgets('pages of its own tab load without a touch', (tester) async {
      await pumpPage(tester, 'https://dart.dev/');
      expect(await go('https://dart.dev/next'), NavigationDecision.navigate);
      expect(launcher.tried, isEmpty);
    });
  });

  group('an HTML file', () {
    late FakeFileBrowser files;
    HtmlSite? site;
    var starts = 0;

    Future<void> pumpHtml(WidgetTester tester, {bool fail = false}) async {
      WebViewPlatform.instance = platform = FakeWebViewPlatform();
      UrlLauncherPlatform.instance = launcher = _Launcher();
      files = FakeFileBrowser();
      await files.writeText('/home/me/site/page.html', '<h1>x</h1>');
      starts = 0;
      site = null;
      // Started in the real zone: the server's handlers must not wait on the
      // test's fake clock.
      final started = (await tester.runAsync(
        () =>
            HtmlSite.start(browser: files, htmlPath: '/home/me/site/page.html'),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebPage(
              initialUrl: Uri.parse('about:blank'),
              onChanged: (_, _) {},
              site: () async {
                starts++;
                if (fail) throw StateError('<b>gone</b>');
                return site = started;
              },
            ),
          ),
        ),
      );
      if (fail) await tester.runAsync(started.close);
      await tester.pump();
      await tester.pump();
    }

    Future<NavigationDecision> go(String url) async => platform.view.page
        .navigate(NavigationRequest(url: url, isMainFrame: true));

    testWidgets('is loaded from its own loopback address, under a token', (
      tester,
    ) async {
      await pumpHtml(tester);
      expect(platform.view.loaded, [site!.url]);
      expect(site!.url.host, '127.0.0.1');
      expect(site!.url.pathSegments, [site!.token, 'page.html']);
      expect(platform.view.htmls, isEmpty);
      // The address bar does not show the token.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });

    testWidgets(
      'Reload loads it again, with a clean budget, and starts one site',
      (tester) async {
        await pumpHtml(tester);
        final first = site!.url;
        await tester.runAsync(() async {
          await _ask(site!, 'none.css');
        });
        expect(site!.problems.value, isNotEmpty);
        await tester.tap(find.byTooltip('Reload'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(platform.view.loaded, [first, first]);
        expect(starts, 1);
        expect(site!.problems.value, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      },
    );

    testWidgets('says what the page asked for and did not get', (tester) async {
      await pumpHtml(tester);
      expect(find.textContaining('not loaded'), findsNothing);
      await tester.runAsync(() async {
        for (final name in ['gone.png', 'old.css']) {
          await _ask(site!, name);
        }
      });
      await tester.pump();
      expect(
        find.text('2 files not loaded: gone.png (missing), old.css (missing)'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });

    testWidgets('closing the tab stops the site', (tester) async {
      await pumpHtml(tester);
      final port = site!.url.port;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await expectLater(
          Socket.connect('127.0.0.1', port),
          throwsA(isA<SocketException>()),
        );
      });
    });

    testWidgets('a site that cannot start says so, escaped', (tester) async {
      await pumpHtml(tester, fail: true);
      expect(platform.view.htmls.single, contains('Could not open the file'));
      expect(platform.view.htmls.single, contains('&lt;b&gt;'));
      expect(platform.view.loaded, isEmpty);
    });

    testWidgets('a frame inside the page loads, a page-level launch waits '
        'for a touch', (tester) async {
      await pumpHtml(tester);
      expect(
        await platform.view.page.navigate(
          const NavigationRequest(
            url: 'https://cdn.example/player',
            isMainFrame: false,
          ),
        ),
        NavigationDecision.navigate,
      );
      // A frame is no way to reach another app.
      expect(
        await platform.view.page.navigate(
          const NavigationRequest(url: 'mailto:me@box', isMainFrame: false),
        ),
        NavigationDecision.prevent,
      );
      expect(launcher.tried, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });

    testWidgets('a tab closed while its site is starting leaves none running', (
      tester,
    ) async {
      WebViewPlatform.instance = platform = FakeWebViewPlatform();
      files = FakeFileBrowser();
      final started = (await tester.runAsync(
        () =>
            HtmlSite.start(browser: files, htmlPath: '/home/me/site/page.html'),
      ))!;
      final port = started.url.port;
      final ready = Completer<HtmlSite>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebPage(
              initialUrl: Uri.parse('about:blank'),
              onChanged: (_, _) {},
              site: () => ready.future,
            ),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      ready.complete(started);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await expectLater(
          Socket.connect('127.0.0.1', port),
          throwsA(isA<SocketException>()),
        );
      });
      expect(platform.view.loaded, isEmpty);
    });

    testWidgets('the view asking about the page it was just told to load is '
        'let through, as WKWebView asks', (tester) async {
      await pumpHtml(tester);
      expect(await go('${site!.url}'), NavigationDecision.navigate);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });

    testWidgets('its own pages and anchors stay, links leave through openUrl', (
      tester,
    ) async {
      await pumpHtml(tester);
      final own = site!.url;
      expect(await go('$own#top'), NavigationDecision.navigate);
      expect(
        await go(
          own.replace(pathSegments: [site!.token, 'next.html']).toString(),
        ),
        NavigationDecision.navigate,
      );
      expect(await go('about:blank#top'), NavigationDecision.navigate);

      await _touch(tester);
      // Loopback without the token, or on another port, is not the site.
      launcher.tried.clear();
      for (final url in [
        'http://127.0.0.1:${own.port}/other/page.html',
        'http://127.0.0.1:${own.port + 1}/${site!.token}/page.html',
        'http://localhost:${own.port}/${site!.token}/page.html',
      ]) {
        expect(await go(url), NavigationDecision.prevent, reason: url);
      }
      await tester.pump();
      expect(launcher.tried.length, 3);

      // An allowed link leaves, to the browser, and the tab stays.
      launcher.tried.clear();
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
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });
  });
}

/// One GET for [name] beside the site's page, over a raw socket: flutter_test
/// swaps dart:io's HttpClient for one that answers 400 to everything.
Future<int> _ask(HtmlSite site, String name) async {
  final socket = await Socket.connect('127.0.0.1', site.url.port);
  socket.write(
    'GET /${site.token}/$name HTTP/1.1\r\n'
    'Host: 127.0.0.1:${site.url.port}\r\nConnection: close\r\n\r\n',
  );
  final head = String.fromCharCodes(await socket.expand((b) => b).toList());
  socket.destroy();
  return int.parse(head.split(' ')[1]);
}

/// A finger lifted from the page, as the view reports none of its own.
Future<void> _touch(WidgetTester tester) =>
    tester.tapAt(tester.getCenter(find.byType(WebViewWidget)));
