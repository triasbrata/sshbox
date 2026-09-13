import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/models/os_info.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/known_hosts_page.dart';
import 'package:sshbox/src/ui/os_icon.dart';

/// A shell that is up the moment it is asked for.
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
  }) async => this;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  Future<void> dispose() async {}

  /// send, resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  // A phone in portrait, and a tablet.
  for (final (width, columns) in [(400.0, 1), (1200.0, 3)]) {
    testWidgets('$columns host card(s) to a row at $width dp, all as tall', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final repository = HostRepository(secrets);
      // Connected: it has said what it runs, and has two shells up.
      const connected = HostProfile(
        id: 'a',
        label: 'a',
        host: '10.0.0.1',
        username: 'me',
        os: OsInfo(
          id: 'ubuntu',
          prettyName: 'Ubuntu 22.04.5 LTS',
          arch: 'x86_64',
        ),
      );
      await repository.upsert(connected);
      // A short version.
      await repository.upsert(
        const HostProfile(
          id: 'b',
          label: 'b',
          host: '10.0.0.2',
          username: 'me',
          os: OsInfo(
            id: 'alpine',
            prettyName: 'Alpine Linux v3.20',
            kernel: 'Linux',
            arch: 'aarch64',
          ),
        ),
      );
      // Never connected.
      await repository.upsert(
        const HostProfile(
          id: 'c',
          label: 'c',
          host: '10.0.0.3',
          username: 'me',
        ),
      );
      // Far too long for any card, and a long version: they have to
      // ellipsize, not overflow. On a tablet it is alone in the second row.
      await repository.upsert(
        HostProfile(
          id: 'd',
          label: 'a very long host name ' * 4,
          host: 'build-${'x' * 80}.example.com',
          username: 'deploy',
          port: 2222,
          os: const OsInfo(
            id: 'fedora',
            prettyName: 'Fedora Linux 40 (Workstation Edition)',
            kernel: 'Linux',
            arch: 'x86_64',
          ),
        ),
      );

      final sessions = SessionManager();
      for (var i = 0; i < 2; i++) {
        await sessions
            .open(connected, transport: (_, _) => _Shell())
            .connect(secrets: secrets);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: HostsPage(
            repository: repository,
            secrets: secrets,
            sessions: sessions,
            onOpenHost: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cards = find.byType(Card);
      expect(cards, findsNWidgets(4));
      final corners = [
        for (var i = 0; i < 4; i++) tester.getTopLeft(cards.at(i)),
      ];
      expect(corners.map((c) => c.dx).toSet(), hasLength(columns));
      expect(corners.map((c) => c.dy).toSet(), hasLength((4 / columns).ceil()));
      // Off the screen's edge.
      expect(corners.first.dx, greaterThan(0));
      // Whatever a host has said, and however long its version, its card
      // is as tall as the others, in its own row and the next...
      expect({
        for (var i = 0; i < 4; i++) tester.getSize(cards.at(i)).height,
      }, hasLength(1));
      // ...with its badge as far down it: the version under the badge takes
      // one line, long, short, or blank before the first connect.
      expect({
        for (var i = 0; i < 4; i++)
          tester
                  .getTopLeft(
                    find.descendant(
                      of: cards.at(i),
                      matching: find.byType(OsBadge),
                    ),
                  )
                  .dy -
              tester.getTopLeft(cards.at(i)).dy,
      }, hasLength(1));
      expect({
        for (final version in [
          '22.04.5 LTS',
          '3.20',
          '40 (Workstation Edition)',
        ])
          tester.getSize(find.text(version)).height,
      }, hasLength(1));

      // The version is under its badge, centred on it, without the OS's
      // name: the badge already shows it.
      final badge = tester.getRect(
        find.descendant(
          of: find.widgetWithText(Card, '22.04.5 LTS'),
          matching: find.byType(OsBadge),
        ),
      );
      final version = tester.getRect(find.text('22.04.5 LTS'));
      expect(version.top, greaterThanOrEqualTo(badge.bottom));
      expect(
        version.center.dx,
        moreOrLessEquals(badge.center.dx, epsilon: 0.5),
      );
      for (final name in ['Ubuntu', 'Alpine', 'Fedora', 'Linux']) {
        expect(find.textContaining(name), findsNothing);
      }

      // The arch is saved, but on no card.
      for (final arch in ['x86_64', 'aarch64', '·']) {
        expect(find.textContaining(arch), findsNothing);
      }
      expect(find.text('2 active sessions'), findsOneWidget);
      expect(find.text('OS not detected yet'), findsNothing);
      // The user and the OS are on the card once each, not again in an
      // `ssh, me, ubuntu` line.
      expect(find.textContaining('ssh,'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Known hosts opens from Home', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          repository: HostRepository(secrets),
          secrets: secrets,
          sessions: SessionManager(),
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Known hosts'));
    await tester.pumpAndSettle();
    expect(find.byType(KnownHostsPage), findsOneWidget);
    expect(find.text('Nothing trusted yet'), findsOneWidget);
  });

  testWidgets('the push token is copied in Settings, no longer on Home', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final copied = <Object?>[];
    final platform = tester.binding.defaultBinaryMessenger;
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(call.arguments);
      return null;
    });
    addTearDown(
      () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final secrets = InMemorySecretStore();
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          repository: HostRepository(secrets),
          secrets: secrets,
          sessions: SessionManager(pushToken: () => 'device-token'),
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.key_outlined), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final copy = find.text('Copy notification token');
    // Settings' own list, not its preview terminal's.
    await tester.scrollUntilVisible(
      copy,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(copy);
    // A frame for the toast's overlay, one to start its slide, and the slide.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(copied, [
      {'text': 'device-token'},
    ]);
    expect(find.text('FCM token copied'), findsOneWidget);
    // The toast's countdown run out, rather than left running past the test.
    await tester.pumpAndSettle();
  });
}
