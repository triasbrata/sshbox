import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/connect_sheet.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// Opens every link it is asked to, and keeps them.
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

/// A host as SSH meets it, a step at a time: its key goes through the
/// pinning every connect does, then it may hold the connection at a
/// Tailscale sign-in until [signIn] completes, and it refuses while
/// [refuse] says so. Each connect hands back this one shell.
class _Host implements SessionTransport, TerminalSession {
  _Host({this.fingerprint, this.signIn, this.refuse = false});

  /// The key it shows. Null for a host whose key is not asked about.
  String? fingerprint;
  final Completer<void>? signIn;
  bool refuse;

  /// This attempt's, as the session hands them to SSH.
  Future<bool> Function(HostKeyCheck check)? confirm;
  void Function(String banner) banner = (_) {};

  int attempts = 0;
  bool disposed = false;

  /// Every size the shell was opened at, or told since.
  final sizes = <(int, int)>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
  }) async {
    attempts++;
    final key = fingerprint;
    if (key != null && !await KnownHostStore().trust(host, key, confirm)) {
      throw const SshSessionException('The host key was not trusted.');
    }
    if (signIn case final signIn?) {
      banner('To authenticate, visit: $_signInUrl');
      await signIn.future;
    }
    if (refuse) throw const SshSessionException('Connection refused.');
    sizes.add((columns, rows));
    disposed = false;
    status.value = SessionStatus.connected;
    return this;
  }

  @override
  final ValueNotifier<SessionStatus> status = ValueNotifier(
    SessionStatus.connecting,
  );

  /// Let go of on a reconnect, and its cancel answers in the test's own zone:
  /// `Stream.empty()`'s answers in the root zone, which a widget test's
  /// clock never runs, so the reconnect would wait on it for good.
  @override
  Stream<String> get output =>
      StreamController<String>(onCancel: () async {}).stream;

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) =>
      sizes.add((columns, rows));

  @override
  Future<void> dispose() async => disposed = true;
}

const _box = HostProfile(
  id: 'host-1',
  label: 'box',
  host: '10.0.2.2',
  username: 'me',
);
const _key = 'SHA256:q1w2e3r4t5y6u7i8o9p0';
const _signInUrl = 'https://login.tailscale.com/a/1a2b3c';

void main() {
  late SessionManager manager;
  late Future<LiveSession?> opening;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = SessionManager();
  });

  tearDown(() => manager.closeAll());

  /// The app's one screen over [manager], and a tap on the box's card:
  /// another shell on [host], connecting in its sheet. [opening] is the
  /// session once it has its tab, or null.
  Future<void> openBox(WidgetTester tester, _Host host) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: manager,
          onOpenHost: (_) async {},
          pushToken: () => null,
        ),
      ),
    );
    opening = openInSheet(
      tester.element(find.byType(TabsShell)),
      manager,
      _box,
      secrets: _NoSecrets(),
      transport: (confirm, banner) => host
        ..confirm = confirm
        ..banner = banner,
    );
    await tester.pumpAndSettle();
  }

  Future<String?> pinned() => KnownHostStore().pinnedKey('10.0.2.2', 22);

  // A new key and a changed one in one test, because only one widget test
  // here can pin a key: KnownHostStore chains its writes on a static future,
  // bound to the zone of the test that wrote first, and a later test's write
  // would wait on that zone for good.
  testWidgets("a new host's key is asked about in the sheet; Trust opens its "
      'tab at the size it is shown at, and a changed key on Reconnect is '
      'asked about the same way', (tester) async {
    final host = _Host(fingerprint: _key);
    await openBox(tester, host);

    // Named, with the key to check against the server's own, and no tab
    // while it waits.
    expect(find.text('me@10.0.2.2:22'), findsOneWidget);
    expect(find.text('Trust 10.0.2.2?'), findsOneWidget);
    expect(find.text(_key), findsOneWidget);
    expect(manager.sessions, isEmpty);

    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();

    final session = (await opening)!;
    expect(manager.sessions, [session]);
    expect(manager.activeId, session.id);
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.text(_key), findsNothing);
    expect(await pinned(), _key);
    // Opened before its page was laid out, then told what that came to.
    final terminal = session.terminal;
    expect(host.sizes.first, (80, 24));
    expect(host.sizes.last, (terminal.viewWidth, terminal.viewHeight));
    expect(host.sizes.last, isNot((80, 24)));

    // The server is rebuilt, and the shell drops.
    host
      ..fingerprint = 'SHA256:rebuilt'
      ..status.value = SessionStatus.closed;
    await tester.pump();
    await tester.tap(find.byTooltip('Reconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Host key of 10.0.2.2 changed'), findsOneWidget);
    expect(find.text(_key), findsOneWidget);
    expect(find.text('SHA256:rebuilt'), findsOneWidget);
    await tester.tap(find.text('Replace key'));
    await tester.pumpAndSettle();

    expect(session.isConnected, isTrue);
    expect(find.text('Replace key'), findsNothing);
    expect(await pinned(), 'SHA256:rebuilt');
  });

  testWidgets('Cancel on the key: no tab, and nothing pinned', (tester) async {
    await openBox(tester, _Host(fingerprint: _key));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await opening, isNull);
    expect(manager.sessions, isEmpty);
    expect(find.byType(TerminalPage), findsNothing);
    expect(await pinned(), isNull);
  });

  testWidgets('a sign-in shows its link in the sheet, opens it in the '
      'browser over the app, and carries on once done', (tester) async {
    final launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    final signIn = Completer<void>();
    await openBox(tester, _Host(signIn: signIn));

    expect(find.text('This host wants you to sign in'), findsOneWidget);
    expect(find.text(_signInUrl), findsOneWidget);
    expect(manager.sessions, isEmpty);

    await tester.tap(find.text('Open link'));
    await tester.pump();
    // There is no tab yet to put a web tab beside.
    expect(launcher.tried, [
      (_signInUrl, PreferredLaunchMode.inAppBrowserView),
    ]);

    signIn.complete();
    await tester.pumpAndSettle();
    expect(manager.sessions, [await opening]);
    expect(find.text('This host wants you to sign in'), findsNothing);
  });

  testWidgets('closed while it waits on a sign-in, it gets no tab, and the '
      'connection that comes through after is let go', (tester) async {
    final signIn = Completer<void>();
    final host = _Host(signIn: signIn);
    await openBox(tester, host);

    // The scrim above the sheet, as a swipe down would.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(await opening, isNull);
    expect(manager.sessions, isEmpty);

    signIn.complete();
    await tester.pump();
    expect(host.attempts, 1);
    expect(host.disposed, isTrue);
  });

  testWidgets('a failure says why in the sheet, with Try again and Close; '
      'Close leaves no tab', (tester) async {
    final host = _Host(refuse: true);
    await openBox(tester, host);

    expect(find.text('Connection refused.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(host.attempts, 2);
    expect(find.text('Connection refused.'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await opening, isNull);
    expect(manager.sessions, isEmpty);
    expect(find.byType(TerminalPage), findsNothing);
  });

  testWidgets("a port forward's key is asked about in a sheet of its own, "
      'and closing it is a no', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final context = tester.element(find.byType(Scaffold));
    const HostKeyCheck check = (host: _box, fingerprint: _key, pinned: null);

    var trusted = confirmHostKey(context, check);
    await tester.pumpAndSettle();
    expect(find.text(_key), findsOneWidget);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();
    expect(await trusted, isTrue);

    trusted = confirmHostKey(context, check);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(await trusted, isFalse);
  });
}
