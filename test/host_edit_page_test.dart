import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/host_edit_page.dart';

void main() {
  testWidgets('picks a saved host to jump through, and saves it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    final repository = HostRepository(secrets);
    const box = HostProfile(
      id: 'box',
      label: 'box',
      host: '10.0.0.5',
      username: 'me',
      jumpHostId: 'deleted-since',
    );
    await repository.upsert(
      const HostProfile(
        id: 'gw',
        label: 'office gw',
        host: 'gw.example',
        username: 'me',
      ),
    );
    await repository.upsert(box);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<HostProfile>(
                builder: (_) => HostEditPage(
                  repository: repository,
                  secrets: secrets,
                  existing: box,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A jump host deleted since is no jump host, and the host itself is not
    // offered.
    await tester.tap(find.text('None, connect directly'));
    await tester.pumpAndSettle();
    expect(find.text('box'), findsOneWidget);
    await tester.tap(find.text('office gw').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = (await repository.load()).firstWhere((h) => h.id == 'box');
    expect(saved.jumpHostId, 'gw');
  });

  testWidgets('adds a port forward, refusing a port Android keeps from apps', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    final repository = HostRepository(secrets);
    const db = HostProfile(
      id: 'db',
      label: 'db',
      host: 'db.example',
      username: 'me',
    );
    await repository.upsert(db);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<HostProfile>(
                builder: (_) => HostEditPage(
                  repository: repository,
                  secrets: secrets,
                  existing: db,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add port forward'));
    await tester.tap(find.text('Add port forward'));
    await tester.pumpAndSettle();
    final local = find.widgetWithText(TextFormField, 'Port on this tablet');
    await tester.enterText(local, '80');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.textContaining('below 1024'), findsOneWidget);

    await tester.enterText(local, '5432');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('127.0.0.1:5432 → localhost:5432'), findsOneWidget);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = (await repository.load()).single;
    expect(saved.localForwards, [
      const LocalForward(localPort: 5432, destPort: 5432),
    ]);
  });
}
