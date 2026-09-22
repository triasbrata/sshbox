import 'dart:async';

import 'package:flutter/material.dart';

import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/session_manager.dart';
import '../session/tmux.dart';
import '../platform.dart';
import 'terminal_page.dart' show ConnectionError, openUrl;
import 'tui.dart';

/// Another terminal on [host], connected in a sheet and given its tab by
/// [sessions] once it is up, or once its sign-in has gone to a web tab beside
/// it: what a tap on a host's card does, and a notification tap for a host
/// with nothing open. Null when the sheet was closed first: the session is
/// let go, and never had a tab. [transport] is a test's, as
/// [SessionManager.create] takes one.
///
/// [pickTmux] is Attach: once connected, the sheet lists the tmux sessions
/// running on the host, and the tab joins the one picked instead of starting
/// one of its own. What a tab's long press offers, and a host's card, the
/// way back to a session left running with Detach.
Future<LiveSession?> openInSheet(
  BuildContext context,
  SessionManager sessions,
  HostProfile host, {
  required SecretStore secrets,
  TransportMaker? transport,
  bool pickTmux = false,
}) async {
  final session = sessions.create(
    host,
    transport: transport,
    pickTmux: pickTmux,
  );
  final kept = await connectInSheet(
    context,
    session,
    secrets: secrets,
    // Every tmux session this host already has a tab for, shown and not
    // offered: two tabs on one session would fight over its size, tmux
    // giving the window to whichever client attached last.
    taken: {for (final open in sessions.sessionsFor(host.id)) open.tmuxName},
    // A tab of its own first, for its sign-in's to open beside. On a desktop
    // there are no web tabs at all, so the sign-in goes to the machine's own
    // browser — where the user is likely signed in to the identity provider
    // already — and the session waits for it exactly as before.
    inTab: (url) {
      if (isDesktop) {
        sessions.add(session);
        unawaited(openUrl(context, url));
        return;
      }
      sessions
        ..add(session)
        ..openWeb(session.id, url);
    },
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
///
/// [taken] are the tmux sessions not to offer, when the session asks which
/// to join: see [openInSheet].
Future<bool> connectInSheet(
  BuildContext context,
  LiveSession session, {
  required SecretStore secrets,
  required void Function(Uri url) inTab,
  Set<String> taken = const {},
}) async {
  final kept = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) =>
        _ConnectSheet(session: session, secrets: secrets, taken: taken),
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
  const _ConnectSheet({
    required this.session,
    required this.secrets,
    required this.taken,
  });

  final LiveSession session;
  final SecretStore secrets;
  final Set<String> taken;

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  /// The host key being asked about, and where the answer goes. One at a
  /// time: the transport asks for each hop in turn.
  HostKeyCheck? _check;
  Completer<bool>? _answer;

  /// The tmux sessions being offered, and where the one picked goes: asked
  /// the way a host key is, in this sheet, part way through the connect.
  List<TmuxSessionInfo>? _found;
  Completer<String?>? _picked;

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
    _picked?.complete(null);
    super.dispose();
  }

  /// From scratch, whatever the session had: a new one has nothing to let
  /// go of, and Try again starts over.
  Future<void> _connect() async {
    if (!mounted) return;
    await _session.reconnect(
      secrets: widget.secrets,
      confirmHostKey: _ask,
      pickTmux: _pick,
    );
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

  Future<String?> _pick(List<TmuxSessionInfo> found) {
    if (!mounted) return Future.value();
    final picked = _picked = Completer<String?>();
    setState(() => _found = found);
    return picked.future;
  }

  void _choose(String name) {
    _picked?.complete(name);
    _picked = null;
    setState(() => _found = null);
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
    final found = _found;
    final error = _session.connecting ? null : _session.error;
    final url = _session.connecting ? _session.authUrl : null;

    return SingleChildScrollView(
      padding: _padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(host.displayName, style: theme.textTheme.titleLarge),
          // A prompt's chevron before where it goes, as Termul draws a
          // command line.
          Row(
            children: [
              ExcludeSemantics(
                child: Text(
                  '❯ ',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  '${host.username}@${host.host}:${host.port}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (check != null)
            _HostKeyPrompt(check: check, onAnswer: _rule)
          else if (found != null) ...[
            TmuxSessionList(
              sessions: found,
              taken: widget.taken,
              onPick: _choose,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
          ] else if (error != null)
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
/// the address that answered, never by the address the host is saved with:
/// a key reached over the alternative address belongs to whatever is at that
/// address, and a prompt that named the other one would ask the user to trust
/// a machine that was never reached. The host's own name comes along, because
/// a jump host and the host behind it can ask one after the other.
/// [onAnswer] with true, from Trust or Replace key, is the only yes.
class _HostKeyPrompt extends StatelessWidget {
  const _HostKeyPrompt({required this.check, required this.onAnswer});

  final HostKeyCheck check;
  final void Function(bool trusted) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = check.host;
    final where = host.port == 22
        ? check.address
        : '${check.address}:${host.port}';
    final alternative = check.address != host.host;
    final pinned = check.pinned;
    final other = check.otherAddress;
    final error = theme.colorScheme.error;
    const mono = TextStyle(fontFamily: tuiFontFamily, fontSize: 13);
    Widget boxed(String fingerprint) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectableText(fingerprint, style: mono),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (pinned != null || other != null) ...[
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
        Text(switch ((pinned, alternative)) {
          (final String _, _) =>
            'Something at $where is answering for ${host.displayName} with '
                'a key that is not the one pinned for that address. The '
                'server may have been rebuilt — or something may be '
                'intercepting the connection.',
          (null, true) =>
            'First connection to ${host.displayName} at its alternative '
                'address, $where. Trust it only if this fingerprint '
                'matches the one '
                '`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` '
                'prints on the server.',
          (null, false) =>
            'First connection to ${host.displayName} at $where. Trust it '
                'only if this fingerprint matches the one '
                '`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` '
                'prints on the server.',
        }),
        if (other != null) ...[
          const SizedBox(height: 12),
          Text(
            'The other address of ${host.displayName}, ${other.address}, is '
            'pinned to a different key. Two addresses of one machine show '
            'the same key, so this is either a different machine or '
            'something sitting on $where.',
            style: TextStyle(color: error),
          ),
          const SizedBox(height: 12),
          Text('Pinned for ${other.address}'),
          boxed(other.fingerprint),
        ],
        if (pinned != null) ...[
          const SizedBox(height: 12),
          const Text('Pinned'),
          boxed(pinned),
        ],
        const SizedBox(height: 12),
        Text(pinned == null ? 'Fingerprint' : 'Now'),
        boxed(check.fingerprint),
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

/// The tmux sessions running on a host, for Attach to pick one of: its name,
/// how many windows, when it started and last wrote, and whether a client is
/// attached to it already.
///
/// The app's own sessions come first, as the user asked for: they are the
/// ones a tab made, told by their name, and the rest are whatever somebody
/// started at a terminal. Within each group the session that wrote something
/// most recently is at the top, as [TmuxSession.parseList] sorts them, since
/// what brings anybody here is a thing they left running.
///
/// Every name is drawn as plain text. It comes from the host and can hold a
/// quote, a `$( )` or a backtick; nothing here interprets one, and the only
/// place a name goes afterwards is `TmuxSession.attachExisting`, which
/// passes it to the host as one quoted argument.
class TmuxSessionList extends StatelessWidget {
  const TmuxSessionList({
    super.key,
    required this.sessions,
    required this.onPick,
    this.taken = const {},
  });

  final List<TmuxSessionInfo> sessions;
  final void Function(String name) onPick;

  /// The names this host already has a tab on, shown and not offered.
  final Set<String> taken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    bool ours(TmuxSessionInfo session) =>
        LiveSession.tmuxNamePattern.hasMatch(session.name);
    final mine = sessions.where(ours).toList();
    final theirs = sessions.where((session) => !ours(session)).toList();
    // A heading over one list of one kind says nothing; over two it says
    // which is which.
    final headings = mine.isNotEmpty && theirs.isNotEmpty;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    Widget row(TmuxSessionInfo session) =>
        _TmuxRow(session, taken: taken.contains(session.name), onPick: onPick);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Attach to a tmux session', style: theme.textTheme.titleMedium),
        if (headings) heading("Jeansh's own"),
        for (final session in mine) row(session),
        if (headings) heading('Started on the host'),
        for (final session in theirs) row(session),
      ],
    );
  }
}

/// One session in [TmuxSessionList]: its name, and the little tmux can say
/// about it for free.
class _TmuxRow extends StatelessWidget {
  const _TmuxRow(this.session, {required this.taken, required this.onPick});

  final TmuxSessionInfo session;

  /// Open in a tab here already: see [openInSheet].
  final bool taken;
  final void Function(String name) onPick;

  /// How long ago, as the chat's session list says it.
  static String _ago(DateTime at) {
    final since = DateTime.now().difference(at);
    if (since.inMinutes < 1) return 'just now';
    if (since.inHours < 1) return '${since.inMinutes}m ago';
    if (since.inDays < 1) return '${since.inHours}h ago';
    return '${since.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    // A name tmux reads as an id however it is asked for would join another
    // session: see [LiveSession.tmuxNameAllowed].
    final reachable = LiveSession.tmuxNameAllowed(session.name);
    final windows = session.windows == 1
        ? '1 window'
        : '${session.windows} windows';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !taken && reachable,
      title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          windows,
          'started ${_ago(session.created)}',
          // Only when something has happened since: a session nobody has
          // typed in carries the time it was made as its activity too, and
          // saying it twice tells nobody anything.
          if (session.activity.isAfter(session.created))
            'wrote ${_ago(session.activity)}',
          if (taken)
            'open in a tab here'
          else if (!reachable)
            "tmux can't be asked for it by name"
          else if (session.inUse)
            'attached elsewhere',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: taken || !reachable ? null : () => onPick(session.name),
    );
  }
}
