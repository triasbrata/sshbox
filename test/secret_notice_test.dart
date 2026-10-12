import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';

/// Notifications as a desktop's plugin gives them: nothing to say.
class _BareNotifications extends FlutterLocalNotificationsPlatform {}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _start(WidgetTester tester) async {
  FlutterLocalNotificationsPlatform.instance = _BareNotifications();
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (_) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
  await tester.pumpWidget(const SshboxApp());
  await _settle(tester);
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'sshbox.telemetry.notice': true,
    }),
  );
  tearDown(() => secretNotice.value = null);

  testWidgets('what the secret store says is toasted as a warning', (
    tester,
  ) async {
    await _start(tester);
    expect(find.text(SecretNotice.movedAway), findsNothing);

    secretNotice.value = SecretNotice(SecretNotice.movedAway);
    await _settle(tester);
    expect(find.text(SecretNotice.movedAway), findsOneWidget);
    expect(find.text(SecretNotice.notMoved), findsNothing);

    // The toast stays long enough to read, then goes.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(SecretNotice.movedAway), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
    expect(find.text(SecretNotice.movedAway), findsNothing);
  });

  testWidgets('clearing the notice, or the app gone, toasts nothing', (
    tester,
  ) async {
    await _start(tester);
    secretNotice.value = null;
    await _settle(tester);
    expect(find.text(SecretNotice.movedAway), findsNothing);
    expect(find.text(SecretNotice.notMoved), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    secretNotice.value = SecretNotice(SecretNotice.notMoved);
    await _settle(tester);
    expect(find.text(SecretNotice.notMoved), findsNothing);
  });
}
