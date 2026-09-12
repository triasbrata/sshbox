import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/hosts_page.dart';

void main() {
  // A phone in portrait, and a tablet.
  for (final (width, columns) in [(400.0, 1), (1200.0, 3)]) {
    testWidgets('$columns host card(s) to a row at $width dp', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final repository = HostRepository(secrets);
      for (final id in ['a', 'b', 'c']) {
        await repository.upsert(
          HostProfile(id: id, label: id, host: '10.0.0.1', username: 'me'),
        );
      }
      // Far too long for any card: it has to ellipsize, not overflow.
      await repository.upsert(
        HostProfile(
          id: 'd',
          label: 'a very long host name ' * 4,
          host: 'build-${'x' * 80}.example.com',
          username: 'deploy',
          port: 2222,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HostsPage(
            repository: repository,
            secrets: secrets,
            sessions: SessionManager(),
            onOpenHost: (_) async {},
            pushToken: () => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final corners = [
        for (var i = 0; i < 4; i++) tester.getTopLeft(find.byType(Card).at(i)),
      ];
      expect(corners.map((c) => c.dx).toSet(), hasLength(columns));
      expect(corners.map((c) => c.dy).toSet(), hasLength((4 / columns).ceil()));
      // Off the screen's edge.
      expect(corners.first.dx, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }
}
