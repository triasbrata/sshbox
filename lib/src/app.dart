import 'dart:async';
import 'dart:io' show Platform;

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
import 'telemetry/crash_reporting.dart';
import 'telemetry/telemetry.dart';
import 'ui/bug_report.dart';
import 'ui/connect_sheet.dart';
import 'ui/settings_page.dart';
import 'ui/tabs_shell.dart';
import 'ui/toast.dart';
import 'ui/update_dialog.dart';
import 'update/updater.dart';

class SshboxApp extends StatefulWidget {
  const SshboxApp({super.key, @visibleForTesting this.transport});

  /// What every host's tabs connect through: SSH's own, or this machine's
  /// for a local or WSL shell, unless a test brings a stand-in, as
  /// [SessionManager.create] takes one.
  final TransportMaker? transport;

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
    unawaited(_checkForUpdate());
    unawaited(_countThisInstall());
    lastFault.addListener(_offerToReport);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      FocusManager.instance.addEarlyKeyEventHandler(_onSettingsKey);
      _menuChannel.setMethodCallHandler((call) async {
        if (call.method == 'openSettings') _openSettings();
      });
    }
  }

  /// The Mac's app menu: its Settings… item, clicked, arrives here — see
  /// `AppDelegate.openSettings`.
  static const _menuChannel = MethodChannel('sshbox/menu');

  void _openSettings() {
    final navigator = _navigator.currentState;
    if (navigator != null) openSettings(navigator, notifyKeys: _notifyKeys);
  }

  /// Whether this ⌘, went down here, so its key-up is taken too.
  bool _settingsKeyDown = false;

  /// ⌘, on a Mac opens Settings, as it does in every Mac app, wherever the
  /// focus is.
  ///
  /// An early handler rather than a shortcut at the root: the focus chain
  /// runs from the focused widget up, so a terminal holding the focus would
  /// see the key first, and xterm2 sends ⌘ keys on to a program that asked
  /// for the kitty keyboard protocol, as Claude Code does. Taken here, the
  /// key reaches no widget, and not the menu either, which Flutter asks only
  /// with what it leaves unhandled — so Settings opens once.
  KeyEventResult _onSettingsKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.comma) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (!_settingsKeyDown) return KeyEventResult.ignored;
      _settingsKeyDown = false;
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    if (!keys.isMetaPressed ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _settingsKeyDown = true;
    if (event is KeyDownEvent) _openSettings();
    return KeyEventResult.handled;
  }

  /// Once a day, and only while telemetry is on: the install id, the version,
  /// the platform and the OS version, and nothing else. It says nothing here
  /// whatever happens — see [Telemetry.pingDaily].
  ///
  /// The first run of a new install also gets a word about it, since the
  /// switch is on to begin with and a count goes before the user has said
  /// anything. A toast rather than a dialog: it is a thing to know, not a
  /// thing to answer.
  Future<void> _countThisInstall() async {
    unawaited(telemetry.pingDaily());
    if (!telemetryOn.value) return;
    if (!await telemetry.claimFirstRunNotice()) return;
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return;
    showToast(
      context,
      'Jeansh counts installs\nIt sends a daily count and any crashes, never '
      'a hostname, a login, a path or a command. Settings turns it off.',
      duration: const Duration(seconds: 8),
      action: (label: 'Settings', onPressed: _openSettings),
    );
  }

  /// The one offer a run makes: something went wrong, and here is a way to
  /// say so. Shown whether or not telemetry is on, because reporting a bug is
  /// the user's own act — see `showBugReport`.
  void _offerToReport() {
    final fault = lastFault.value;
    if (fault == null) return;
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return;
    showToast(
      context,
      'Jeansh hit an error',
      type: ToastificationType.error,
      action: (
        label: 'Report',
        onPressed: () => showBugReport(context, about: fault),
      ),
    );
  }

  /// Once a day, on a desktop build with an update host baked in: a newer
  /// release offers itself, and anything else — no update, a feed out of
  /// reach, a release with no build for this platform — says nothing here.
  /// Settings' Check for updates is where an answer is always given.
  Future<void> _checkForUpdate() async {
    // What the last update left beside this copy — the copy it replaced, or
    // a build it never swapped in — goes first, and the second is said.
    if (updater.enabled && (updater.install?.cleanUp() ?? false)) {
      await WidgetsBinding.instance.endOfFrame;
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        showToast(
          context,
          'The last update did not go in, so this is still Jeansh '
          '${updater.version}.',
          type: ToastificationType.warning,
        );
      }
    }
    final Update? update;
    try {
      update = await updater.checkDaily();
    } catch (_) {
      return;
    }
    if (update == null) return;
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return;
    await showUpdate(context, update);
  }

  /// The tabs open when the app last went away, back as they were: see
  /// [SessionManager.restoreTabs]. Only this, the one running copy, gets
  /// here: a second hands its intent over before Dart starts.
  Future<void> _restoreTabs() async => _sessions.restoreTabs(
    hosts: await _repository.load(),
    databases: await loadDatabases(),
    transport: widget.transport,
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
  /// [newSession] is Duplicate session instead: another shell on the host,
  /// however many it already has. Either way the tab strip, a view of the
  /// session registry, shows the session once it is up: nothing else is
  /// pushed on the navigator.
  ///
  /// [restoredFirst] is a tap on the host's card, or on its row in Logs:
  /// another shell too, unless a tab of the host brought back from an earlier
  /// run has not connected since — see [SessionManager.restoredTab]. Then
  /// that tab is shown and connected in its sheet instead, because after
  /// Android killed the app the user most likely wants the work they had,
  /// and a new tab would leave it beside the new one, unconnected. On a tmux
  /// host that is the session and whatever runs in it, and a session gone
  /// since says so in the sheet and offers a new one in the same tab; on a
  /// plain host the shell died with the app, but the tab still has its files
  /// to bring back, and is one tab rather than two.
  ///
  /// A tap that opens nothing says why. A host no longer saved is the one
  /// case that can: a notification posted for it before it was deleted, or a
  /// link naming it. The other two ways out stay quiet on purpose. No
  /// navigator cannot happen while the app runs — it is mounted in the same
  /// build as this state, before any await here resumes — and there would be
  /// nothing to say it on. A sheet closed before it connected was closed by
  /// the user, who watched it go.
  Future<void> openHost(
    String hostId, {
    bool newSession = false,
    bool restoredFirst = false,
  }) async {
    // This machine's own shells are saved nowhere, so the repository has no
    // host to find for them — and none has gone missing either. They open
    // as their cards open them, going back to one already open unless
    // another was asked for, as a saved host's do. None is ever brought back
    // from an earlier run, so there is no restored tab to connect first.
    final distro = wslDistroOf(hostId);
    if (hostId == localHostId || distro != null) {
      if (newSession || _sessions.resume(hostId) == null) {
        await (distro == null ? openLocal() : openWsl(distro));
      }
      return;
    }

    final hosts = await _repository.load();
    HostProfile? host;
    for (final candidate in hosts) {
      if (candidate.id == hostId) {
        host = candidate;
        break;
      }
    }
    if (host == null) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        showToast(
          context,
          'That host is no longer saved',
          type: ToastificationType.warning,
        );
      }
      return;
    }

    var session = newSession ? null : _sessions.resume(host.id);
    if (session == null) {
      final context = _navigator.currentContext;
      if (context == null || !context.mounted) return;
      final restored = restoredFirst ? _sessions.restoredTab(host.id) : null;
      if (restored != null) {
        // Taken, so its tab showing opens no sheet of its own over this one.
        restored.takeAutoConnect();
        _sessions.select(restored.id);
        // One still connecting is at its sign-in, in the web tab beside it:
        // shown, and left to finish.
        if (!restored.connecting &&
            !await connectInSheet(
              context,
              restored,
              secrets: _secrets,
              inTab: (url) => _sessions.openWeb(restored.id, url),
            )) {
          return;
        }
        session = restored;
      } else {
        session = await openInSheet(
          context,
          _sessions,
          host,
          secrets: _secrets,
          transport: widget.transport,
        );
      }
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
      transport: widget.transport ?? (_, _) => LocalTransport(),
    );
    _sessions.add(session);
    await session.connect(secrets: _secrets);
  }

  /// A shell in the WSL distro [distro], on the Windows build alone — see
  /// [wslDistros] — opened as [openLocal] opens one.
  ///
  /// Asked of [defaultTargetPlatform], as [isDesktop] is, so a test can be
  /// Windows: off Windows a [LocalTransport] opens the login shell instead,
  /// which would be the wrong shell under the distro's name.
  Future<void> openWsl(String distro) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    final session = _sessions.create(
      wslHost(distro),
      transport:
          widget.transport ?? (_, _) => LocalTransport(wslDistro: distro),
    );
    _sessions.add(session);
    await session.connect(secrets: _secrets);
  }

  /// Files and texts shared into the app before there was anywhere to put
  /// them: see [LiveSession.queueUploads].
  final List<Object> _pendingShares = [];

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
        (share) =>
            share['text'] as String? ??
            (path: share['path'] as String, name: share['name'] as String),
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
    final files = _pendingShares.whereType<SharedFile>().length;
    showToast(
      context,
      files == 0
          ? 'Open a host to paste the shared text'
          : 'Open a host to upload $files shared file(s)',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void dispose() {
    lastFault.removeListener(_offerToReport);
    FocusManager.instance.removeEarlyKeyEventHandler(_onSettingsKey);
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
              onOpenHost: (hostId) =>
                  openHost(hostId, newSession: true, restoredFirst: true),
              onDuplicate: (hostId) => openHost(hostId, newSession: true),
              onOpenLocal: openLocal,
              onOpenWsl: Platform.isWindows ? openWsl : null,
            ),
          );
        },
      ),
    );
  }
}
