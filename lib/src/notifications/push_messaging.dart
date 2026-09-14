import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notification_gateway.dart';
import 'notify_key.dart';

/// FCM wiring. This is only the *delivery* half — everything about what a tap
/// does already lives in [NotificationGateway] and the `sshbox://` router, and
/// none of it changes here.
///
/// A message is expected to carry `hostId` in its data payload:
///
/// ```json
/// { "data": { "hostId": "1788717544349041", "title": "…", "body": "…" } }
/// ```
///
/// Data-only messages are deliberate: a `notification` block would let Android
/// post its own notification while the app is backgrounded, and that one has
/// no payload to route with. Sending data only keeps every tap going through
/// the same path.
class PushMessaging {
  PushMessaging({
    required this.notifications,
    required this.onOpenLink,
    required this.notifyKeys,
  });

  final NotificationGateway notifications;
  final Future<void> Function(Uri uri) onOpenLink;

  /// Given every registration token FCM hands over, to register each host's
  /// key for with the relay: the token itself goes to no server.
  final NotifyKeys notifyKeys;

  Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      // A missing or mismatched google-services.json should not take the whole
      // app down — the terminal works fine without push.
      debugPrint('sshbox: Firebase init failed, push disabled ($error)');
      return;
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();

    // Registration fails transiently — an IOException here is common on a
    // first launch and clears on the next one. Letting it escape would abort
    // the rest of this method and leave the message handlers unregistered,
    // so push would stay dead for the whole run rather than just this attempt.
    // Never logged: debugPrint reaches logcat in a release build too.
    try {
      final token = await messaging.getToken();
      if (token != null) unawaited(notifyKeys.useFcmToken(token));
    } catch (error) {
      debugPrint('sshbox: FCM registration failed, will retry on next launch ($error)');
    }
    messaging.onTokenRefresh.listen(
      (token) => unawaited(notifyKeys.useFcmToken(token)),
    );

    // App in the foreground: FCM hands us the message and posts nothing, so we
    // raise the notification ourselves.
    FirebaseMessaging.onMessage.listen(_showFrom);

    // Tapped while the app was backgrounded but alive.
    FirebaseMessaging.onMessageOpenedApp.listen(_routeFrom);

    // Tapped while the app was dead — the message is waiting rather than
    // arriving on a stream.
    final initial = await messaging.getInitialMessage();
    if (initial != null) unawaited(_routeFrom(initial));
  }

  Future<void> _showFrom(RemoteMessage message) async {
    final hostId = message.data['hostId'];
    if (hostId is! String || hostId.isEmpty) return;

    await notifications.showForHost(
      hostId: hostId,
      title: message.data['title'] as String? ??
          message.notification?.title ??
          'Jeansh',
      body: message.data['body'] as String? ??
          message.notification?.body ??
          'Tap to return to your session',
    );
  }

  Future<void> _routeFrom(RemoteMessage message) async {
    final hostId = message.data['hostId'];
    if (hostId is! String || hostId.isEmpty) return;
    await onOpenLink(Uri.parse('sshbox://host/$hostId'));
  }
}
