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
}
