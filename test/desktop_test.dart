import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/magic_key.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// A shell that is up the moment it is asked for, and carries nothing else:
/// no files, no commands, no forwards — which is exactly what the local
/// transport offers.
class _Shell implements SessionTransport, TerminalSession {
  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  Future<void> dispose() async {}

  /// send, resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// Opens everything, and remembers what it was handed.
class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

Future<LiveSession> _connected(WidgetTester tester) async {
  final session = LiveSession(
    host: const HostProfile(
      id: 'host-1',
      label: 'box',
      host: '10.0.2.2',
      username: 'me',
    ),
    transport: (_, _) => _Shell(),
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: TerminalPage(
        session: session,
        secrets: _NoSecrets(),
        onOpenFile: (_, {line}) {},
        onOpenWeb: (_) {},
        onOpenChat: () {},
        onOpenGit: () {},
        onSaveFileRoot: (_) async {},
      ),
    ),
  );
  await session.connect(secrets: _NoSecrets());
  await tester.pump();
  return session;
}

Future<void> _pumpHome(
  WidgetTester tester, {
  Future<void> Function()? onOpenLocal,
  List<HostProfile> hosts = const [],
  SessionManager? sessions,
}) async {
  SharedPreferences.setMockInitialValues({});
  final secrets = InMemorySecretStore();
  final repository = HostRepository(secrets);
  for (final host in hosts) {
    await repository.upsert(host);
  }
  await tester.pumpWidget(
    MaterialApp(
      home: HostsPage(
        repository: repository,
        secrets: secrets,
        sessions: sessions ?? SessionManager(),
        onOpenHost: (_) async {},
        onOpenLocal: onOpenLocal,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the keys a desktop does not need', () {
    testWidgets('go, key bar and magic key both', (tester) async {
      await _connected(tester);

      expect(find.byType(TerminalKeyBar), findsNothing);
      expect(find.byType(MagicKey), findsNothing);
    }, variant: _desktop);

    testWidgets('stay on a phone, which has no keyboard of its own', (
      tester,
    ) async {
      await _connected(tester);

      expect(find.byType(TerminalKeyBar), findsOneWidget);
      expect(find.byType(MagicKey), findsOneWidget);
    }, variant: _phone);
  });

  group('a link on a desktop', () {
    testWidgets('goes to the machine\'s own browser, never to a web tab', (
      tester,
    ) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      await openUrl(
        context,
        Uri.parse('https://example.com/x'),
        inTab: inTab.add,
      );

      expect(inTab, isEmpty);
      expect(launcher.opened, ['https://example.com/x']);
    }, variant: _desktop);

    testWidgets('opens in a tab beside its shell on a phone', (tester) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      await openUrl(
        context,
        Uri.parse('https://example.com/x'),
        inTab: inTab.add,
      );

      expect(inTab, [Uri.parse('https://example.com/x')]);
      expect(launcher.opened, isEmpty);
    }, variant: _phone);
  });

  group('the local shell on Home', () {
    testWidgets('has a card of its own, and a tap opens one', (tester) async {
      var opened = 0;
      await _pumpHome(tester, onOpenLocal: () async => opened++);

      expect(find.text('Local shell'), findsOneWidget);
      // No hosts saved yet, and the empty state would have stood in front of
      // it.
      expect(find.text('A shell on this machine'), findsOneWidget);

      await tester.tap(find.text('Local shell'));
      await tester.pump();
      expect(opened, 1);
    }, variant: _desktop);

    testWidgets('counts the shells already open on this machine', (
      tester,
    ) async {
      final sessions = SessionManager();
      final secrets = InMemorySecretStore();
      for (var i = 0; i < 2; i++) {
        await sessions
            .open(localHost(), transport: (_, _) => _Shell())
            .connect(secrets: secrets);
      }

      await _pumpHome(tester, onOpenLocal: () async {}, sessions: sessions);

      expect(find.text('2 open'), findsOneWidget);
    }, variant: _desktop);

    testWidgets('is not drawn on a phone, which has no shell to open', (
      tester,
    ) async {
      await _pumpHome(
        tester,
        onOpenLocal: () async {},
        hosts: const [
          HostProfile(id: 'a', label: 'box', host: '10.0.0.1', username: 'me'),
        ],
      );

      expect(find.text('Local shell'), findsNothing);
      expect(find.text('box'), findsOneWidget);
    }, variant: _phone);
  });

  test('the local host is this machine, saved nowhere', () {
    final host = localHost();

    expect(host.id, localHostId);
    expect(host.host, 'localhost');
    // Nothing to authenticate to, so it keeps the default rather than
    // claiming a method that would send a credential.
    expect(host.authMethod, SshAuthMethod.password);
  });
}
