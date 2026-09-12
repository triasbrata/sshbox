import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:toastification/toastification.dart';

import 'data/host_repository.dart';
import 'data/secret_store.dart';
import 'models/host_profile.dart';
import 'notifications/notification_gateway.dart';
import 'notifications/push_messaging.dart';
import 'session/port_forwards.dart';
import 'session/session_keepalive.dart';
import 'session/session_log.dart';
import 'session/session_manager.dart';
import 'ui/settings_page.dart';
import 'ui/tabs_shell.dart';

class SshboxApp extends StatefulWidget {
  const SshboxApp({super.key});

  @override
  State<SshboxApp> createState() => _SshboxAppState();
}

class _SshboxAppState extends State<SshboxApp> {
  /// Files another app handed us, waiting for a session to send them to.
  static const _shareChannel = MethodChannel('sshbox/share');

  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final SecretStore _secrets = KeystoreSecretStore();
  final SessionManager _sessions = SessionManager();
  late final HostRepository _repository = HostRepository(_secrets);

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  late final NotificationGateway _notifications =
      NotificationGateway(onOpenLink: _handleLink);
  late final PushMessaging _push = PushMessaging(
    notifications: _notifications,
    onOpenLink: _handleLink,
  );

  late final SessionKeepAlive _keepAlive =
      SessionKeepAlive(_sessions, portForwards);

  @override
  void initState() {
    super.initState();
    _keepAlive.attach();
    sessionLog.follow(_sessions);
    unawaited(_startNotifications());
    unawaited(_listenForLinks());
    unawaited(_listenForShares());
  }

  Future<void> _startNotifications() async {
    // Local notifications first: FCM only delivers messages, the display and
    // tap routing below it are shared.
    await _notifications.initialize();
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
      case 'host':
        await openHost(hostId);
      case 'notify' when kDebugMode:
        await _notifications.showForHost(
          hostId: hostId,
          title: uri.queryParameters['title'] ?? 'Clode',
          body: uri.queryParameters['body'] ?? 'Tap to return to your session',
        );
    }
  }

  /// "Take me back to my session, or start a new one":
  /// [SessionManager.openOrCreate] returns a terminal already open on this
  /// host, and only builds a new one when there isn't any — then makes it the
  /// showing tab either way. That is what a notification tap wants.
  ///
  /// [newSession] is the host list's tap instead: another shell on the host,
  /// however many it already has. Nothing is pushed on the navigator either
  /// way: the tab strip is a view of the session registry, so selecting there
  /// is the whole of "show me this session".
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

    final session = newSession
        ? _sessions.open(host)
        : _sessions.openOrCreate(host);

    // Handed over after the session has just been made the showing tab — so
    // the upload runs on the page the user is looking at.
    session.queueUploads(_pendingShares);
    _pendingShares.clear();
  }

  /// Files shared into the app before there was anywhere to put them.
  final List<SharedFile> _pendingShares = [];

  /// "Share with Clode" from another app.
  ///
  /// Same two arrival paths as a link: a cold start leaves the files waiting on
  /// the Android side until we ask, a warm one pushes them at us.
  Future<void> _listenForShares() async {
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'shared') _handleShared(call.arguments);
    });
    _handleShared(await _shareChannel.invokeMethod<List<dynamic>>('takeShared'));
  }

  void _handleShared(Object? payload) {
    if (payload is! List) return;
    _pendingShares.addAll(
      payload.cast<Map<dynamic, dynamic>>().map(
            (file) => (
              path: file['path'] as String,
              name: file['name'] as String,
            ),
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
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          'Open a host to upload ${_pendingShares.length} shared file(s)',
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_linkSubscription?.cancel());
    _keepAlive.detach();
    unawaited(_keepAlive.shutdown());
    unawaited(_sessions.closeAll());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Toasts (see `showToast`) stack under the status bar, three at most: a
    // fourth pushes the oldest out rather than reaching down over the shell.
    return ToastificationWrapper(
      config: const ToastificationConfig(maxToastLimit: 3),
      // The mode and palette picked in Settings. A change rebuilds the app's
      // theme only: every page keeps its state.
      child: ValueListenableBuilder(
        valueListenable: appTheme,
        builder: (context, look, _) {
          ThemeData themeOf(Brightness brightness) => ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: look.seed,
              brightness: brightness,
            ),
          );

          return MaterialApp(
            title: 'Clode',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: _messengerKey,
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
              child: child!,
            ),
            home: TabsShell(
              repository: _repository,
              secrets: _secrets,
              sessions: _sessions,
              onOpenHost: (hostId) => openHost(hostId, newSession: true),
              pushToken: () => _push.token,
            ),
          );
        },
      ),
    );
  }
}
