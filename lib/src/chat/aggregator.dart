import 'dart:async';
import 'dart:convert';

import '../session/terminal_session.dart';
import 'aggregator_script.dart';

/// What the host helper ([aggregatorScript]) says of a message it was given:
/// one line of JSON per call.
class AggregatorReply {
  const AggregatorReply(this.json);

  final Map<String, dynamic> json;

  bool get ok => json['ok'] == true;

  /// `accepted`, `sending`, `sent`, `delivered`, `refused`, `undeliverable`
  /// or `unknown`: see [aggregatorScript]. `unknown-id` for an id the
  /// journal has never seen.
  String? get state => json['state'] as String?;

  String? get reason => json['reason'] as String?;

  /// What the session itself reports, `idle` or `busy`, when it is running.
  String? get sessionStatus => json['sessionStatus'] as String?;

  /// The same id was given before: nothing was written again.
  bool get duplicate => json['duplicate'] == true;

  String? get error => json['error'] as String?;
}

/// Why messages cannot go through the helper on a host, or null.
class AggregatorReady {
  const AggregatorReady.ready() : unavailable = null;
  const AggregatorReady.unavailable(this.unavailable);

  final String? unavailable;

  bool get ready => unavailable == null;
}

/// Chat's side of the host helper: puts it on the host, once, and runs its
/// calls. It talks over a command of the session's own connection, so a call
/// is one short command and the helper is not left running.
class Aggregator {
  Aggregator(this.open, {this.timeout = const Duration(seconds: 20)});

  /// The session's own [ChannelCapable.open].
  final Future<CommandChannel> Function(String command) open;

  /// How long one call may take before it is given up on.
  final Duration timeout;

  Future<AggregatorReady>? _ready;

  /// Puts the helper on the host if it is not there or is older, and asks it
  /// for its version. Done once; a call that could not be made at all (the
  /// connection) is not remembered, so the next message asks again.
  Future<AggregatorReady> ensure() {
    final have = _ready;
    if (have != null) return have;
    final made = _ensure();
    _ready = made;
    made.then((_) {}, onError: (Object _) => _ready = null);
    return made;
  }

  Future<AggregatorReady> _ensure() async {
    final said = (await _run(installShell())).trim();
    switch (said) {
      case 'ok' || 'kept':
        break;
      case 'nopython':
        return const AggregatorReady.unavailable('this host has no python3');
      default:
        return const AggregatorReady.unavailable(
          'the helper could not be put on this host',
        );
    }
    final hello = await call(const ['hello']);
    if (!hello.ok || hello.json['version'] is! int) {
      return const AggregatorReady.unavailable('the helper did not answer');
    }
    return const AggregatorReady.ready();
  }

  /// Runs the helper with [args]. Throws when the host did not answer in
  /// time or said no JSON; the helper's own refusals come back as a reply.
  Future<AggregatorReply> call(List<String> args) async {
    final output = await _run(aggregatorShell(args));
    for (final line in const LineSplitter().convert(output)) {
      if (!line.startsWith('{')) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (json is Map<String, dynamic>) return AggregatorReply(json);
    }
    throw StateError(
      output.trim().isEmpty
          ? 'The helper on the host said nothing.'
          : 'The helper on the host said: ${output.trim()}',
    );
  }

  /// Hands [text] to the helper to deliver to [sessionId], under [id], which
  /// is what makes a second try the same message.
  Future<AggregatorReply> deliver(String id, String sessionId, String text) =>
      call([
        'deliver',
        id,
        sessionId,
        '--text-b64',
        base64Encode(utf8.encode(text)),
      ]);

  Future<AggregatorReply> status(String id) => call(['status', id]);

  Future<String> _run(String command) async {
    final channel = await open(command);
    try {
      final bytes = await channel.output
          .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
          .timeout(timeout);
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } finally {
      channel.close();
    }
  }

  /// The command that installs the helper: [aggregatorScript] goes in as
  /// base64, so nothing of it is quoted into the line, and through `sh -c`,
  /// so a login shell of another kind reads the same words.
  static String installShell() {
    final body =
        'b=${base64Encode(utf8.encode(aggregatorScript))}; '
        'printf %s "\$b" | (base64 -d 2>/dev/null || base64 -D) | { '
        '$aggregatorInstallCommand}';
    return 'sh -c ${_quote(body)}';
  }

  /// One call of the helper, through `sh -c`.
  static String aggregatorShell(List<String> args) =>
      'sh -c ${_quote(aggregatorRunCommand(args))}';

  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}

/// A message the host helper delivered, as the session's transcript holds it:
/// [id] is the helper's id for it (the outbox id), [text] what the user wrote.
class PeerMessage {
  const PeerMessage(this.id, this.text);

  final String id;
  final String text;
}

const _peerOpen = 'Another Claude session sent a message:\n';
const _peerClose = '\n\nThis came from another Claude session';

/// What the session wrote around a message from another session, taken off:
/// its words are the user's. Claude Code 2.1.332 wraps them as
/// `Another Claude session sent a message:\n<text>\n\nThis came from…`; a
/// text it does not recognise is kept whole rather than lost.
String unwrapPeer(String raw) {
  if (!raw.startsWith(_peerOpen)) return raw;
  final end = raw.lastIndexOf(_peerClose);
  return end < _peerOpen.length ? raw : raw.substring(_peerOpen.length, end);
}

/// The message [event], a line of a transcript, carries from the helper, or
/// null when it is not one. Two shapes, measured on 2.1.332: a user line
/// marked `isMeta` whose `origin` names the sender, written when the session
/// was idle, with the text wrapped; and, when it arrived mid-turn, an
/// attachment of type `queued_command` holding the bare text with the
/// `origin` inside it. The sender is `jeansh-<id>`, which the helper sets.
///
/// [userText] reads a user line's `content`.
PeerMessage? peerMessageIn(
  Map<String, dynamic> event,
  String? Function(Object? content) userText,
) {
  String? from(Object? origin) =>
      origin is Map && origin['kind'] == 'peer' && origin['from'] is String
      ? origin['from'] as String
      : null;
  String? id(String? from) =>
      from != null && from.startsWith('jeansh-') && from.length > 7
      ? from.substring(7)
      : null;
  final attachment = event['attachment'];
  if (event['type'] == 'attachment' &&
      attachment is Map &&
      attachment['type'] == 'queued_command' &&
      attachment['prompt'] is String) {
    final sent = id(from(attachment['origin']));
    return sent == null
        ? null
        : PeerMessage(sent, attachment['prompt'] as String);
  }
  if (event['type'] == 'user' && event['isMeta'] == true) {
    final sent = id(from(event['origin']));
    final message = event['message'];
    final raw = message is Map ? userText(message['content']) : null;
    return sent == null || raw == null
        ? null
        : PeerMessage(sent, unwrapPeer(raw));
  }
  return null;
}
