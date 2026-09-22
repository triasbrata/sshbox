import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/settings_page.dart';
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
/// host, and that session's tab — or the tabs named by the tmux sessions in
/// [tabs].
Map<String, Object> _killedLive({
  HostProfile host = _host,
  List<String> tabs = const ['sshbox-abc'],
}) => {
  'sshbox.hosts.v1': jsonEncode([host.toJson()]),
  // Past the first run's word about telemetry, which would lie over Home.
  'sshbox.telemetry.notice': true,
  'sshbox.tabs.v1': jsonEncode({
    'sessions': [
      for (final tmux in tabs)
        {'hostId': host.id, 'tmux': tmux, 'files': [], 'web': []},
    ],
    'databases': [],
  }),
};

/// The same host with tmux on, which is what a killed session's tab is
/// worth coming back to for.
final _tmuxHost = _host.copyWith(useTmux: true);

/// A host that is up the moment it is asked for, and answers whether a tmux
/// session is there with [tmuxThere]. It cannot start tmux itself, so a tab
/// falls back to a plain shell, but what it was asked to attach is in
/// [attached], by name, in the order asked.
class _Box
    implements
        SessionTransport,
        TerminalSession,
        CommandCapable,
        ChannelCapable {
  _Box({this.tmuxThere = true});

  bool tmuxThere;
  final attached = <String>[];
  final checked = <String>[];

  /// The hosts connected to, by id, in the order asked.
  final connected = <String>[];

  /// The quoted name a tmux command for one tab ends with.
  static final _name = RegExp(r"sh '(sshbox-[0-9a-z]+)'$");

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    connected.add(host.id);
    return this;
  }

  @override
  Stream<String> run(String command, {bool pty = false}) {
    final name = _name.firstMatch(command)?.group(1);
    if (command.contains('has-session') && name != null) {
      checked.add(name);
      return Stream.value(tmuxThere ? 'yes' : 'no');
    }
    return const Stream.empty();
  }

  @override
  Future<CommandChannel> open(String command) async {
    final name = _name.firstMatch(command)?.group(1);
    if (name != null) attached.add(name);
    throw const SshSessionException('tmux will not start here');
  }

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}
}

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
Future<void> _start(WidgetTester tester, {_Box? over}) async {
  await tester.pumpWidget(
    SshboxApp(
      key: UniqueKey(),
      transport: over == null ? null : (_, _) => over,
    ),
  );
  await _settle(tester);
}

/// This machine's own shells as they were before they ran in tmux, for a
/// test about something else: [_Box] cannot start tmux, and a shell that
/// asked for it would say so over the tab strip.
void _plainLocalShells() {
  localTmux.value = (on: false, path: '');
  addTearDown(() => localTmux.value = (on: true, path: ''));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Back to Home, a tap on the host's card, and the connect it starts, to
/// its end.
Future<void> _tapCard(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Home'));
  await tester.pump();
  await tester.tap(find.text('e2e@127.0.0.1:1'));
  await _settle(tester);
}

/// The tmux sessions of the tabs on the strip, in its order, as saved.
Future<List<Object?>> _savedTmux() async => [
  for (final tab in ((await _savedTabs())! as Map)['sessions'] as List)
    (tab as Map)['tmux'],
];

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

  testWidgets('a tap on the card connects the tabs a killed app left, first '
      'on the strip first, and opens a new tab once none is left', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(
      _killedLive(host: _tmuxHost, tabs: ['sshbox-one', 'sshbox-two']),
    );
    _quietPlatform(tester);
    final box = _Box();
    await _start(tester, over: box);
    expect(box.attached, isEmpty);

    // Each tab asks first whether its session is still there, and joins it:
    // no new tab, no new session.
    await _tapCard(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(box.checked, ['sshbox-one']);
    expect(box.attached, ['sshbox-one']);
    expect(await _savedTmux(), ['sshbox-one', 'sshbox-two']);

    await _tapCard(tester);
    expect(box.attached, ['sshbox-one', 'sshbox-two']);
    expect(await _savedTmux(), ['sshbox-one', 'sshbox-two']);

    // Only connected tabs now: another session, as a tap always opened.
    await _tapCard(tester);
    expect(box.checked, ['sshbox-one', 'sshbox-two']);
    expect(box.attached, hasLength(3));
    expect(box.attached.last, isNot(anyOf('sshbox-one', 'sshbox-two')));
    expect(await _savedTmux(), ['sshbox-one', 'sshbox-two', box.attached.last]);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('with no tab for the host, a tap on the card opens one, and '
      'another tap another', (tester) async {
    SharedPreferences.setMockInitialValues(
      _killedLive(host: _tmuxHost, tabs: []),
    );
    _quietPlatform(tester);
    final box = _Box();
    await _start(tester, over: box);

    await _tapCard(tester);
    expect(box.attached, hasLength(1));
    expect(await _savedTmux(), box.attached);

    await _tapCard(tester);
    expect(box.attached, hasLength(2));
    expect(box.attached.toSet(), hasLength(2));
    expect(await _savedTmux(), box.attached);
    // Neither was brought back, so neither was asked about first.
    expect(box.checked, isEmpty);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('Duplicate session on a tab brought back opens a copy, and '
      'leaves that tab for the card', (tester) async {
    SharedPreferences.setMockInitialValues(_killedLive(host: _tmuxHost));
    _quietPlatform(tester);
    final box = _Box();
    await _start(tester, over: box);

    await tester.longPress(_onStrip(find.text('WSL via tailnet')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate session'));
    await _settle(tester);
    expect(box.attached, hasLength(1));
    expect(box.attached.single, isNot('sshbox-abc'));
    expect(await _savedTmux(), ['sshbox-abc', box.attached.single]);

    await _tapCard(tester);
    expect(box.attached.last, 'sshbox-abc');
    expect(await _savedTmux(), hasLength(2));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a tab brought back whose tmux session has gone, reached from '
      'the card, says so and starts a new one in the same tab', (tester) async {
    SharedPreferences.setMockInitialValues(_killedLive(host: _tmuxHost));
    _quietPlatform(tester);
    final box = _Box(tmuxThere: false);
    await _start(tester, over: box);

    await _tapCard(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.textContaining('sshbox-abc is no longer on'), findsWidgets);
    expect(box.attached, isEmpty);

    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Start a new session'),
      ),
    );
    await _settle(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(box.attached, ['sshbox-abc']);
    expect(await _savedTmux(), ['sshbox-abc']);
    await tester.pump(const Duration(seconds: 10));
  });

  // This machine's own shells are saved nowhere, and are not missing.
  testWidgets('Duplicate session on a local shell opens another, and says '
      'nothing of a host no longer saved', (tester) async {
    SharedPreferences.setMockInitialValues(_killedLive(tabs: []));
    _quietPlatform(tester);
    _plainLocalShells();
    final box = _Box();
    await _start(tester, over: box);

    await tester.tap(find.text('Local shell'));
    await _settle(tester);
    await tester.longPress(_onStrip(find.text('Local shell')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate session'));
    await _settle(tester);

    expect(find.text('That host is no longer saved'), findsNothing);
    expect(_onStrip(find.text('Local shell')), findsNWidgets(2));
    expect(box.connected, ['local', 'local']);
    await tester.pump(const Duration(seconds: 10));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a link to a WSL shell opens one, and Duplicate session on it '
      'another in the same distro, saying nothing of a host no longer '
      'saved', (tester) async {
    SharedPreferences.setMockInitialValues(_killedLive(tabs: []));
    _quietPlatform(tester, launchedBy: 'sshbox://host/wsl:Ubuntu');
    _plainLocalShells();
    final box = _Box();
    await _start(tester, over: box);
    expect(_onStrip(find.text('Ubuntu')), findsOneWidget);

    await tester.longPress(_onStrip(find.text('Ubuntu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate session'));
    await _settle(tester);

    expect(find.text('That host is no longer saved'), findsNothing);
    expect(_onStrip(find.text('Ubuntu')), findsNWidgets(2));
    expect(box.connected, ['wsl:Ubuntu', 'wsl:Ubuntu']);
    await tester.pump(const Duration(seconds: 10));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a notification for a host deleted since says so, rather than '
      'opening nothing without a word', (tester) async {
    _quietPlatform(tester, launchedBy: 'sshbox://host/deleted');
    await _start(tester);
    expect(find.text('That host is no longer saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
