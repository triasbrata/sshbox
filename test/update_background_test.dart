import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/update/updater.dart';

import 'tui_finders.dart';

/// Issue #116: closing the update dialog while it downloads — a click outside
/// it, Esc — cancelled the update. It now goes on in the background, and the
/// dialog opened again, or Settings, shows it.

class _NoShell implements SessionTransport {
  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BareNotifications extends FlutterLocalNotificationsPlatform {}

const _feed = 'https://example.test/latest.json';

/// A feed offering 1.0.63, and its build, whose body arrives when the test
/// says so; how often the build was fetched.
class _Release {
  final bytes = utf8.encode('a build, near enough' * 100);
  final body = StreamController<List<int>>();
  final downloads = Directory.systemTemp.createTempSync('update_background');
  var fetches = 0;

  late final updater = _Installable(this);

  Future<Stream<List<int>>> fetch(Uri url) async {
    if (url.toString() == _feed) {
      return Stream.value(
        utf8.encode(
          jsonEncode({
            'version': '1.0.63',
            'build': 67,
            'platforms': {
              'linux': {
                'path': 'desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz',
                'size': bytes.length,
                'sha256': sha256.convert(bytes).toString(),
              },
            },
          }),
        ),
      );
    }
    fetches++;
    return body.stream;
  }

  void half() => body.add(bytes.sublist(0, bytes.length ~/ 2));

  Future<void> rest() async {
    body.add(bytes.sublist(bytes.length ~/ 2));
    await body.close();
  }
}

/// A copy that could put the update in place, which only records being asked.
class _Installable extends Updater {
  _Installable(_Release release)
    : super(
        fetch: release.fetch,
        host: 'https://builds.example.test',
        version: '1.0.62+66',
        feed: _feed,
        downloads: release.downloads,
      );

  final installed = <String>[];

  @override
  String? get installRefusal => null;

  @override
  Future<void> restartInto(Update update, File archive) async =>
      installed.add(archive.path);
}

/// Frames and real I/O in turns: writing the file only runs outside the
/// test's own clock.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

/// The app, whose check at startup offers [release]'s update.
Future<void> _start(WidgetTester tester, _Release release) async {
  addTearDown(() => release.downloads.deleteSync(recursive: true));
  SharedPreferences.setMockInitialValues({'sshbox.telemetry.notice': true});
  updater = release.updater;
  FlutterLocalNotificationsPlatform.instance = _BareNotifications();
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (_) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
  await tester.pumpWidget(SshboxApp(transport: (_, _) => _NoShell()));
  await _settle(tester);
  expect(find.text('Jeansh 1.0.63 is out'), findsOneWidget);
}

/// Download pressed, and half the build in.
Future<void> _downloadHalf(WidgetTester tester, _Release release) async {
  await tester.tap(find.bySemanticsLabel('Download'));
  await tester.pump();
  release.half();
  await _settle(tester);
  expect(find.text('Downloading Jeansh 1.0.63'), findsOneWidget);
}

/// Settings, scrolled to its Updates.
Future<void> _openSettingsAt(WidgetTester tester, Finder target) async {
  await tester.tap(find.byTooltip('Settings'));
  await _settle(tester);
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  final original = updater;
  setUp(() {
    updateAvailable.value = null;
    updateDownload.value = null;
  });
  tearDown(() {
    updater = original;
    updateAvailable.value = null;
    updateDownload.value = null;
  });

  final linux = TargetPlatformVariant.only(TargetPlatform.linux);
  final downloading = find.text('Jeansh 1.0.63 is downloading');
  final checked = find.text('Jeansh 1.0.63 is downloaded and checked.');

  testWidgets('a click outside the dialog leaves the download running, and '
      'Settings shows it and then Restart to update', (tester) async {
    final release = _Release();
    await _start(tester, release);
    await _downloadHalf(tester, release);

    // The barrier, well away from the dialog.
    await tester.tapAt(const Offset(4, 4));
    await _settle(tester);
    expect(find.text('Downloading Jeansh 1.0.63'), findsNothing);

    await _openSettingsAt(tester, downloading);
    expect(downloading, findsOneWidget);
    expect(find.textContaining('1000 B of 2.0 KB'), findsOneWidget);
    expect(findTuiButton('Cancel'), findsOneWidget);

    await release.rest();
    await _settle(tester);
    expect(checked, findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Restart to update'));
    await _settle(tester);
    expect(release.updater.installed, [
      '${release.downloads.path}${Platform.pathSeparator}'
          'Jeansh-1.0.63+67-linux-x64.tar.gz',
    ]);
    expect(release.fetches, 1);
  }, variant: linux);

  testWidgets('Esc leaves it running, and asking again — Home\'s chip, the '
      'menu — shows the same download rather than starting another', (
    tester,
  ) async {
    final release = _Release();
    await _start(tester, release);
    await _downloadHalf(tester, release);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Downloading Jeansh 1.0.63'), findsNothing);

    await tester.tap(findTuiButton('Update 1.0.63'));
    await _settle(tester);
    expect(find.text('Downloading Jeansh 1.0.63'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'sshbox/menu',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('checkForUpdates'),
      ),
      (_) {},
    );
    await _settle(tester);
    expect(find.text('Downloading Jeansh 1.0.63'), findsOneWidget);
    expect(find.bySemanticsLabel('Download'), findsNothing);

    await release.rest();
    await _settle(tester);
    expect(find.text('Jeansh 1.0.63 is ready'), findsOneWidget);
    expect(release.fetches, 1);
  }, variant: linux);

  testWidgets('Cancel still cancels, closes the dialog and leaves no .part', (
    tester,
  ) async {
    final release = _Release();
    await _start(tester, release);
    await _downloadHalf(tester, release);

    await tester.tap(find.bySemanticsLabel('Cancel'));
    await tester.pump();
    // The cancel lands with the next chunk.
    await release.rest();
    await _settle(tester);
    expect(find.text('Downloading Jeansh 1.0.63'), findsNothing);
    expect(updateDownload.value, isNull);
    expect(release.downloads.listSync(), isEmpty);
  }, variant: linux);
}
