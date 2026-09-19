import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../files/file_browser.dart';
import '../files/transfers.dart';

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
      // Every platform the app is built for has to be named here, or the
      // plugin throws "settings must be set when targeting <platform>" as it
      // starts — which is what the Mac did, before the shell was even drawn.
      // The Darwin ones ask for permission to post as they initialise; the
      // icon is the app's own there, so there is nothing to name. Windows
      // names the app to its toasts by the Play package name, and the GUID is
      // Jeansh's own, made once: it is what a tapped toast activates.
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_jeansh'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'Jeansh',
          appUserModelId: 'cloud.brata.terminal',
          guid: '526e8ae7-be97-40b8-b1f8-fbd5e998b685',
        ),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );

    // Cold start: the tap is what launched the app, so the response is waiting
    // here rather than arriving through the callback above. Not on Linux,
    // where a notification never starts the app and the plugin throws
    // UnimplementedError for asking — which, uncaught, left the Linux build
    // with no transfer notifications at all.
    if (defaultTargetPlatform == TargetPlatform.linux) return;
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final payload = launch?.notificationResponse?.payload;
      if (payload != null) unawaited(_route(payload));
    }

    // Android 13+ refuses to post anything without this.
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    // A transfer's Cancel. It brings the app forward, to the Transfers tab,
    // as a tap does: one that left the app behind would start a second
    // Flutter engine to run in, with no way to reach the transfer here.
    if (response.actionId == _cancelAction) {
      final id = int.tryParse(
        Uri.tryParse(payload ?? '')?.pathSegments.firstOrNull ?? '',
      );
      final transfers = _transfers;
      final transfer = transfers?.items.where((t) => t.id == id).firstOrNull;
      if (transfer != null) transfers!.cancel(transfer);
    }
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

  static const _transfersChannelId = 'sshbox.transfers';
  static const _cancelAction = 'cancel';

  /// Where a transfer's notification ids start, clear of the per-host ones
  /// in practice: those are hashes, and a clash only replaces one notice.
  static const _transferIds = 0x5a5e0000;

  Transfers? _transfers;

  /// The state each transfer's notification was last posted in, and when.
  final Map<int, ({TransferState state, Duration at})> _posted = {};
  final _clock = Stopwatch()..start();

  /// Follows [transfers] with a notification for each, as a browser follows
  /// its downloads, on a channel of its own that makes no sound: the file's
  /// name, a bar, how much of it, and Cancel, no more than once a second and
  /// alerting once; then what came of it. Cancelled, it goes. A tap opens the
  /// Transfers tab, through `sshbox://transfers`.
  Future<void> followTransfers(Transfers transfers) async {
    _transfers = transfers;
    transfers.addListener(_followTransfers);
    // A bar still up from a run before this one stopped with it: a transfer
    // does not outlive the app.
    try {
      for (final left in await _plugin.getActiveNotifications()) {
        final id = left.id;
        if (left.channelId == _transfersChannelId && id != null) {
          await _plugin.cancel(id: id);
        }
      }
    } catch (_) {
      // Only a stale bar rides on it.
    }
  }

  void _followTransfers() {
    final now = _clock.elapsed;
    for (final transfer in _transfers!.items) {
      // Cancel tapped: gone at once, whatever the work does after.
      final state = transfer.cancelling
          ? TransferState.cancelled
          : transfer.state;
      final posted = _posted[transfer.id];
      if (posted != null &&
          (posted.state == TransferState.cancelled ||
              posted.state == state &&
                  (state != TransferState.running ||
                      now - posted.at < const Duration(seconds: 1)))) {
        continue;
      }
      _posted[transfer.id] = (state: state, at: now);
      unawaited(_showTransfer(transfer, state));
    }
  }

  Future<void> _showTransfer(Transfer transfer, TransferState state) async {
    final id = _transferIds + transfer.id;
    if (state == TransferState.cancelled) return _plugin.cancel(id: id);
    final down = transfer.direction == TransferDirection.download;
    final running = state == TransferState.running;
    final fraction = transfer.fraction;
    final total = transfer.total;
    final (title, body) = switch (state) {
      TransferState.running => (
        transfer.name,
        [
          if (fraction != null) '${(fraction * 100).floor()}%',
          total > 0
              ? '${formatBytes(transfer.done)} of ${formatBytes(total)}'
              : formatBytes(transfer.done),
        ].join(' · '),
      ),
      TransferState.done => (
        '${down ? 'Downloaded' : 'Uploaded'} ${transfer.name}',
        [
          formatBytes(total > 0 ? total : transfer.done),
          if (transfer.host.isNotEmpty)
            '${down ? 'from' : 'to'} ${transfer.host}',
        ].join(' '),
      ),
      _ => (
        '${down ? 'Download' : 'Upload'} failed',
        '${transfer.name}: ${transfer.error}',
      ),
    };
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _transfersChannelId,
          'Transfers',
          channelDescription: 'Downloads and uploads under way',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          ongoing: running,
          autoCancel: !running,
          showProgress: running,
          maxProgress: 100,
          progress: ((fraction ?? 0) * 100).floor(),
          indeterminate: running && fraction == null,
          category: running ? AndroidNotificationCategory.progress : null,
          actions: running
              ? const [
                  AndroidNotificationAction(
                    _cancelAction,
                    'Cancel',
                    showsUserInterface: true,
                  ),
                ]
              : null,
        ),
      ),
      payload: 'sshbox://transfers/${transfer.id}',
    );
  }
}
