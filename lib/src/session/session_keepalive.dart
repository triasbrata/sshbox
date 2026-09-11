import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'session_manager.dart';

/// Keeps the app's process alive while any session is connected.
///
/// Android freezes a backgrounded app, and its TCP connections die with it.
/// That is not a theoretical concern here: opening the file picker to upload
/// something was enough to drop a live shell, because picking a file
/// backgrounds the app. A foreground service with a persistent notification is
/// what Termux and Termius run for exactly this reason.
///
/// There is no iOS equivalent — a suspended app there always has to reconnect,
/// so this is a no-op off Android.
class SessionKeepAlive {
  SessionKeepAlive(this._sessions);

  final SessionManager _sessions;

  bool _initialized = false;

  /// Last count we acted on, so a rebuild that changes nothing does not churn
  /// the service.
  int _lastCount = -1;

  void attach() => _sessions.addListener(_onSessionsChanged);

  void detach() => _sessions.removeListener(_onSessionsChanged);

  void _onSessionsChanged() => unawaited(_sync());

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

    final count = _sessions.liveCount;
    if (count == _lastCount) return;
    _lastCount = count;

    _ensureInitialized();

    if (count == 0) {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      return;
    }

    final text = '$count session${count == 1 ? '' : 's'} connected';

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationText: text);
      return;
    }

    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Clode',
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
