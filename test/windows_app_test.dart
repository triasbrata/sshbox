import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/web_page.dart';
import 'package:sshbox/src/windows/windows.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

const _host = HostProfile(
  id: 'h1',
  label: 'box via tailnet',
  host: '127.0.0.1',
  port: 1,
  username: 'me',
);

const _signInUrl = 'https://login.tailscale.com/a/1a2b3c';

/// A runner that opens windows, numbering them from 1, and keeps what it was
/// asked.
class _Runner implements WindowBackend {
  final opened = <WindowFrame?>[];
  final closed = <int>[];
  final say = StreamController<WindowEvent>.broadcast();
  int _next = 1;

  @override
  Future<bool> get supported async => true;

  @override
  Stream<WindowEvent> get events => say.stream;

  @override
  Future<int?> open({WindowFrame? frame}) async {
    opened.add(frame);
    return _next++;
  }

  @override
  Future<void> close(int id) async => closed.add(id);

  @override
  Future<void> activate(int id) async {}

  @override
  Future<void> place(int id, WindowFrame frame) async {}
}

/// A host that is up the moment it is asked for, or, with [signIn], held at a
/// sign-in that wants the user's link first.
class _Shell implements SessionTransport, TerminalSession {
  _Shell({this.signIn});

  Completer<void>? signIn;
  void Function(String banner) banner = (_) {};

  /// The hosts connected to, by id, in the order asked.
  final connected = <String>[];

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
    if (signIn case final signIn?) {
      banner('To authenticate, visit: $_signInUrl');
      await signIn.future;
    }
    status.value = SessionStatus.connected;
    return this;
  }

  @override
  final ValueNotifier<SessionStatus> status = ValueNotifier(
    SessionStatus.connecting,
  );

  @override
  Stream<String> get output =>
      StreamController<String>(onCancel: () async {}).stream;

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}
}

class _BareNotifications extends FlutterLocalNotificationsPlatform {}

Map<String, Object> _saved({bool restored = false}) => {
  'sshbox.hosts.v1': jsonEncode([_host.toJson()]),
  // Past the first run's word about telemetry, which would lie over Home.
  'sshbox.telemetry.notice': true,
  if (restored)
    'sshbox.tabs.v1': jsonEncode({
      'sessions': [
        {'hostId': _host.id, 'tmux': null, 'files': [], 'web': []},
      ],
      'databases': [],
    }),
};

/// The platform's half of what the app asks as it starts, answered as a
/// machine with nothing to say; [initialLink] is the link that started it.
void _quiet(WidgetTester tester, {String? initialLink}) {
  FlutterLocalNotificationsPlatform.instance = _BareNotifications();
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (call) async => call.method == 'getInitialLink' ? initialLink : null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Runner> _start(
  WidgetTester tester,
  _Shell shell, {
  String? initialLink,
}) async {
  _quiet(tester, initialLink: initialLink);
  final runner = _Runner();
  // The root is the views, as `runWidget` makes it, where the runner opens
  // windows.
  await tester.pumpWidget(
    SshboxApp(
      windows: runner,
      multiWindow: true,
      transport: (_, banner) => shell..banner = banner,
    ),
    wrapWithView: false,
  );
  await _settle(tester);
  return runner;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(_saved());
    // What a sign-in's web tab is drawn by.
    WebViewPlatform.instance = FakeWebViewPlatform();
  });

  testWidgets(
    'the app coming back resyncs the tmux of every window, and a view that '
    'comes up rebuilds the windows',
    (tester) async {
      await _start(tester, _Shell());
      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      binding.handleMetricsChanged();
      await _settle(tester);
      expect(find.byType(MaterialApp), findsOneWidget);
    },
  );

  testWidgets('a link to a host opens it in the window the user is in', (
    tester,
  ) async {
    final shell = _Shell();
    await _start(tester, shell, initialLink: 'sshbox://host/h1');
    expect(shell.connected, ['h1']);
  });

  testWidgets(
    'a window with a live session asks before it closes, and a no keeps it',
    (tester) async {
      final shell = _Shell();
      final runner = await _start(tester, shell);

      // A live shell in the first window: the Local card's.
      await tester.tap(
        find.descendant(
          of: find.byType(HostsPage),
          matching: find.text('Local shell'),
        ),
      );
      await _settle(tester);

      // A second window, so the first is not the last.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(runner.opened, hasLength(1));

      runner.say.add(const WindowCloseRequested(0));
      await _settle(tester);
      expect(find.text('Close this window?'), findsOneWidget);
      expect(find.text('1 live session in it will end.'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Keep it'));
      await _settle(tester);
      expect(runner.closed, isEmpty);

      runner.say.add(const WindowCloseRequested(0));
      await _settle(tester);
      await tester.tap(find.bySemanticsLabel('Close window'));
      await _settle(tester);
      expect(runner.closed, [1]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('a window with nothing live closes with no question', (
    tester,
  ) async {
    final runner = await _start(tester, _Shell());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);

    runner.say.add(const WindowCloseRequested(0));
    await _settle(tester);
    expect(find.text('Close this window?'), findsNothing);
    expect(runner.closed, [1]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    "a restored tab's sign-in, opened from its sheet, goes to a web tab",
    (tester) async {
      SharedPreferences.setMockInitialValues(_saved(restored: true));
      final shell = _Shell(signIn: Completer());
      await _start(tester, shell);

      await tester.tap(find.byTooltip('Home'));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(HostsPage),
          matching: find.text('box via tailnet'),
        ),
      );
      await _settle(tester);
      expect(find.text(_signInUrl), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Open link'));
      await _settle(tester);
      // The link is a tab of the same host's, beside its shell.
      expect(find.byType(WebPage), findsOneWidget);
    },
  );
}
