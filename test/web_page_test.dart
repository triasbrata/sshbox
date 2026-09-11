import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/web_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Stands in for Android System WebView, which does not run under
/// `flutter test`: it loads nothing and remembers what it was asked to, and
/// the test plays the page's side through the callbacks it was handed.
class _Platform extends WebViewPlatform {
  late _View view;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => view = _View(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Delegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
}

class _View extends PlatformWebViewController {
  _View(super.params) : super.implementation();

  final loaded = <Uri>[];
  late _Delegate page;
  String? title;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => page = handler as _Delegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loaded.add(params.uri);

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<String?> currentUrl() async => '${loaded.last}';

  @override
  Future<String?> getTitle() async => title;
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();

  late NavigationRequestCallback navigate;
  late PageEventCallback started;
  late PageEventCallback finished;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback c) async =>
      navigate = c;

  @override
  Future<void> setOnPageStarted(PageEventCallback c) async => started = c;

  @override
  Future<void> setOnPageFinished(PageEventCallback c) async => finished = c;

  @override
  Future<void> setOnProgress(ProgressCallback c) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback c) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  /// Holding focus, as the real view does once the page has been touched.
  @override
  Widget build(BuildContext context) =>
      const Focus(autofocus: true, child: SizedBox.expand());
}

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
  late _Platform platform;
  late _Launcher launcher;
  late List<(Uri, String?)> reported;

  Future<void> pumpPage(WidgetTester tester, String url) async {
    WebViewPlatform.instance = platform = _Platform();
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
}
