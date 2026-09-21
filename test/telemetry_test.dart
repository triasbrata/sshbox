import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/telemetry/crash_reporting.dart';
import 'package:sshbox/src/telemetry/scrub.dart';
import 'package:sshbox/src/telemetry/telemetry.dart';

/// Stands in for the network: every request made, and what each answers.
/// Nothing in this file ever opens a socket.
class _Net {
  _Net({this.status = 200});

  final int status;
  static const answer = '{"url":"https://x.test/1"}';
  final sent = <(Uri, String)>[];

  Future<({int status, String body})> post(Uri url, String body) async {
    sent.add((url, body));
    return (status: status, body: answer);
  }
}

void _mockInfo() => PackageInfo.setMockInitialValues(
  appName: 'Jeansh',
  packageName: 'cloud.brata.terminal',
  version: '1.0.62',
  buildNumber: '66',
  buildSignature: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockInfo();
    telemetryOn.value = true;
  });

  group('scrub', () {
    test('takes the host, the login and the path out of an SSH failure', () {
      final out = scrub(
        "Could not reach my-box.tail1a2b.ts.net: connecting to "
        "trias@my-box.tail1a2b.ts.net port 22 from 192.168.1.20 failed, key "
        "/home/trias/.ssh/id_ed25519",
      );
      expect(out, isNot(contains('my-box')));
      expect(out, isNot(contains('tail1a2b')));
      expect(out, isNot(contains('trias')));
      expect(out, isNot(contains('192.168.1.20')));
      expect(out, isNot(contains('id_ed25519')));
      expect(out, isNot(contains('.ssh')));
      expect(out, contains('<host>'));
      expect(out, contains('<account>'));
      expect(out, contains('<ip>'));
      expect(out, contains('<path>'));
    });

    test('takes a database URI and the password in it', () {
      final out = scrub(
        'postgresql://admin:hunter2@db.internal.example:5432/payments failed',
      );
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('admin')));
      expect(out, isNot(contains('payments')));
      expect(out, isNot(contains('db.internal.example')));
      expect(out, startsWith('<uri>'));
    });

    test('takes a mongodb and a redis URI too', () {
      expect(
        scrub('mongodb://u:p@10.0.0.4:27017/app'),
        isNot(contains('27017')),
      );
      expect(
        scrub('redis://:secret@cache.lan:6379'),
        isNot(contains('secret')),
      );
    });

    test('takes a whole private key, not just its edges', () {
      final out = scrub(
        'could not read -----BEGIN OPENSSH PRIVATE KEY-----\n'
        'b3BlbnNzaC1rZXktdjEAAAAABG5vbmU\nQyNTUxOQAAACDx\n'
        '-----END OPENSSH PRIVATE KEY-----\n from the field',
      );
      expect(out, isNot(contains('b3BlbnNzaC')));
      expect(out, contains('<key>'));
    });

    test('takes a Windows path', () {
      final out = scrub(r'cannot open C:\Users\Trias\Documents\hosts.json');
      expect(out, isNot(contains('Trias')));
      expect(out, contains('<path>'));
    });

    test('takes a token or a fingerprint but leaves ordinary words', () {
      final out = scrub(
        'bad token ghp_0123456789abcdefghijklmnopqrstuvwxyzAB while opening',
      );
      expect(out, isNot(contains('ghp_')));
      expect(out, contains('while opening'));
    });

    test('takes a host fingerprint whole, not from its first slash on', () {
      // The base64 of a SHA256 fingerprint has slashes in it. The path rule
      // used to start at the first one and leave half a hash behind, which
      // leaked nothing — a fingerprint is public — but read as though the
      // scrubber had lost its grip.
      final out = scrub(
        'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU does not match',
      );
      expect(out, 'SHA256:<redacted> does not match');
    });

    test('an absolute path after an = is still a path', () {
      // The lookbehind that keeps the path rule out of base64 must not keep
      // it out of this: `home/trias` is far too short for the key rule to
      // catch, so blocking the path rule here would leak a login.
      final out = scrub('HOME=/home/trias not set');
      expect(out, isNot(contains('trias')));
      expect(out, contains('<path>'));
    });

    test('leaves a version number alone, being no hostname', () {
      expect(scrub('Release 1.0.62 has no build'), contains('1.0.62'));
    });

    test('leaves a package: frame readable, and scrubs a file:// one', () {
      expect(
        scrubFrame('package:sshbox/src/ui/settings_page.dart'),
        'package:sshbox/src/ui/settings_page.dart',
      );
      expect(scrubFrame('dart:async/zone.dart'), 'dart:async/zone.dart');
      final out = scrubFrame('file:///home/trias/dev/sshbox/lib/main.dart')!;
      expect(out, isNot(contains('trias')));
    });

    test("drops a Jeansh exception's message whole, and keeps the type", () {
      // Every one of these is written to be shown to the user, which is
      // exactly why it holds the user's own world.
      for (final type in [
        'SshSessionException',
        'DbException',
        'GitException',
        'FileBrowserException',
        'TmuxException',
        'UpdateException',
        'SftpStatusError',
        'PlatformException',
      ]) {
        final out = scrubValue(
          type,
          'nothing to commit on /srv/app at my.box',
        )!;
        expect(out, isNot(contains('/srv/app')), reason: type);
        expect(out, isNot(contains('my.box')), reason: type);
        expect(out, contains('dropped'), reason: type);
      }
    });

    test('scrubs, rather than drops, an error that is not one of ours', () {
      final out = scrubValue(
        'RangeError',
        'Invalid value: Not in inclusive range 0..3: 4',
      )!;
      expect(out, contains('Not in inclusive range'));
    });
  });

  group('the event that actually leaves', () {
    SentryEvent eventWith({
      String type = 'StateError',
      String value = 'Bad state: no session for my-box.ts.net',
    }) => SentryEvent(
      serverName: 'trias-laptop',
      user: SentryUser(id: 'u1', ipAddress: '10.1.2.3', username: 'trias'),
      request: SentryRequest(url: 'https://my-box.ts.net/secret'),
      breadcrumbs: [Breadcrumb(message: 'opened /home/trias/notes.md')],
      // ignore: deprecated_member_use
      extra: {'command': 'ssh trias@my-box'},
      exceptions: [
        SentryException(
          type: type,
          value: value,
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                absPath: 'file:///home/trias/dev/sshbox/lib/src/a.dart',
                fileName: '/home/trias/dev/sshbox/lib/src/a.dart',
                function: 'connect',
                lineNo: 12,
                contextLine: "final password = 'hunter2';",
                vars: {'password': 'hunter2'},
                preContext: ['// secret above'],
              ),
              SentryStackFrame(
                fileName: 'package:sshbox/src/session/x.dart',
                function: 'open',
                lineNo: 4,
              ),
            ],
          ),
        ),
      ],
      contexts: Contexts(
        device: SentryDevice(name: "Trias's Pad", model: 'Pad 8'),
        operatingSystem: SentryOperatingSystem(
          name: 'Android',
          version: '15',
          rawDescription: 'Linux trias-laptop 6.6.0 #1 SMP',
          kernelVersion: '6.6.0',
        ),
      ),
    );

    test('carries no user, request, server name, breadcrumb or extra', () {
      final out = scrubEvent(eventWith(), Hint())!;
      expect(out.user, isNull);
      expect(out.request, isNull);
      expect(out.serverName, isNull);
      expect(out.breadcrumbs, anyOf(isNull, isEmpty));
      // ignore: deprecated_member_use
      expect(out.extra, anyOf(isNull, isEmpty));
      // Nothing of any of it survives anywhere in the serialised event.
      final json = jsonEncode(out.toJson());
      for (final leak in [
        'trias',
        'my-box',
        'hunter2',
        '10.1.2.3',
        'notes.md',
        "Trias's Pad",
        'trias-laptop',
      ]) {
        expect(json, isNot(contains(leak)), reason: leak);
      }
    });

    test("keeps the type, the frames and what kind of machine it was", () {
      final out = scrubEvent(eventWith(), Hint())!;
      expect(out.exceptions!.first.type, 'StateError');
      final frames = out.exceptions!.first.stackTrace!.frames;
      expect(frames.last.fileName, 'package:sshbox/src/session/x.dart');
      expect(frames.last.function, 'open');
      expect(frames.last.lineNo, 4);
      expect(out.contexts.device?.model, 'Pad 8');
      expect(out.contexts.device?.name, isNull);
      expect(out.contexts.operatingSystem?.version, '15');
      expect(out.contexts.operatingSystem?.rawDescription, isNull);
    });

    test('drops the source line and the locals of every frame', () {
      final out = scrubEvent(eventWith(), Hint())!;
      final first = out.exceptions!.first.stackTrace!.frames.first;
      expect(first.contextLine, isNull);
      expect(first.vars, anyOf(isNull, isEmpty));
      expect(first.preContext, anyOf(isNull, isEmpty));
    });

    test('says nothing at all about a wrong password or a refused host', () {
      for (final type in ordinaryFailures) {
        expect(scrubEvent(eventWith(type: type), Hint()), isNull, reason: type);
      }
    });

    test('sends nothing once the switch is off', () {
      telemetryOn.value = false;
      expect(scrubEvent(eventWith(), Hint()), isNull);
    });
  });

  group('the count', () {
    test('sends the five things and nothing else, once a day', () async {
      final net = _Net();
      final counter = Telemetry(
        post: net.post,
        host: 'https://t.test',
        enabled: () => true,
      );
      await counter.pingDaily();
      expect(net.sent, hasLength(1));
      expect(net.sent.first.$1.toString(), 'https://t.test/ping');
      final body = jsonDecode(net.sent.first.$2) as Map<String, Object?>;
      expect(body.keys.toSet(), {
        'install',
        'version',
        'build',
        'platform',
        'os',
      });
      expect(body['version'], '1.0.62');
      expect(body['build'], '66');
      // A UUID, not anything the hardware knows about itself.
      expect(body['install'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4')));

      // The same day again asks nothing.
      await counter.pingDaily();
      expect(net.sent, hasLength(1));
    });

    test('keeps the same install id, and makes it only once', () async {
      final net = _Net();
      final counter = Telemetry(
        post: net.post,
        host: 'https://t.test',
        enabled: () => true,
      );
      final first = await counter.installId();
      expect(await counter.installId(), first);
      expect(
        (await SharedPreferences.getInstance()).getString(Telemetry.installKey),
        first,
      );
    });

    test('sends nothing at all with the switch off', () async {
      final net = _Net();
      telemetryOn.value = false;
      await Telemetry(post: net.post, host: 'https://t.test').pingDaily();
      expect(net.sent, isEmpty);
      // And it has not even made an install id to send later.
      expect(
        (await SharedPreferences.getInstance()).getString(Telemetry.installKey),
        isNull,
      );
    });

    test('a dead endpoint costs nothing and says nothing', () async {
      final counter = Telemetry(
        post: (_, _) => throw const SocketException('nothing there'),
        host: 'https://t.test',
        enabled: () => true,
      );
      await expectLater(counter.pingDaily(), completes);
    });

    test('the first-run notice is claimed exactly once', () async {
      final counter = Telemetry(host: 'https://t.test');
      expect(await counter.claimFirstRunNotice(), isTrue);
      expect(await counter.claimFirstRunNotice(), isFalse);
    });
  });

  group('the anonymous report', () {
    test('goes to the relay and gives back where it landed', () async {
      final net = _Net();
      final relay = Telemetry(post: net.post, host: 'https://t.test');
      expect(await relay.report('it broke', 'here is how'), 'https://x.test/1');
      expect(net.sent.single.$1.toString(), 'https://t.test/issue');
      final body = jsonDecode(net.sent.single.$2) as Map<String, Object?>;
      expect(body['title'], 'it broke');
      expect(body['body'], 'here is how');
    });

    test('works with the switch off: the user pressed the button', () async {
      final net = _Net();
      telemetryOn.value = false;
      await Telemetry(post: net.post, host: 'https://t.test').report('a', 'b');
      expect(net.sent, hasLength(1));
    });

    test('cuts a body the relay would refuse', () async {
      final net = _Net();
      final relay = Telemetry(post: net.post, host: 'https://t.test');
      await relay.report('t', 'x' * (maxReportBody + 500));
      final body = jsonDecode(net.sent.single.$2) as Map<String, Object?>;
      expect((body['body']! as String).length, maxReportBody);
    });

    test('says what a refusal means, in words fit to show', () async {
      for (final (status, word) in [
        (429, 'tomorrow'),
        (403, 'switched off'),
        (500, '500'),
      ]) {
        final relay = Telemetry(
          post: _Net(status: status).post,
          host: 'https://t.test',
        );
        await expectLater(
          relay.report('t', 'b'),
          throwsA(
            isA<TelemetryException>().having(
              (e) => e.message,
              'message',
              contains(word),
            ),
          ),
        );
      }
    });
  });

  test('a fault is turned into a scrubbed line and its first frames', () {
    final text = faultText(
      FlutterErrorDetails(
        exception: StateError('no session for my-box.ts.net'),
        stack: StackTrace.fromString(
          '#0      open (package:sshbox/src/session/x.dart:4:3)\n'
          '#1      main (file:///home/trias/dev/sshbox/lib/main.dart:9:1)',
        ),
      ),
    );
    expect(text, isNot(contains('my-box')));
    expect(text, isNot(contains('trias')));
    expect(text, contains('package:sshbox/src/session/x.dart'));
  });
}
