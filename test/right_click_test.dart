import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/right_click.dart';

void main() {
  group('a Ctrl+click', () {
    var menus = 0;
    var taps = 0;

    Future<void> pumpTarget(WidgetTester tester) async {
      menus = 0;
      taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            onSecondaryTapUp: rightClick((_) => menus++),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    /// A mouse click with Ctrl held, through [click] as the app's binding
    /// passes every pointer event.
    Future<void> ctrlClick(WidgetTester tester, ControlClick click) async {
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      for (final event in [
        mouse.addPointer(location: const Offset(100, 100)),
        mouse.down(const Offset(100, 100)),
        mouse.up(),
      ]) {
        await tester.sendEventToBinding(click.convert(event));
      }
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('is a right-click on a Mac, as AppKit\'s own menus take it', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => false));
      expect(menus, 1);
      expect(taps, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('stays a click on a Mac while Ctrl is the link key', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => true));
      expect(menus, 0);
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('stays a click on Linux, where a Ctrl+click is a click', (
      tester,
    ) async {
      await pumpTarget(tester);
      await ctrlClick(tester, ControlClick(ctrlOpensLinks: () => false));
      expect(menus, 0);
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('a right-click on a Home card', () {
    Future<HostRepository> pumpHome(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final repository = HostRepository(secrets);
      await repository.upsert(
        const HostProfile(
          id: 'box',
          label: 'box',
          host: '10.0.0.1',
          username: 'me',
        ),
      );
      await saveDatabases(const [
        DbConnection(
          id: 'pg',
          kind: DbKind.postgres,
          hostId: 'box',
          name: 'the pg',
          port: 5432,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: HostsPage(
            repository: repository,
            secrets: secrets,
            sessions: SessionManager(),
            onOpenHost: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    Future<void> rightClickOn(WidgetTester tester, String text) async {
      await tester.tap(find.text(text), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
    }

    testWidgets('opens its ⋮ menu on a desktop', (tester) async {
      final repository = await pumpHome(tester);

      await rightClickOn(tester, 'box');
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect((await repository.load()).map((h) => h.label), [
        'box',
        'box (copy)',
      ]);

      await rightClickOn(tester, 'the pg');
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Duplicate'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('opens nothing on Android', (tester) async {
      await pumpHome(tester);
      await rightClickOn(tester, 'box');
      expect(find.text('Edit'), findsNothing);
    });
  });
}
