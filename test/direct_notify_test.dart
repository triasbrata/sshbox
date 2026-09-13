import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/notifications/direct_notify.dart';

void main() {
  late DirectNotify direct;
  late List<(String, String)> shown;

  setUp(() {
    shown = [];
    direct = DirectNotify((title, body) async => shown.add((title, body)));
  });

  /// A request as curl sends one, with [secret] unless another is given.
  String request({
    String? body = 'body=build+done',
    String method = 'POST',
    String path = '/v1/send',
    String? secret,
    String type = 'application/x-www-form-urlencoded',
    int? length,
  }) =>
      '$method $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:34567\r\n'
      'User-Agent: curl/8.5.0\r\n'
      'Accept: */*\r\n'
      'Authorization: Bearer ${secret ?? direct.secret}\r\n'
      'Content-Type: $type\r\n'
      '${body == null ? '' : 'Content-Length: ${length ?? utf8.encode(body).length}\r\n'}'
      '\r\n'
      '${body ?? ''}';

  /// Sends [text] down a tunnel, [chunk] bytes at a time, and hands back
  /// everything that came up it before it was hung up.
  Future<String> send(String text, {int chunk = 1 << 20}) async {
    final up = StreamController<Uint8List>();
    final down = StreamController<List<int>>();
    final answer = down.stream.expand((bytes) => bytes).toList();
    final served = direct.serve((output: up.stream, input: down.sink));
    final bytes = utf8.encode(text);
    for (var i = 0; i < bytes.length; i += chunk) {
      up.add(bytes.sublist(i, min(i + chunk, bytes.length)));
    }
    await served;
    return utf8.decode(await answer);
  }

  test('a form shows its title and body, and is answered ok', () async {
    final reply = await send(
      request(body: 'title=Build&body=build+done+in+4m'),
    );
    expect(reply, startsWith('HTTP/1.1 200 OK\r\n'));
    expect(reply, contains('Connection: close\r\n'));
    expect(reply, endsWith('\r\n\r\n{"ok":true}'));
    expect(shown, [('Build', 'build done in 4m')]);
  });

  test('so does JSON', () async {
    final reply = await send(
      request(
        type: 'application/json',
        body: jsonEncode({'title': 'Deploy', 'body': 'selesai'}),
      ),
    );
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(shown, [('Deploy', 'selesai')]);
  });

  test('with no title it is Jeansh, and the body is trimmed', () async {
    await send(request(body: 'body=%20%20done%0A'));
    expect(shown, [('Jeansh', 'done')]);
  });

  test('a long body and title are cut, between whole characters', () async {
    await send(
      request(
        type: 'application/json',
        body: jsonEncode({'title': '😀' * 101, 'body': 'x' * 1500}),
      ),
    );
    expect(shown.single.$1, '😀' * 100);
    expect(shown.single.$2, 'x' * 1000);
  });

  test('a request split across reads is put back together', () async {
    final reply = await send(request(body: 'body=done'), chunk: 7);
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(shown, [('Jeansh', 'done')]);
  });

  test('a wrong or missing secret is refused', () async {
    expect(
      await send(request(secret: 'guess')),
      startsWith('HTTP/1.1 401 Unauthorized\r\n'),
    );
    final other = DirectNotify((_, _) async {});
    expect(
      await send(request(secret: other.secret)),
      startsWith('HTTP/1.1 401'),
    );
    expect(
      await send(request().replaceFirst(RegExp('Authorization: .*\r\n'), '')),
      startsWith('HTTP/1.1 401'),
    );
    expect(shown, isEmpty);
  });

  test('only POST /v1/send is answered', () async {
    expect(
      await send(request(path: '/v1/key')),
      startsWith('HTTP/1.1 404 Not Found\r\n'),
    );
    final get = await send(request(method: 'GET', body: null));
    expect(get, startsWith('HTTP/1.1 405 Method Not Allowed\r\n'));
    expect(get, contains('Allow: POST\r\n'));
    expect(shown, isEmpty);
  });

  test('a request with nothing to say is refused', () async {
    for (final bad in [
      request(body: 'title=Build'),
      request(body: 'body=%20%20'),
      request(body: 'body=%zz'),
      request(type: 'application/json', body: '{"body": 5}'),
      request(type: 'application/json', body: '["body"]'),
      request(type: 'application/json', body: '{"body":'),
      request(body: null),
      'POST /v1/send\r\n\r\n',
    ]) {
      expect(await send(bad), startsWith('HTTP/1.1 400 Bad Request\r\n'));
    }
    expect(shown, isEmpty);
  });

  test('one that ends early is refused', () async {
    final up = StreamController<Uint8List>();
    final down = StreamController<List<int>>();
    final answer = down.stream.expand((bytes) => bytes).toList();
    final served = direct.serve((output: up.stream, input: down.sink));
    up.add(utf8.encode(request(length: 100)));
    await up.close();
    await served;
    expect(utf8.decode(await answer), startsWith('HTTP/1.1 400'));
  });

  test('more than 16 KB is refused without waiting for it', () async {
    expect(
      await send(request(length: 20000)),
      startsWith('HTTP/1.1 413 Content Too Large\r\n'),
    );
    expect(
      await send('POST /v1/send HTTP/1.1\r\nX: ${'a' * 17000}'),
      startsWith('HTTP/1.1 413'),
    );
    expect(shown, isEmpty);
  });

  testWidgets('one that has not arrived in five seconds is hung up on', (
    tester,
  ) async {
    final up = StreamController<Uint8List>();
    final down = StreamController<List<int>>();
    final answer = <int>[];
    var hungUp = false;
    down.stream.listen(answer.addAll, onDone: () => hungUp = true);
    unawaited(direct.serve((output: up.stream, input: down.sink)));
    up.add(utf8.encode('POST /v1/send HTTP/1.1\r\n'));

    await tester.pump(const Duration(seconds: 4));
    expect(hungUp, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(hungUp, isTrue);
    expect(answer, isEmpty);
  });

  test("the shell's URL and secret, a fresh secret each connection", () {
    expect(direct.environment(34567), {
      'LC_SSHBOX_NOTIFY_URL': 'http://127.0.0.1:34567/v1/send',
      'LC_SSHBOX_NOTIFY_SECRET': direct.secret,
    });
    // 32 bytes, base64url with no padding.
    expect(direct.secret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(DirectNotify((_, _) async {}).secret, isNot(direct.secret));
  });
}
