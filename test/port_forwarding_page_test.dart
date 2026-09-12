import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/forward_setting.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/port_forwards.dart';
import 'package:sshbox/src/ui/port_forwarding_page.dart';

void main() {
  late HostRepository repository;
  late PortForwards forwards;

  /// The page at [width] dp, with one saved host and no settings.
  Future<void> open(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    repository = HostRepository(secrets);
    await repository.upsert(
      const HostProfile(
        id: 'db',
        label: 'db box',
        host: 'db.example',
        username: 'me',
      ),
    );
    forwards = PortForwards(secrets: secrets);
    await forwards.load();
    await tester.pumpWidget(
      MaterialApp(
        home: PortForwardingPage(
          forwards: forwards,
          repository: repository,
          secrets: secrets,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A new setting's editor, with the saved host picked.
  Future<void> addOne(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add port forward'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('db box').last);
    await tester.pumpAndSettle();
  }

  final tabletPort = find.widgetWithText(TextFormField, 'Tablet port');
  final remotePort = find.widgetWithText(TextFormField, 'Remote port');

  // A phone in portrait, and a tablet.
  for (final width in [400.0, 1200.0]) {
    testWidgets('adds a setting with two ports at $width dp, refusing a port '
        'Android keeps from apps and a port used twice, and deletes it', (
      tester,
    ) async {
      await open(tester, width);
      expect(find.text('No port forwards yet'), findsOneWidget);

      await tester.tap(find.byTooltip('Add port forward'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(find.text('Pick a host'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('db box').last);
      await tester.pumpAndSettle();

      await tester.enterText(tabletPort, '80');
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(find.textContaining('Use 1024 or above'), findsOneWidget);

      await tester.enterText(tabletPort, '5432');
      await tester.tap(find.text('Add port'));
      await tester.pumpAndSettle();
      await tester.enterText(tabletPort.last, '5432');
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(find.text('Used twice'), findsNWidgets(2));

      await tester.enterText(tabletPort.last, '6379');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(find.text('db box'), findsOneWidget);
      expect(
        find.text(
          'PostgreSQL · Tablet 5432 → Remote 5432\n'
          'Redis · Tablet 6379 → Remote 6379',
        ),
        findsOneWidget,
      );
      expect(find.text('Stopped'), findsOneWidget);
      expect(forwards.runs.single.setting.mappings, const [
        LocalForward(localPort: 5432, destPort: 5432),
        LocalForward(localPort: 6379, destPort: 6379),
      ]);
      expect(tester.takeException(), isNull);

      // Tapped, it opens to edit, and can be deleted from there.
      await tester.tap(find.text('db box'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('No port forwards yet'), findsOneWidget);
      expect(forwards.runs, isEmpty);
    });

    testWidgets('a Remote → Tablet port at $width dp says what it does as it '
        'is typed, warns of what the host may refuse or expose, and saves', (
      tester,
    ) async {
      await open(tester, width);
      await addOne(tester);
      await tester.tap(find.text('Remote → Tablet'));
      await tester.pumpAndSettle();

      await tester.enterText(remotePort, '80');
      await tester.pump();
      expect(find.textContaining('unless you sign in as root'), findsOneWidget);

      await tester.enterText(remotePort, '8000');
      await tester.pump();
      expect(find.textContaining('unless you sign in as root'), findsNothing);
      expect(
        find.text(
          'Programs on db box open localhost:8000 to reach port 8000 on this '
          'tablet.',
        ),
        findsOneWidget,
      );

      final listenOn = find.widgetWithText(TextFormField, 'Remote listens on');
      expect(listenOn, findsNothing);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.enterText(listenOn, '0.0.0.0');
      await tester.enterText(tabletPort, '9000');
      await tester.pump();
      expect(find.textContaining('GatewayPorts'), findsOneWidget);
      expect(
        find.text(
          'Programs on db box, and machines that reach it, open port 8000 on '
          'it to reach port 9000 on this tablet.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(forwards.runs.single.setting.mappings, const [
        RemoteForward(remoteHost: '0.0.0.0', remotePort: 8000, tabletPort: 9000),
      ]);
      expect(find.text('Remote 0.0.0.0:8000 → Tablet 9000'), findsOneWidget);
    });
  }

  testWidgets('a service chip fills the port, names the service, and names '
      'the setting after it', (tester) async {
    await open(tester, 400);
    await addOne(tester);
    await tester.tap(find.text('PostgreSQL 5432'));
    await tester.pump();

    expect(tester.widget<TextFormField>(tabletPort).controller!.text, '5432');
    expect(
      find.text(
        'Apps on this tablet open 127.0.0.1:5432 (PostgreSQL) to reach port '
        '5432 on db box.',
      ),
      findsOneWidget,
    );
    expect(find.text('Optional. Defaults to PostgreSQL on db box.'), findsOne);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('PostgreSQL on db box'), findsOneWidget);
    expect(find.text('PostgreSQL · Tablet 5432 → Remote 5432'), findsOneWidget);
  });

  testWidgets('New host… makes one in the host editor and comes back with it '
      'picked', (tester) async {
    await open(tester, 400);
    await tester.tap(find.byTooltip('Add port forward'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New host…').last);
    await tester.pumpAndSettle();

    expect(find.text('New host'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'pg.example',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'me');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(find.text('me@pg.example'), findsOneWidget);
    await tester.enterText(tabletPort, '15432');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final created = (await repository.load()).last;
    expect(created.host, 'pg.example');
    expect(forwards.runs.single.setting.hostId, created.id);
    expect(find.text('me@pg.example'), findsOneWidget);
    expect(find.text('Tablet 15432 → Remote 15432'), findsOneWidget);
  });
}
