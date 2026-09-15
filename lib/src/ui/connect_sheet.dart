import 'dart:async';

import 'package:flutter/material.dart';

import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/session_manager.dart';
import 'terminal_page.dart' show ConnectionError;

/// Another terminal on [host], connected in a sheet and given its tab by
/// [sessions] once it is up, or once its sign-in has gone to a web tab beside
/// it: what a tap on a host's card does, and a notification tap for a host
/// with nothing open. Null when the sheet was closed first: the session is
/// let go, and never had a tab. [transport] is a test's, as
/// [SessionManager.create] takes one.
Future<LiveSession?> openInSheet(
  BuildContext context,
  SessionManager sessions,
  HostProfile host, {
  required SecretStore secrets,
  TransportMaker? transport,
}) async {
  final session = sessions.create(host, transport: transport);
  final kept = await connectInSheet(
    context,
    session,
    secrets: secrets,
    // A tab of its own first, for its sign-in's to open beside.
    inTab: (url) => sessions
      ..add(session)
      ..openWeb(session.id, url),
  );
  if (!kept) {
    session.dispose();
    return null;
  }
  // Up in the sheet. One sent to sign in has its tab already.
  if (!sessions.sessions.contains(session)) sessions.add(session);
  return session;
}

/// Connects [session] in a bottom sheet over [context]: a new one, or one
/// whose tab has ended. The sheet names the host and shows how the connect
/// is going — a host key to rule on, a sign-in to finish, or why it failed,
/// with Try again — and closes by itself once the shell is up.
///
/// A sign-in's Open link closes it too, and the connect carries on without
/// it: [inTab] opens the link in a web tab beside the session's shell, which
/// closes itself once the session is through — see [LiveSession.openWeb].
///
/// True once connected, or carrying on at a sign-in. Closed before that —
/// swiped away, Close, or Cancel on a host key — the connect is given up: see
/// [LiveSession.abandon].
Future<bool> connectInSheet(
  BuildContext context,
  LiveSession session, {
  required SecretStore secrets,
  required void Function(Uri url) inTab,
}) async {
  final kept = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ConnectSheet(session: session, secrets: secrets),
  );
  if (kept != true) {
    session.abandon();
    return false;
  }
  // Closed by Open link, with the connect still going: its sign-in.
  final url = session.authUrl;
  if (session.connecting && url != null) inTab(url);
  return true;
}

/// Asks in a sheet of its own whether to trust a host key that is not the
/// one pinned for its host: what a port forward asks through, with no
/// connect sheet on screen. Anything but Trust or Replace key refuses it.
Future<bool> confirmHostKey(BuildContext context, HostKeyCheck check) async {
  if (!context.mounted) return false;
  final trusted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => SingleChildScrollView(
      padding: _padding,
      child: _HostKeyPrompt(
        check: check,
        onAnswer: (trusted) => Navigator.of(context).pop(trusted),
      ),
    ),
  );
  return trusted ?? false;
}

/// Under a sheet's drag handle, which leaves room enough above.
const _padding = EdgeInsets.fromLTRB(24, 0, 24, 24);

class _ConnectSheet extends StatefulWidget {
  const _ConnectSheet({required this.session, required this.secrets});

  final LiveSession session;
  final SecretStore secrets;

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  /// The host key being asked about, and where the answer goes. One at a
  /// time: the transport asks for each hop in turn.
  HostKeyCheck? _check;
  Completer<bool>? _answer;

  LiveSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    // After the frame: connecting tells whatever shows the session — the
    // tabs, and a reconnecting tab's page — which must not hear of it while
    // this sheet is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    // Closed with a question open: that is a no.
    _answer?.complete(false);
    super.dispose();
  }

  /// From scratch, whatever the session had: a new one has nothing to let
  /// go of, and Try again starts over.
  Future<void> _connect() async {
    if (!mounted) return;
    await _session.reconnect(secrets: widget.secrets, confirmHostKey: _ask);
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive || !_session.isConnected) return;
    // By route rather than a plain pop when another sheet has opened over
    // this one since — a port forward's host key — which must not be the
    // one closed, and so answered yes.
    final navigator = Navigator.of(context);
    route.isCurrent ? navigator.pop(true) : navigator.removeRoute(route, true);
  }

  Future<bool> _ask(HostKeyCheck check) {
    if (!mounted) return Future.value(false);
    final answer = _answer = Completer<bool>();
    setState(() => _check = check);
    return answer.future;
  }

  /// Trust or Replace key carries on; Cancel closes the sheet, which gives
  /// the connect up.
  void _rule(bool trusted) {
    _answer?.complete(trusted);
    _answer = null;
    if (trusted) {
      setState(() => _check = null);
    } else {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = _session.host;
    final check = _check;
    final error = _session.connecting ? null : _session.error;
    final url = _session.connecting ? _session.authUrl : null;

    return SingleChildScrollView(
      padding: _padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(host.displayName, style: theme.textTheme.titleLarge),
          Text(
            '${host.username}@${host.host}:${host.port}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (check != null)
            _HostKeyPrompt(check: check, onAnswer: _rule)
          else if (error != null)
            ConnectionError(
              message: error,
              // A tab brought back after its tmux session went: trying again
              // finds the same, so it offers a new one.
              retryLabel: _session.tmuxGone ? 'Start a new session' : null,
              onRetry: () {
                if (_session.tmuxGone) _session.startNewTmux();
                unawaited(_connect());
              },
              onClose: () => Navigator.of(context).pop(false),
            )
          else if (url != null)
            // Closed with a yes: the connect carries on, and the link opens
            // beside the session's tab — see [connectInSheet].
            AuthCheckPrompt(
              url: url,
              onOpen: () => Navigator.of(context).pop(true),
            )
          else
            Row(
              children: [
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Text('Connecting…', style: theme.textTheme.bodyLarge),
              ],
            ),
        ],
      ),
    );
  }
}

/// A host key that is not the one pinned for its host: the first connect to
/// it, or a key that has changed since, shown beside the old one. Named by
/// its host, because a jump host and the host behind it can ask one after
/// the other. [onAnswer] with true, from Trust or Replace key, is the only
/// yes.
class _HostKeyPrompt extends StatelessWidget {
  const _HostKeyPrompt({required this.check, required this.onAnswer});

  final HostKeyCheck check;
  final void Function(bool trusted) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = check.host;
    final where = host.port == 22 ? host.host : '${host.host}:${host.port}';
    final pinned = check.pinned;
    final error = theme.colorScheme.error;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (pinned != null) ...[
              Icon(Icons.gpp_maybe, color: error),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                pinned == null ? 'Trust $where?' : 'Host key of $where changed',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          pinned == null
              ? 'First connection to ${host.displayName}. Trust it only if '
                    'this fingerprint matches the one '
                    '`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` '
                    'prints on the server.'
              : '${host.displayName} is not showing the key pinned for it. '
                    'The server may have been rebuilt — or something may be '
                    'intercepting the connection.',
        ),
        if (pinned != null) ...[
          const SizedBox(height: 12),
          const Text('Pinned'),
          SelectableText(pinned, style: mono),
        ],
        const SizedBox(height: 12),
        Text(pinned == null ? 'Fingerprint' : 'Now'),
        SelectableText(check.fingerprint, style: mono),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => onAnswer(false),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            pinned == null
                ? FilledButton(
                    onPressed: () => onAnswer(true),
                    child: const Text('Trust'),
                  )
                : TextButton(
                    style: TextButton.styleFrom(foregroundColor: error),
                    onPressed: () => onAnswer(true),
                    child: const Text('Replace key'),
                  ),
          ],
        ),
      ],
    );
  }
}

/// Shown while a server waits for the user to prove who they are somewhere
/// else — Tailscale SSH's check, for instance — in the connect sheet, and on
/// the shell's page while it still waits once the sheet has gone. The
/// connection is still open behind it, and finishing the sign-in is what
/// lets it through, so there is nothing to submit here.
///
/// [onOpen] takes the link to a web tab beside the session's shell, where
/// the user asked for it, and the connect carries on. Some identity
/// providers, Google in particular, refuse to sign in inside an embedded web
/// view; the tab's Open in browser is the way out then. Nothing here passes
/// the web view off as a browser to get past that: the providers' policies
/// forbid it.
class AuthCheckPrompt extends StatelessWidget {
  const AuthCheckPrompt({super.key, required this.url, required this.onOpen});

  final Uri url;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.verified_user_outlined,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'This host wants you to sign in',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Open the link, sign in, and this session continues on its own. '
          'Later sessions will not ask again until the check expires.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open link'),
        ),
        const SizedBox(height: 12),
        SelectableText(
          url.toString(),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
