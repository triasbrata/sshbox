import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/models/os_info.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
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
      // Connected: it has said what it runs, a name that takes both of the
      // label's lines, and has two shells up.
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
      // Only its kernel: a name that fits on one line.
      await repository.upsert(
        const HostProfile(
          id: 'b',
          label: 'b',
          host: '10.0.0.2',
          username: 'me',
          os: OsInfo(kernel: 'Linux', arch: 'aarch64'),
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
      // Far too long for any card: it has to ellipsize, not overflow. On a
      // tablet it is alone in the second row, with no OS either.
      await repository.upsert(
        HostProfile(
          id: 'd',
          label: 'a very long host name ' * 4,
          host: 'build-${'x' * 80}.example.com',
          username: 'deploy',
          port: 2222,
        ),
      );

      final sessions = SessionManager();
      for (var i = 0; i < 2; i++) {
        await sessions
            .open(connected, transport: _Shell())
            .connect(secrets: secrets);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: HostsPage(
            repository: repository,
            secrets: secrets,
            sessions: sessions,
            onOpenHost: (_) async {},
            pushToken: () => null,
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
      // Whatever a host has said, and however long its OS's name, its card
      // is as tall as the others, in its own row and the next...
      expect(
        {for (var i = 0; i < 4; i++) tester.getSize(cards.at(i)).height},
        hasLength(1),
      );
      // ...though the names take different room under their badges.
      expect(
        tester.getSize(find.text('Ubuntu 22.04.5 LTS')).height,
        greaterThan(tester.getSize(find.text('Linux')).height),
      );

      // The OS's name is under its badge, centred on it.
      final badge = tester.getRect(
        find.descendant(
          of: find.widgetWithText(Card, 'Ubuntu 22.04.5 LTS'),
          matching: find.byType(OsBadge),
        ),
      );
      final name = tester.getRect(find.text('Ubuntu 22.04.5 LTS'));
      expect(name.top, greaterThanOrEqualTo(badge.bottom));
      expect(name.center.dx, moreOrLessEquals(badge.center.dx, epsilon: 0.5));

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
}
