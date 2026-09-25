import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/update/updater.dart';

import 'tui_finders.dart';

/// A shell nobody opens: the app wants a transport, and these tests never
/// leave Home.
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

/// The feed, naming [label]'s build for Linux, and how often it was read.
class _Feed {
  _Feed(this.label);

  String label;
  var reads = 0;

  Updater updater() => Updater(
    fetch: (_) async {
      reads++;
      final [version, build] = label.split('+');
      return Stream.value(
        utf8.encode(
          jsonEncode({
            'version': version,
            'build': int.parse(build),
            'platforms': {
              'linux': {
                'path': 'desktop/linux/Jeansh-$label-linux-x64.tar.gz',
                'size': 100,
                'sha256': '0' * 64,
              },
            },
          }),
        ),
      );
    },
    host: 'https://builds.example.test',
    version: '1.0.62+66',
    feed: _feed,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The app, against [feed], having [checkedToday] or not.
Future<void> _start(
  WidgetTester tester,
  _Feed feed, {
  bool checkedToday = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'sshbox.telemetry.notice': true,
    if (checkedToday) Updater.checkedKey: DateTime.now().millisecondsSinceEpoch,
  });
  updater = feed.updater();
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
}

/// The native menu's Check for updates…, as each platform hands it over.
Future<void> _clickMenu(WidgetTester tester) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'sshbox/menu',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('checkForUpdates'),
      ),
      (_) {},
    );

final _dialog = find.text('Jeansh 1.0.63 is out');
// By the widget, not its semantics: under the dialog, Home's are blocked.
final _marker = findTuiButton('Update 1.0.63');

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

  testWidgets('the menu\'s Check for updates offers a newer release', (
    tester,
  ) async {
    final feed = _Feed('1.0.63+67');
    await _start(tester, feed);
    expect(feed.reads, 0, reason: 'checked today already');

    await _clickMenu(tester);
    await _settle(tester);
    expect(feed.reads, 1);
    expect(_dialog, findsOneWidget);
  }, variant: linux);

  testWidgets('Help at the window\'s top right checks for updates, as the '
      'native menu did', (tester) async {
    final feed = _Feed('1.0.63+67');
    await _start(tester, feed);

    await tester.tap(find.bySemanticsLabel('Help'));
    await _settle(tester);
    await tester.tap(find.text('Check for updates…'));
    await _settle(tester);
    expect(feed.reads, 1);
    expect(_dialog, findsOneWidget);
  }, variant: linux);

  testWidgets('the menu\'s Check for updates says so when up to date', (
    tester,
  ) async {
    await _start(tester, _Feed('1.0.62+66'));
    await _clickMenu(tester);
    await _settle(tester);
    expect(find.text('Jeansh is up to date'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  }, variant: linux);

  testWidgets('two menu clicks in a row give one dialog, and a third while '
      'it is up gives none', (tester) async {
    final feed = _Feed('1.0.63+67');
    await _start(tester, feed);
    await _clickMenu(tester);
    await _clickMenu(tester);
    await _settle(tester);
    expect(_dialog, findsOneWidget);

    await _clickMenu(tester);
    await _settle(tester);
    expect(_dialog, findsOneWidget);
  }, variant: linux);

  testWidgets('the daily check puts a marker on Home, which the dialog '
      'dismissed leaves', (tester) async {
    await _start(tester, _Feed('1.0.63+67'), checkedToday: false);
    expect(_dialog, findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Not now'));
    await _settle(tester);
    expect(_dialog, findsNothing);
    expect(_marker, findsOneWidget);

    await tester.tap(_marker);
    await _settle(tester);
    expect(_dialog, findsOneWidget);
  }, variant: linux);

  testWidgets('a check finding nothing newer clears the marker', (
    tester,
  ) async {
    final feed = _Feed('1.0.63+67');
    await _start(tester, feed, checkedToday: false);
    await tester.tap(find.bySemanticsLabel('Not now'));
    await _settle(tester);
    expect(_marker, findsOneWidget);

    feed.label = '1.0.62+66';
    await _clickMenu(tester);
    await _settle(tester);
    expect(_marker, findsNothing);
    await tester.pump(const Duration(seconds: 10));
  }, variant: linux);

  testWidgets('the running app asks the daily check again every hour', (
    tester,
  ) async {
    final feed = _Feed('1.0.63+67');
    await _start(tester, feed);
    expect(feed.reads, 0);

    // A day on, as far as the once-a-day rule can tell.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(Updater.checkedKey, 0);
    await tester.pump(const Duration(hours: 1));
    await _settle(tester);
    expect(feed.reads, 1);
    expect(_marker, findsOneWidget);
  }, variant: linux);
}
