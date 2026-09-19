import 'package:flutter/foundation.dart';

/// Whether this build draws for a desktop — a real keyboard, a mouse, and a
/// browser of the user's own already on the machine.
///
/// Read through [defaultTargetPlatform] rather than `dart:io`'s [Platform] so
/// a widget test sees whatever it overrides, and so the app under
/// `flutter test` — which reports Android — keeps the phone's layout, the one
/// almost every test was written against.
///
/// What it turns off is everything that stands in for a missing keyboard: the
/// key bar, the magic key, and web pages in tabs of our own. What it turns on
/// is the local shell, which only a desktop can run — see `LocalTransport`.
bool get isDesktop => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// Whether webview_flutter can draw a page here. It has Android, iOS and
/// macOS and nothing else: on Linux or Windows the first `WebViewController`
/// throws, so what would be a web view there has to be something else.
bool get hasWebView => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => true,
  _ => false,
};
