import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/update_dialog.dart';
import 'package:sshbox/src/update/updater.dart';

/// A release's whole `latest.json`, with [platforms] as given.
String feedJson({
  String version = '1.0.63',
  int build = 67,
  Map<String, Object?> platforms = const {
    'linux': {
      'path': 'desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz',
      'size': 100,
      'sha256':
          '0000000000000000000000000000000000000000000000000000000000000000',
    },
  },
}) => jsonEncode({
  'version': version,
  'build': build,
  'platforms': platforms,
});

/// Stands in for the network: every URL asked for, and what each answers.
class _Net {
  _Net(this.answers);

  /// By URL: the bytes it gives back, or the error it throws.
  final Map<String, Object> answers;
  final asked = <String>[];

  Future<Stream<List<int>>> fetch(Uri url) async {
    asked.add(url.toString());
    final answer = answers[url.toString()];
    if (answer == null) throw UpdateException('nothing at $url');
    if (answer is Exception) throw answer;
    final bytes = answer as List<int>;
    // In two pieces, as a real body arrives.
    return Stream.fromIterable([
      bytes.sublist(0, bytes.length ~/ 2),
      bytes.sublist(bytes.length ~/ 2),
    ]);
  }
}

const _feed = 'https://example.test/latest.json';
const _host = 'https://builds.example.test';

Updater _updater(_Net net, {String version = '1.0.62+66', String host = _host}) =>
    Updater(fetch: net.fetch, host: host, version: version, feed: _feed);

/// The updater is a desktop's, and under `flutter test` the platform is
/// Android, which has no desktop build to update. The widget tests take their
/// platform from a variant instead: a `testWidgets` must leave every
/// foundation debug variable unset.
void asLinux() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
}

void main() {
  group('the version comparison', () {
    test('counts each part as a number, not as text', () {
      expect(isNewer('1.0.10', '1.0.9'), isTrue);
      expect(isNewer('1.0.9', '1.0.10'), isFalse);
      expect(isNewer('1.10.0', '1.9.99'), isTrue);
      expect(isNewer('2.0.0', '1.999.999'), isTrue);
    });

    test('takes the build number when the name is the same', () {
      expect(isNewer('1.0.62+67', '1.0.62+66'), isTrue);
      expect(isNewer('1.0.62+66', '1.0.62+66'), isFalse);
      expect(isNewer('1.0.62+65', '1.0.62+66'), isFalse);
    });
  });

  group('the feed', () {
    test('a good one gives the path, the size and the sha256', () {
      final update = parseFeed(feedJson(), 'linux');
      expect(update.version, '1.0.63');
      expect(update.build, 67);
      expect(update.label, '1.0.63+67');
      expect(update.name, 'Jeansh-1.0.63+67-linux-x64.tar.gz');
      expect(update.size, 100);
      expect(
        update.url(_host).toString(),
        '$_host/desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz',
      );
    });

    test('a broken one says so rather than half-reading it', () {
      expect(
        () => parseFeed('{"version": "1.0.63", "platforms"', 'linux'),
        throwsA(isA<UpdateException>()),
      );
      expect(
        () => parseFeed('[]', 'linux'),
        throwsA(isA<UpdateException>()),
      );
    });

    test('one with no build for this platform names it', () {
      expect(
        () => parseFeed(feedJson(), 'windows'),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            contains('no windows build'),
          ),
        ),
      );
    });

    test('a path that would leave the baked host is refused', () {
      for (final path in [
        'https://elsewhere.test/evil.tar.gz',
        '/etc/passwd',
        '../../evil.tar.gz',
      ]) {
        expect(
          () => parseFeed(
            feedJson(
              platforms: {
                'linux': {
                  'path': path,
                  'size': 100,
                  'sha256': '0' * 64,
                },
              },
            ),
            'linux',
          ),
          throwsA(isA<UpdateException>()),
          reason: path,
        );
      }
    });
  });

  group('checking', () {
    asLinux();

    test('offers a newer release', () async {
      final net = _Net({_feed: utf8.encode(feedJson())});
      final update = await _updater(net).check();
      expect(update?.label, '1.0.63+67');
      expect(net.asked, [_feed]);
    });

    test('offers nothing for a release this build already is, or older',
        () async {
      final net = _Net({_feed: utf8.encode(feedJson())});
      expect(await _updater(net, version: '1.0.63+67').check(), isNull);
      expect(await _updater(net, version: '1.0.64+68').check(), isNull);
    });

    test('with no update host baked in, nothing is asked', () async {
      final net = _Net({_feed: utf8.encode(feedJson())});
      final updater = _updater(net, host: '');
      expect(updater.enabled, isFalse);
      expect(await updater.check(), isNull);
      expect(await updater.checkDaily(), isNull);
      expect(net.asked, isEmpty);
    });

    test('nothing is asked on a phone, which updates through its store',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final net = _Net({_feed: utf8.encode(feedJson())});
      expect(_updater(net).enabled, isFalse);
      expect(await _updater(net).check(), isNull);
      expect(net.asked, isEmpty);
    });
  });

  group('downloading', () {
    asLinux();

    late Directory into;
    setUp(() => into = Directory.systemTemp.createTempSync('update_test'));
    tearDown(() => into.deleteSync(recursive: true));

    /// A feed whose linux entry describes [bytes] with [digest] as its hash.
    String feedFor(List<int> bytes, {String? digest}) => feedJson(
      platforms: {
        'linux': {
          'path': 'desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz',
          'size': bytes.length,
          'sha256': digest ?? sha256.convert(bytes).toString(),
        },
      },
    );

    test('keeps a file whose sha256 is the one the feed gives', () async {
      final bytes = utf8.encode('a build, near enough' * 100);
      final net = _Net({
        _feed: utf8.encode(feedFor(bytes)),
        '$_host/desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz': bytes,
      });
      final updater = _updater(net);
      final update = (await updater.check())!;

      final seen = <double>[];
      final file = await updater.download(
        update,
        into: into,
        onProgress: (done, total) => seen.add(done / total),
      );

      expect(file!.path, '${into.path}${Platform.pathSeparator}${update.name}');
      expect(file.readAsBytesSync(), bytes);
      expect(seen.last, 1.0);
      expect(into.listSync().length, 1, reason: 'no .part left behind');
    });

    test('Cancel leaves nothing behind', () async {
      final body = StreamController<List<int>>();
      final cancel = Completer<void>();
      final updater = Updater(
        fetch: (_) async => body.stream,
        host: _host,
        version: '1.0.62+66',
        feed: _feed,
      );
      final update = parseFeed(feedJson(), 'linux');

      final download = updater.download(
        update,
        into: into,
        cancelled: cancel.future,
      );
      body.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      body.add([4, 5, 6]);
      await body.close();

      expect(await download, isNull);
      expect(into.listSync(), isEmpty);
    });

    test('a file that is not what the feed describes is deleted', () async {
      final bytes = utf8.encode('not the build it says');
      final net = _Net({
        _feed: utf8.encode(feedFor(bytes, digest: 'a' * 64)),
        '$_host/desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz': bytes,
      });
      final updater = _updater(net);
      final update = (await updater.check())!;

      await expectLater(
        updater.download(update, into: into),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            allOf(contains(update.name), contains('SHA-256')),
          ),
        ),
      );
      expect(into.listSync(), isEmpty);
    });
  });

  testWidgets('a build with no update host says so in Settings', (
    tester,
  ) async {
    final net = _Net({_feed: utf8.encode(feedJson())});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateTile(using: _updater(net, host: ''))),
      ),
    );

    expect(find.textContaining('takes no updates'), findsOneWidget);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(net.asked, isEmpty);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Check for updates offers what the feed names', (tester) async {
    final net = _Net({_feed: utf8.encode(feedJson())});
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UpdateTile(using: _updater(net)))),
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(net.asked, [_feed]);
    expect(find.text('Jeansh 1.0.63 is out'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
