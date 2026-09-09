import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'data/host_repository.dart';
import 'data/secret_store.dart';
import 'models/host_profile.dart';
import 'notifications/notification_gateway.dart';
import 'notifications/push_messaging.dart';
import 'session/session_keepalive.dart';
import 'session/session_manager.dart';
import 'ui/hosts_page.dart';
import 'ui/terminal_page.dart';

class SshboxApp extends StatefulWidget {
  const SshboxApp({super.key});

  @override
  State<SshboxApp> createState() => _SshboxAppState();
}

class _SshboxAppState extends State<SshboxApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
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

  late final SessionKeepAlive _keepAlive = SessionKeepAlive(_sessions);

  @override
  void initState() {
    super.initState();
    _keepAlive.attach();
    unawaited(_startNotifications());
    unawaited(_listenForLinks());
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
  /// [NotificationGateway.showForHost].
  Future<void> _handleLink(Uri uri) async {
    if (uri.scheme != 'sshbox') return;
    if (uri.pathSegments.isEmpty) return;
    final hostId = uri.pathSegments.first;

    switch (uri.host) {
      case 'host':
        await openHost(hostId);
      case 'notify':
        await _notifications.showForHost(
          hostId: hostId,
          title: uri.queryParameters['title'] ?? 'sshbox',
          body: uri.queryParameters['body'] ?? 'Tap to return to your session',
        );
    }
  }

  /// The single rule behind "take me back to my session, or start a new one":
  /// [SessionManager.openOrCreate] returns the terminal that is already open
  /// for this host, and only builds a new one when there isn't any.
  ///
  /// Both a notification tap and a tap in the host list come through here, so
  /// they cannot drift apart.
  Future<void> openHost(String hostId) async {
    final hosts = await _repository.load();
    HostProfile? host;
    for (final candidate in hosts) {
      if (candidate.id == hostId) {
        host = candidate;
        break;
      }
    }
    if (host == null) return;

    final session = _sessions.openOrCreate(host);
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    // Keep at most one terminal page on the stack. The sessions themselves are
    // untouched by this — they live in the manager, not in the routes.
    navigator.popUntil((route) => route.isFirst);
    unawaited(
      navigator.push(
        MaterialPageRoute(
          builder: (_) => TerminalPage(session: session, secrets: _secrets),
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
    return MaterialApp(
      title: 'sshbox',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      // A terminal is a dark surface; forcing dark keeps the app chrome from
      // fighting the terminal's own palette.
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4CC38A),
          brightness: Brightness.dark,
        ),
      ),
      home: HostsPage(
        repository: _repository,
        secrets: _secrets,
        sessions: _sessions,
        onOpenHost: openHost,
        pushToken: () => _push.token,
      ),
    );
  }
}
