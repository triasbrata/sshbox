import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Stands in for Android System WebView, which does not run under
/// `flutter test`: it loads nothing and remembers what it was asked to, and
/// the test plays the page's side through the callbacks it was handed.
class FakeWebViewPlatform extends WebViewPlatform {
  late FakeWebView view;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => view = FakeWebView(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
}

class FakeWebView extends PlatformWebViewController {
  FakeWebView(super.params) : super.implementation();

  final loaded = <Uri>[];
  final assets = <String>[];
  final scripts = <String>[];
  final channels = <String, JavaScriptChannelParams>{};
  late FakeNavigationDelegate page;
  String? title;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> loadFlutterAsset(String key) async => assets.add(key);

  @override
  Future<void> runJavaScript(String javaScript) async => scripts.add(javaScript);

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channels[params.name] = params;

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => page = handler as FakeNavigationDelegate;

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

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

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
