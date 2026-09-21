import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

/// The e2e gate's host, named as the flows name it. Its address refuses at
/// once, so the connect a tap starts ends here rather than out on a network.
const _host = HostProfile(
  id: 'h1',
  label: 'WSL via tailnet',
  host: '127.0.0.1',
  port: 1,
  username: 'e2e',
);

/// What the app finds saved after a live session was killed with it: the
/// host, and that session's tab.
Map<String, Object> _killedLive() => {
  'sshbox.hosts.v1': jsonEncode([_host.toJson()]),
  // Past the first run's word about telemetry, which would lie over Home.
  'sshbox.telemetry.notice': true,
  'sshbox.tabs.v1': jsonEncode({
    'sessions': [
      {'hostId': 'h1', 'tmux': 'sshbox-abc', 'files': [], 'web': []},
    ],
    'databases': [],
  }),
};

/// The platform's half of what the app asks as it starts, answered as a
/// device with nothing to say: nothing shared, no notification up, and no
/// link — unless [launchedBy] is one, as a tapped notification's is.
void _quietPlatform(WidgetTester tester, {String? launchedBy}) {
  final messenger = tester.binding.defaultBinaryMessenger;
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  messenger.setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (call) async => switch (call.method) {
      'initialize' || 'requestNotificationsPermission' => true,
      'getActiveNotifications' => const <Object>[],
      _ => null,
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('sshbox/share'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (call) async => call.method == 'getInitialLink' ? launchedBy : null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
}

/// Starts the app as Android does after its process died, over whatever
/// was saved when it went. A new key is a new app: the one before is let go
/// as a killed one would be, saving nothing on its way out.
Future<void> _start(WidgetTester tester) async {
  await tester.pumpWidget(SshboxApp(key: UniqueKey()));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The tab strip's own copy of a name, rather than the host card's.
Finder _onStrip(Finder finder) =>
    find.descendant(of: find.byType(TabStrip), matching: finder);

Future<Object?> _savedTabs() async => jsonDecode(
  (await SharedPreferences.getInstance()).getString('sshbox.tabs.v1')!,
);

/// Where a Maestro `tapOn` given [text] lands: of the nodes a screen reader
/// sees whose text matches, each traded for the deepest node under it that
/// matches too, the first a tap can land on, in the order a hierarchy dump
/// reads them. A node's text is everything it says: its label, its value
/// and its tooltip, which Android hands over as the node's tooltipText.
SemanticsNode? _maestroTap(WidgetTester tester, RegExp text) {
  bool matches(SemanticsNode node) {
    final data = node.getSemanticsData();
    return text.hasMatch(
      [data.label, data.value, data.tooltip].where((s) => s.isNotEmpty).join(),
    );
  }

  List<SemanticsNode> deepest(SemanticsNode node) {
    final under = <SemanticsNode>[];
    node.visitChildren((child) {
      under.addAll(deepest(child));
      return true;
    });
    return under.isNotEmpty || !matches(node) ? under : [node];
  }

  final root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  return deepest(root)
      .where((node) => node.getSemanticsData().hasAction(SemanticsAction.tap))
      .firstOrNull;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(_killedLive()));

  testWidgets('after a live session was killed, its tab is back on the strip '
      'and a tap on the host opens a connect sheet, however many starts '
      'it has sat through', (tester) async {
    _quietPlatform(tester);
    // `logs`, in the e2e gate: a start that taps no host.
    await _start(tester);
    expect(_onStrip(find.text('WSL via tailnet')), findsOneWidget);
    // `duplicate_session`: the start after it, which taps the host.
    await _start(tester);
    expect(_onStrip(find.text('WSL via tailnet')), findsOneWidget);

    await tester.tap(find.text('e2e@127.0.0.1:1'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(BottomSheet), findsOneWidget);
    // The tab the killed session left is still there, for its own tap.
    expect(_onStrip(find.text('WSL via tailnet')), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('what the e2e flows tap as the host, with a killed session\'s '
      'tab on the strip, is that tab\'s close button: the tab goes, nothing '
      'opens, and the next start has no tab to be caught by', (tester) async {
    _quietPlatform(tester);
    final semantics = tester.ensureSemantics();
    await _start(tester);

    // The flows' own selector for the host: `(?s).*${HOST_LABEL}.*`. A tab
    // never connected since it came back is named after its host, and so is
    // its close button, which comes first — above the host's card, and under
    // the tab's own name, which it is traded for as the deeper match.
    final tapped = _maestroTap(tester, RegExp(r'^.*WSL via.*$', dotAll: true));
    expect(tapped?.getSemanticsData().tooltip, 'Close WSL via tailnet');

    await tester.tap(find.byTooltip('Close WSL via tailnet'));
    await tester.pump();
    await tester.pump();
    // The failure's screenshot: Home alone, no sheet, no tab, and nothing
    // said — and no connect, which is why sshd logged no login for it.
    expect(_onStrip(find.text('WSL via tailnet')), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    // Closing it saved no tabs, which is why the flow after `tabs` found the
    // host and connected, while `logs`, which taps nothing, left the tab
    // there for `duplicate_session` to close.
    expect(await _savedTabs(), {'sessions': [], 'databases': []});
    await _start(tester);
    expect(_onStrip(find.text('WSL via tailnet')), findsNothing);

    semantics.dispose();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a notification for a host deleted since says so, rather than '
      'opening nothing without a word', (tester) async {
    _quietPlatform(tester, launchedBy: 'sshbox://host/deleted');
    await _start(tester);
    expect(find.text('That host is no longer saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
