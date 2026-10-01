import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/text_size.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:xterm2/xterm.dart';

const _host = HostProfile(
  id: 'h1',
  label: 'box',
  host: '127.0.0.1',
  port: 1,
  username: 'me',
);

/// A host up the moment it is asked for, keeping every window-change.
class _Box implements SessionTransport, TerminalSession {
  final resizes = <(int, int)>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) =>
      resizes.add((columns, rows));

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _quietPlatform(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (call) async => switch (call.method) {
      'initialize' || 'requestNotificationsPermission' => true,
      'getActiveNotifications' => const <Object>[],
      _ => null,
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('sshbox/share'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (_) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
}

class _BareNotifications extends FlutterLocalNotificationsPlatform {}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _start(WidgetTester tester, _Box box, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (defaultTargetPlatform == TargetPlatform.android) {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  } else {
    FlutterLocalNotificationsPlatform.instance = _BareNotifications();
  }
  _quietPlatform(tester);
  await tester.pumpWidget(SshboxApp(transport: (_, _) => box));
  await _settle(tester);
}

/// A shell on the host, from Home's card.
Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Home'));
  await tester.pump();
  await tester.tap(find.text('me@127.0.0.1:1'));
  await _settle(tester);
}

Terminal _terminal(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView).first).terminal;

/// What a text drawn at 13 under [finder] comes out at.
double _at13(WidgetTester tester, Finder finder) =>
    MediaQuery.textScalerOf(tester.element(finder.first)).scale(13);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'sshbox.hosts.v1': jsonEncode([_host.toJson()]),
      'sshbox.telemetry.notice': true,
    });
    uiTextSize.value = 1;
    terminalSettings.value = TerminalSettings.defaultStyle;
  });
  tearDown(() {
    uiTextSize.value = 1;
    terminalSettings.value = TerminalSettings.defaultStyle;
  });

  testWidgets('the UI size grows the chrome and leaves a terminal alone: '
      'same cells, same columns and rows, no window-change', (tester) async {
    final box = _Box();
    await _start(tester, box, const Size(800, 1280));
    await _open(tester);
    final terminal = _terminal(tester);
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    final changes = box.resizes.length;
    expect(_at13(tester, find.byType(TabStrip)), 13);

    await uiTextSize.choose(UiTextSize.max);
    await _settle(tester);

    expect(_at13(tester, find.byType(TabStrip)), 13 * UiTextSize.max);
    expect(_at13(tester, find.byType(TerminalKeyBar)), 13 * UiTextSize.max);
    expect(_at13(tester, find.byType(TerminalView)), 13);
    expect(terminal.viewWidth, columns);
    expect(terminal.viewHeight, rows);
    expect(box.resizes.length, changes, reason: 'no window-change');
    expect(
      (await SharedPreferences.getInstance()).getDouble('sshbox.ui.textScale'),
      UiTextSize.max,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the content size grows what is read in a tab and leaves the '
      'chrome alone', (tester) async {
    final box = _Box();
    await _start(tester, box, const Size(800, 1280));
    await _open(tester);

    await terminalSettings.choose(size: 26);
    await _settle(tester);

    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize,
      26,
    );
    // The terminal's size is its font's, with no scaling on top.
    expect(_at13(tester, find.byType(TerminalView)), 13);
    expect(_at13(tester, find.byType(TabStrip)), 13);
    expect(_at13(tester, find.byType(TerminalKeyBar)), 13);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a swipe from the middle of the slider named Set the UI text '
      'size, as the e2e flow makes, sets the largest UI size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    final slider = find.bySemanticsLabel('Set the UI text size');
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    await tester.dragFrom(tester.getCenter(slider), const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(uiTextSize.value, UiTextSize.max);
    expect(find.text('160%'), findsOneWidget);
  });

  testWidgets('ContentText takes the UI size out and the content size in', (
    tester,
  ) async {
    const prose = Key('prose'), terminal = Key('terminal');
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          textScaler: UiTextScaler(TextScaler.noScaling, 1.6),
        ),
        child: Column(
          children: [
            ContentText(child: SizedBox(key: prose)),
            ContentText(scale: false, child: SizedBox(key: terminal)),
          ],
        ),
      ),
    );
    double at13(Key key) =>
        MediaQuery.textScalerOf(tester.element(find.byKey(key))).scale(13);
    expect(at13(prose), 13);
    expect(at13(terminal), 13);

    terminalSettings.value = terminalStyleOf('monospace', 26);
    await tester.pump();
    expect(at13(prose), 26);
    expect(at13(terminal), 13);
  });

  for (final (name, size, platform) in [
    ('phone', const Size(360, 640), TargetPlatform.android),
    ('tablet', const Size(800, 1280), TargetPlatform.android),
    ('desktop', const Size(1280, 800), TargetPlatform.linux),
  ]) {
    testWidgets('nothing overflows at the largest UI size on a $name: Home, '
        'Settings, a strip of tabs, the key bar and a dialog', (tester) async {
      await uiTextSize.choose(UiTextSize.max);
      final box = _Box();
      await _start(tester, box, size);
      expect(find.byType(HostsPage), findsOneWidget);

      for (var i = 0; i < 4; i++) {
        await _open(tester);
      }
      expect(find.byType(TerminalKeyBar), findsOneWidget);

      await tester.tap(find.byTooltip('Home'));
      await _settle(tester);
      unawaitedDialog(tester);
      await _settle(tester);
      expect(find.byType(TuiDialog), findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await _settle(tester);

      await tester.tap(find.byTooltip('Settings'));
      await _settle(tester);
      final scroll = find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byType(Scrollable),
      );
      for (var i = 0; i < 30; i++) {
        await tester.drag(scroll.first, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _settle(tester);
      // Any overflow on the way failed the test as it was laid out.
    }, variant: TargetPlatformVariant.only(platform));
  }
}

/// The host delete confirmation, termul's TuiDialog, left open.
void unawaitedDialog(WidgetTester tester) {
  showTuiConfirmDialog(
    tester.element(find.byType(HostsPage)),
    title: 'delete host',
    message: 'Delete box?',
    detail:
        'Every open session for this host is closed, its saved password or '
        'private key is removed from the device keystore, and its '
        'notification key is revoked.',
    confirmLabel: 'Delete',
    cancelLabel: 'Cancel',
  );
}
