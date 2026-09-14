import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/mermaid_view.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

const _page =
    'file:///android_asset/flutter_assets/assets/mermaid/mermaid.html';

void main() {
  late FakeWebViewPlatform platform;
  setUp(() => WebViewPlatform.instance = platform = FakeWebViewPlatform());

  testWidgets('hands the source over as data, and takes back only a height',
      (tester) async {
    // Would break out of a string pasted into the script.
    const source = 'flowchart LR\n  A["\\"); alert(1); //"] --> B\n';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MermaidView(source: source)),
        ),
      ),
    );
    final view = platform.view;
    expect(view.assets, ['assets/mermaid/mermaid.html']);
    expect(view.scripts, isEmpty);

    view.page.finished(_page);
    expect(view.scripts.single, startsWith('render(${jsonEncode(source)}, {'));

    double height() => tester.getSize(find.byType(MermaidView)).height;
    void say(String message) => view.channels['Height']!.onMessageReceived(
      JavaScriptMessage(message: message),
    );
    say('321');
    await tester.pump();
    expect(height(), 321);

    for (final junk in ['', 'tall', 'NaN', 'Infinity', '{"height":5}']) {
      say(junk);
      await tester.pump();
      expect(height(), 321, reason: junk);
    }
    say('1e9');
    await tester.pump();
    expect(height(), lessThan(4100));
  });

  testWidgets('goes nowhere but its own page', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MermaidView(source: 'pie\n  "a": 1\n')),
    );
    Future<NavigationDecision> go(String url) async => platform.view.page
        .navigate(NavigationRequest(url: url, isMainFrame: true));

    expect(await go(_page), NavigationDecision.navigate);
    for (final url in [
      'https://example.com/',
      'file:///data/data/cloud.brata.terminal/shared_prefs/x.xml',
      'javascript:alert(1)',
      'intent://x#Intent;end',
    ]) {
      expect(await go(url), NavigationDecision.prevent, reason: url);
    }
  });
}
