import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/known_hosts_page.dart';

void main() {
  final store = KnownHostStore();
  final repository = HostRepository(InMemorySecretStore());

  /// Pinned straight into storage rather than through `trust`: the store's
  /// writes chain on one static future, and a chain begun in one test's
  /// fake-async zone never runs again in the next test.
  void pin(Map<String, String> known) => SharedPreferences.setMockInitialValues(
    {'sshbox.knownhosts.v1': jsonEncode(known)},
  );

  setUp(() => pin({}));

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: KnownHostsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows each key with the saved hosts that use it', (
    tester,
  ) async {
    pin({'box:22': 'SHA256:box', 'fe80::1:2222': 'SHA256:v6'});
    await repository.upsert(
      const HostProfile(
        id: 'a',
        label: 'Build box',
        host: 'box',
        username: 'me',
      ),
    );
    await repository.upsert(
      const HostProfile(id: 'b', label: '', host: 'box', username: 'root'),
    );
    // Another port is another key.
    await repository.upsert(
      const HostProfile(
        id: 'c',
        label: 'Other',
        host: 'box',
        port: 2200,
        username: 'me',
      ),
    );
    await open(tester);

    expect(find.text('box'), findsOneWidget);
    expect(find.text('Build box, root@box'), findsOneWidget);
    expect(find.text('SHA256:box'), findsOneWidget);
    expect(find.textContaining('Other'), findsNothing);
    // Bracketed, or the port would read as part of the address.
    expect(find.text('[fe80::1]:2222'), findsOneWidget);
    expect(find.text('SHA256:v6'), findsOneWidget);
  });

  testWidgets('Forget asks first: Cancel keeps the key, Forget drops it', (
    tester,
  ) async {
    pin({'box:22': 'SHA256:box', 'fe80::1:2222': 'SHA256:v6'});
    await open(tester);

    Future<void> forget(String address, String answer) async {
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, address),
          matching: find.byTooltip('Forget'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Forget this key?'), findsOneWidget);
      expect(
        find.text(
          'The next connection to $address asks you to trust it again.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(answer),
        ),
      );
      await tester.pumpAndSettle();
    }

    await forget('[fe80::1]:2222', 'Cancel');
    expect(find.text('[fe80::1]:2222'), findsOneWidget);
    expect(await store.pinnedKey('fe80::1', 2222), 'SHA256:v6');

    await forget('[fe80::1]:2222', 'Forget');
    expect(find.text('[fe80::1]:2222'), findsNothing);
    expect(await store.pinnedKey('fe80::1', 2222), isNull);
    // The other key stays.
    expect(find.text('box'), findsOneWidget);
    expect(await store.pinnedKey('box', 22), 'SHA256:box');
  });

  testWidgets('says so when nothing is trusted yet', (tester) async {
    await open(tester);
    expect(find.text('Nothing trusted yet'), findsOneWidget);
    expect(
      find.text('A key is added when you trust it while connecting.'),
      findsOneWidget,
    );
  });
}
