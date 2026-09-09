import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows notifications and turns a tap into a route.
///
/// The payload carried by a notification is the same `sshbox://host/<id>` URI
/// the deep link uses, so a tap and an external link land on one code path.
/// When FCM is added it only has to call [showForHost] — none of the routing
/// below changes.
class NotificationGateway {
  NotificationGateway({required this.onOpenLink});

  /// Where a tapped notification is sent. Wired to the same handler that
  /// serves `sshbox://` links.
  final Future<void> Function(Uri uri) onOpenLink;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'sshbox.sessions';
  static const _channelName = 'Sessions';

  Future<void> initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );

    // Cold start: the tap is what launched the app, so the response is waiting
    // here rather than arriving through the callback above.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final payload = launch?.notificationResponse?.payload;
      if (payload != null) unawaited(_route(payload));
    }

    // Android 13+ refuses to post anything without this.
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null) unawaited(_route(payload));
  }

  Future<void> _route(String payload) async {
    final uri = Uri.tryParse(payload);
    if (uri == null) return;
    await onOpenLink(uri);
  }

  /// Posts a notification that reopens [hostId] when tapped.
  Future<void> showForHost({
    required String hostId,
    required String title,
    required String body,
  }) async {
    await _plugin.show(
      // Stable per host, so a second notice for the same host replaces the
      // first instead of stacking up.
      id: hostId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Alerts from hosts you are connected to',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: 'sshbox://host/$hostId',
    );
  }
}
