import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../session/terminal_session.dart';

/// A server's way to notify the phone straight down one SSH connection, with
/// no FCM and no relay: the host listens on a port of its loopback for us
/// (`ssh -R`, see `LiveSession`), and each connection made to it comes down
/// the SSH connection to [serve], which answers it as a tiny HTTP/1.1 server
/// would. Nothing listens on the phone itself, so no network it is on can
/// reach it.
///
/// One per connection, with a secret of its own that only that connection's
/// shells are given: see [environment].
class DirectNotify {
  DirectNotify(this.onNotify);

  /// Shows what a request asked to, the way a push is shown.
  final Future<void> Function(String title, String body) onNotify;

  /// What a request must carry as `Authorization: Bearer <secret>`: 32 random
  /// bytes, base64url.
  final String secret = base64Url
      .encode([for (var i = 0; i < 32; i++) _random.nextInt(256)])
      .replaceAll('=', '');
  static final _random = Random.secure();

  /// Headers and body together, past which a request is refused with 413.
  static const maxRequest = 16 * 1024;

  /// How long a request has to arrive in full before the tunnel is hung up.
  static const timeout = Duration(seconds: 5);

  /// What a shell on this connection reads to reach [serve], with [port] the
  /// one the host listens on for us.
  Map<String, String> environment(int port) => {
    'LC_SSHBOX_NOTIFY_URL': 'http://127.0.0.1:$port/v1/send',
    'LC_SSHBOX_NOTIFY_SECRET': secret,
  };

  /// Reads one request off [tunnel], answers it, shows it when it is a good
  /// one, and hangs up. Neither the secret nor what a request says is ever
  /// logged.
  Future<void> serve(Tunnel tunnel) async {
    final request = BytesBuilder(copy: false);
    final answered = Completer<_Reply?>();
    void settle(_Reply? reply) {
      if (!answered.isCompleted) answered.complete(reply);
    }

    // A deadline for the whole request, not for each read, so one sent a
    // byte at a time cannot hold the tunnel open.
    final deadline = Timer(timeout, () => settle(null));
    final reading = tunnel.output.listen(
      (chunk) {
        request.add(chunk);
        final reply = _evaluate(request.toBytes());
        if (reply != null) settle(reply);
      },
      onError: (Object _) => settle(null),
      onDone: () => settle(
        _evaluate(request.toBytes()) ?? _refuse(400, 'incomplete request'),
      ),
    );

    final reply = await answered.future;
    deadline.cancel();
    unawaited(reading.cancel());
    if (reply != null) {
      final json = jsonEncode(
        reply.status == 200 ? {'ok': true} : {'ok': false, 'error': reply.error},
      );
      final extra = switch (reply.status) {
        401 => 'WWW-Authenticate: Bearer\r\n',
        405 => 'Allow: POST\r\n',
        _ => '',
      };
      tunnel.input.add(
        utf8.encode(
          'HTTP/1.1 ${reply.status} ${_reasons[reply.status]}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${utf8.encode(json).length}\r\n'
          '${extra}Connection: close\r\n'
          '\r\n'
          '$json',
        ),
      );
      if (reply.status == 200) onNotify(reply.title!, reply.body!).ignore();
    }
    await tunnel.input.close();
  }

  /// What to answer [request] with, or null while more of it is to come.
  _Reply? _evaluate(Uint8List request) {
    final headEnd = _blankLine(request);
    if (headEnd < 0) {
      return request.length > maxRequest
          ? _refuse(413, 'request too large')
          : null;
    }
    final lines = latin1.decode(request.sublist(0, headEnd)).split('\r\n');
    final start = lines.first.split(' ');
    if (start.length != 3) return _refuse(400, 'bad request line');
    final headers = {
      for (final line in lines.skip(1))
        if (line.indexOf(':') case final colon when colon > 0)
          line.substring(0, colon).trim().toLowerCase(): line
              .substring(colon + 1)
              .trim(),
    };

    if (start[1].split('?').first != '/v1/send') {
      return _refuse(404, 'not found');
    }
    if (start[0] != 'POST') return _refuse(405, 'use POST');
    if (!_same(headers['authorization'] ?? '', 'Bearer $secret')) {
      return _refuse(401, 'wrong or missing secret');
    }
    final length = int.tryParse(headers['content-length'] ?? '');
    if (length == null || length < 0) {
      return _refuse(400, 'Content-Length required');
    }
    final bodyStart = headEnd + 4;
    if (bodyStart + length > maxRequest) {
      return _refuse(413, 'request too large');
    }
    if (request.length < bodyStart + length) return null;

    final fields = _fields(
      request.sublist(bodyStart, bodyStart + length),
      headers['content-type'] ?? '',
    );
    if (fields == null) return _refuse(400, 'unreadable body');
    final body = _cut(fields['body'], 1000);
    if (body.isEmpty) return _refuse(400, 'body is required');
    final title = _cut(fields['title'], 100);
    return (
      status: 200,
      error: null,
      title: title.isEmpty ? 'Jeansh' : title,
      body: body,
    );
  }
}

typedef _Reply = ({int status, String? error, String? title, String? body});

_Reply _refuse(int status, String error) =>
    (status: status, error: error, title: null, body: null);

const _reasons = {
  200: 'OK',
  400: 'Bad Request',
  401: 'Unauthorized',
  404: 'Not Found',
  405: 'Method Not Allowed',
  413: 'Content Too Large',
};

/// Where the blank line that ends the headers starts, or -1 before it has
/// arrived.
int _blankLine(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// `title` and `body` from a form — what `curl --data-urlencode` sends — or
/// from JSON. Null when the body cannot be read as either.
Map<String, String>? _fields(List<int> bytes, String contentType) {
  try {
    final text = utf8.decode(bytes);
    if (!contentType.contains('json')) return Uri.splitQueryString(text);
    final json = jsonDecode(text);
    if (json is! Map) return null;
    return {
      for (final name in const ['title', 'body'])
        if (json[name] case final String value) name: value,
    };
  } catch (_) {
    // Not UTF-8, not JSON, or a broken %-escape.
    return null;
  }
}

/// [text] trimmed and cut to [max] characters, whole ones.
String _cut(String? text, int max) =>
    String.fromCharCodes((text ?? '').trim().runes.take(max));

/// Compares [given] with [expected] in time that says nothing about how much
/// of it was right.
bool _same(String given, String expected) {
  if (given.length != expected.length) return false;
  var difference = 0;
  for (var i = 0; i < given.length; i++) {
    difference |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return difference == 0;
}
