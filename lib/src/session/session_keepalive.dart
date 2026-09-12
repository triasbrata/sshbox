import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'port_forwards.dart';
import 'session_manager.dart';

/// Keeps the app's process alive while any session is connected, or any
/// port forward is switched on.
///
/// Android freezes a backgrounded app, and its TCP connections die with it.
/// That is not a theoretical concern here: opening the file picker to upload
/// something was enough to drop a live shell, because picking a file
/// backgrounds the app. A foreground service with a persistent notification is
/// what Termux and Termius run for exactly this reason. A port forward is for
/// another app on the tablet, so the app is always in the background while
/// it is used.
///
/// There is no iOS equivalent — a suspended app there always has to reconnect,
/// so this is a no-op off Android.
class SessionKeepAlive {
  SessionKeepAlive(this._sessions, this._forwards);

  final SessionManager _sessions;
  final PortForwards _forwards;

  bool _initialized = false;

  /// The notification's text last acted on, so a rebuild that changes
  /// nothing does not churn the service. Empty with the service stopped.
  String? _lastText;

  void attach() {
    _sessions.addListener(_onChanged);
    _forwards.addListener(_onChanged);
  }

  void detach() {
    _sessions.removeListener(_onChanged);
    _forwards.removeListener(_onChanged);
  }

  void _onChanged() => unawaited(_sync());

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sshbox.keepalive',
        channelName: 'Active sessions',
        channelDescription:
            'Keeps open SSH sessions from being frozen in the background',
        // Low importance: this notice exists because Android requires one, not
        // because the user needs to be told anything.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic callback: we only want the process kept alive, so there
        // is no task isolate to run.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _sync() async {
    if (!Platform.isAndroid) return;

    final sessions = _sessions.liveCount;
    final forwards = _forwards.onCount;
    final text = [
      if (sessions > 0) '$sessions session${sessions == 1 ? '' : 's'} connected',
      if (forwards > 0) '$forwards port forward${forwards == 1 ? '' : 's'} on',
    ].join(', ');
    if (text == _lastText) return;
    _lastText = text;

    _ensureInitialized();

    if (text.isEmpty) {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      return;
    }

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationText: text);
      return;
    }

    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Jeansh',
      notificationText: text,
    );
  }

  /// Called on app teardown so a lingering service does not outlive the UI.
  Future<void> shutdown() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
