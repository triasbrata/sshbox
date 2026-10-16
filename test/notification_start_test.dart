import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/notifications/notification_gateway.dart';
import 'package:sshbox/src/notifications/notify_key.dart';
import 'package:sshbox/src/notifications/push_messaging.dart';

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
      (call) async => call.method == 'notificationIcon' ? '2131165312' : null,
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

  // JEANSH-8: the plugin turns its icon's name into an id with
  // Resources.getIdentifier, whose lookup by name crashed Android 11 in
  // AssetManager2::GetResourceId. A number is returned before any lookup, so
  // the icon goes as MainActivity's id for it, on Test Lab or not; anything
  // but a number and the plugin is not started.
  for (final (answer, sent) in [
    ('2131165312', '2131165312'),
    (null, null),
    ('@drawable/ic_stat_jeansh', null),
  ]) {
    for (final testLab in [true, false]) {
      testWidgets('the notification icon answered $answer (Test Lab $testLab) '
          'starts the plugin with ${sent ?? 'nothing'}', (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        final icons = <Object?>[];
        messenger.setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async {
            if (call.method == 'initialize') {
              icons.add((call.arguments as Map)['defaultIcon']);
              return true;
            }
            return null;
          },
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('sshbox/share'),
          (call) async => switch (call.method) {
            'notificationIcon' => answer,
            'isTestLab' => testLab,
            _ => null,
          },
        );

        await NotificationGateway(onOpenLink: (_) async {}).initialize();

        expect(icons, sent == null ? isEmpty : [sent]);
        expect(icons, isNot(contains('@drawable/ic_stat_jeansh')));
        expect(tester.takeException(), isNull);
      });
    }
  }

  // JEANSH-8 went on after the notification plugin was skipped: FCM's start
  // reads a resource by name too.
  for (final (testLab, starts) in [(true, 0), (false, 1)]) {
    testWidgets(
      testLab
          ? 'on Test Lab Firebase is not started'
          : 'on a normal device Firebase is started',
      (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('sshbox/share'),
          (call) async => call.method == 'isTestLab' ? testLab : null,
        );
        var started = 0;
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.firebase_core_platform_interface.'
          'FirebaseCoreHostApi.initializeCore',
          (_) async {
            started++;
            return null;
          },
        );

        await PushMessaging(
          notifications: NotificationGateway(onOpenLink: (_) async {}),
          onOpenLink: (_) async {},
          notifyKeys: NotifyKeys(InMemorySecretStore()),
        ).initialize();

        expect(started, starts);
      },
    );
  }
}
