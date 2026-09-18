import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:toastification/toastification.dart';

import 'data/host_repository.dart';
import 'data/secret_store.dart';
import 'db/db_session.dart';
import 'files/transfers.dart';
import 'models/host_profile.dart';
import 'notifications/notification_gateway.dart';
import 'notifications/notify_key.dart';
import 'notifications/push_messaging.dart';
import 'platform.dart';
import 'session/local_transport.dart';
import 'session/port_forwards.dart';
import 'session/session_keepalive.dart';
import 'session/session_log.dart';
import 'session/session_manager.dart';
import 'ui/connect_sheet.dart';
import 'ui/settings_page.dart';
import 'ui/tabs_shell.dart';
import 'ui/toast.dart';

class SshboxApp extends StatefulWidget {
  const SshboxApp({super.key});

  @override
  State<SshboxApp> createState() => _SshboxAppState();
}

class _SshboxAppState extends State<SshboxApp> {
  /// Files another app handed us, waiting for a session to send them to.
  static const _shareChannel = MethodChannel('sshbox/share');

  /// What [openHost] opens a connect sheet from, and what a shared file with
  /// nowhere to go is said from: both run above the app's own navigator, with
  /// no context under them.
  final _navigator = GlobalKey<NavigatorState>();
  final SecretStore _secrets = KeystoreSecretStore();
  late final NotifyKeys _notifyKeys = NotifyKeys(_secrets);
  late final SessionManager _sessions = SessionManager(
    notifyKeys: _notifyKeys,
    onNotify: _notifications.showForHost,
  );
  late final HostRepository _repository = HostRepository(_secrets);

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  late final NotificationGateway _notifications = NotificationGateway(
    onOpenLink: _handleLink,
  );
  late final PushMessaging _push = PushMessaging(
    notifications: _notifications,
    onOpenLink: _handleLink,
    notifyKeys: _notifyKeys,
  );

  late final SessionKeepAlive _keepAlive = SessionKeepAlive(
    _sessions,
    portForwards,
  );

  @override
  void initState() {
    super.initState();
    _keepAlive.attach();
    sessionLog.follow(_sessions);
    unawaited(_restoreTabs());
    unawaited(_startNotifications());
    unawaited(_listenForLinks());
    unawaited(_listenForShares());
  }

  /// The tabs open when the app last went away, back as they were: see
  /// [SessionManager.restoreTabs]. Only this, the one running copy, gets
  /// here: a second hands its intent over before Dart starts.
  Future<void> _restoreTabs() async => _sessions.restoreTabs(
    hosts: await _repository.load(),
    databases: await loadDatabases(),
  );

  Future<void> _startNotifications() async {
    // Local notifications first: FCM only delivers messages, the display and
    // tap routing below it are shared.
    await _notifications.initialize();
    await _notifications.followTransfers(transfers);
    await _push.initialize();
  }

  Future<void> _listenForLinks() async {
    // Cold start: the tap on the notification is what launched us, so the link
    // is waiting rather than arriving on the stream. Missing this case is the
    // usual reason a notification works only when the app was already open.
    final initial = await _appLinks.getInitialLink();
    if (initial != null) unawaited(_handleLink(initial));

    // Warm start: app was already running.
    _linkSubscription = _appLinks.uriLinkStream.listen(_handleLink);
  }

  /// `sshbox://host/<hostId>` opens a host; `sshbox://notify/<hostId>` posts a
  /// notification that opens it when tapped.
  ///
  /// The second exists so the whole notify → tap → resume path can be
  /// exercised end to end without any push infrastructure — adb can fire the
  /// URI directly. Once FCM is wired it calls the same
  /// [NotificationGateway.showForHost]. Debug builds only: any web page or
  /// app can fire the link, and in a release build that would let it post a
  /// notification saying whatever it likes, under the app's name.
  Future<void> _handleLink(Uri uri) async {
    if (uri.scheme != 'sshbox') return;
    if (uri.pathSegments.isEmpty) return;
    final hostId = uri.pathSegments.first;

    switch (uri.host) {
      // `sshbox://transfers/<id>`: a transfer's notification, tapped or
      // cancelled from.
      case 'transfers':
        _sessions.showTransfers(select: true);
      case 'host':
        await openHost(hostId);
      case 'notify' when kDebugMode:
        await _notifications.showForHost(
          hostId: hostId,
          title: uri.queryParameters['title'] ?? 'Jeansh',
          body: uri.queryParameters['body'] ?? 'Tap to return to your session',
        );
    }
  }

  /// "Take me back to my session, or start a new one": what a notification
  /// tap wants. [SessionManager.resume] shows a terminal already open on this
  /// host, and only when there is none does a new one connect, in its sheet.
  ///
  /// [newSession] is the host list's tap instead: another shell on the host,
  /// however many it already has. Either way the tab strip, a view of the
  /// session registry, shows the session once it is up: nothing else is
  /// pushed on the navigator.
  Future<void> openHost(String hostId, {bool newSession = false}) async {
    final hosts = await _repository.load();
    HostProfile? host;
    for (final candidate in hosts) {
      if (candidate.id == hostId) {
        host = candidate;
        break;
      }
    }
    if (host == null) return;

    var session = newSession ? null : _sessions.resume(host.id);
    if (session == null) {
      final context = _navigator.currentContext;
      if (context == null || !context.mounted) return;
      session = await openInSheet(context, _sessions, host, secrets: _secrets);
      // Closed before it connected: the files wait for the next host opened.
      if (session == null) return;
    }

    // Handed over after the session has just been made the showing tab — so
    // the upload runs on the page the user is looking at.
    session.queueUploads(_pendingShares);
    _pendingShares.clear();
  }

  /// A shell on this machine, on the desktop builds that can have one — see
  /// [LocalTransport].
  ///
  /// No connect sheet: there is no address to reach, no host key to rule on
  /// and no sign-in to finish, so the tab opens straight away and whatever the
  /// shell has to say about itself it says in the terminal. A tap when one is
  /// already open adds another, as a tap on a host's card does.
  Future<void> openLocal() async {
    if (!isDesktop) return;
    final session = _sessions.create(
      localHost(),
      transport: (_, _) => LocalTransport(),
    );
    _sessions.add(session);
    await session.connect(secrets: _secrets);
  }

  /// Files shared into the app before there was anywhere to put them.
  final List<SharedFile> _pendingShares = [];

  /// "Share with Jeansh" from another app.
  ///
  /// Same two arrival paths as a link: a cold start leaves the files waiting on
  /// the Android side until we ask, a warm one pushes them at us.
  Future<void> _listenForShares() async {
    // Android alone answers this channel — MainActivity is what takes the
    // files and copies them somewhere SFTP can read. Asking anywhere else
    // throws MissingPluginException as the app starts, which is what the Mac
    // did; the guard is the same one `clipboardImage` and `saveAs` use.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'shared') _handleShared(call.arguments);
    });
    _handleShared(
      await _shareChannel.invokeMethod<List<dynamic>>('takeShared'),
    );
  }

  void _handleShared(Object? payload) {
    if (payload is! List) return;
    _pendingShares.addAll(
      payload.cast<Map<dynamic, dynamic>>().map(
        (file) => (path: file['path'] as String, name: file['name'] as String),
      ),
    );
    if (_pendingShares.isEmpty) return;

    // Straight to the session the user was last in. With no session there is
    // nowhere to upload to yet, so the files wait for the next host they open.
    final active = _sessions.active;
    if (active != null) {
      unawaited(openHost(active.host.id));
      return;
    }
    final context = _navigator.currentContext;
    if (context == null) return;
    // Three seconds rather than a remark's one: it is said as the app comes
    // back from the one the files were shared from.
    showToast(
      context,
      'Open a host to upload ${_pendingShares.length} shared file(s)',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void dispose() {
    unawaited(_linkSubscription?.cancel());
    _keepAlive.detach();
    unawaited(_keepAlive.shutdown());
    // Not closeAll: that would end every tmux session, and save no tabs to
    // come back to.
    unawaited(_sessions.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Toasts (see `showToast`), stacked the way `toastConfig` says.
    return ToastificationWrapper(
      config: toastConfig,
      // The mode and theme picked in Settings. A change rebuilds the app's
      // theme only: every page keeps its state.
      child: ValueListenableBuilder(
        valueListenable: appTheme,
        builder: (context, look, _) {
          ThemeData themeOf(Brightness brightness) => ThemeData(
            useMaterial3: true,
            colorScheme: look.scheme.colorScheme(brightness),
          );

          return MaterialApp(
            title: 'Jeansh',
            debugShowCheckedModeBanner: false,
            navigatorKey: _navigator,
            themeMode: look.mode,
            theme: themeOf(Brightness.light),
            darkTheme: themeOf(Brightness.dark),
            // Under the status bar is the tab strip, with no app bar to set
            // the bar's icons, so they follow the theme from here: the
            // system's white ones would vanish on a light theme.
            builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarIconBrightness:
                    Theme.of(context).brightness == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark,
              ),
              // Toasts over every page, taking only the touches that land on
              // one.
              child: ToastLayer(child: child!),
            ),
            home: TabsShell(
              repository: _repository,
              secrets: _secrets,
              sessions: _sessions,
              onOpenHost: (hostId) => openHost(hostId, newSession: true),
              onOpenLocal: openLocal,
            ),
          );
        },
      ),
    );
  }
}
