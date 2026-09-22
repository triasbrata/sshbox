import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';

void main() {
  testWidgets('a notification plugin that will not start costs only local '
      'notifications: nothing uncaught, and FCM still starts (JEANSH-2)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sshbox.hosts.v1': '[]',
      // Past the first run's word about telemetry, which would lie over Home.
      'sshbox.telemetry.notice': true,
    });
    final messenger = tester.binding.defaultBinaryMessenger;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => switch (call.method) {
        'initialize' => throw PlatformException(code: 'invalid_icon'),
        'getActiveNotifications' => const <Object>[],
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('sshbox/share'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.app_links/messages'),
      (_) async => null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('com.llfbandit.app_links/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    // Firebase.initializeApp's first word to the platform, which is how FCM's
    // start is seen here. Answered with nothing, so push gives up as it does
    // with no Firebase config.
    var pushStarted = false;
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.firebase_core_platform_interface.'
      'FirebaseCoreHostApi.initializeCore',
      (_) async {
        pushStarted = true;
        return null;
      },
    );

    await tester.pumpWidget(SshboxApp());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Before, the plugin's refusal reached the zone uncaught, which fails the
    // test, and FCM never started.
    expect(tester.takeException(), isNull);
    expect(pushStarted, isTrue);
  });
}
