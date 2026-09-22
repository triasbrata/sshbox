import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:xterm2/xterm.dart';

/// A local shell that is up at once, says what [say] gives it, and keeps
/// every byte the terminal sends it.
class _Shell implements SessionTransport, TerminalSession {
  final sent = <String>[];
  final _output = StreamController<String>.broadcast();

  void say(String data) => _output.add(data);

  @override
  final status = ValueNotifier(SessionStatus.connected);

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
  Stream<String> get output => _output.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> dispose() async {}

  /// resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Notifications as a desktop's plugin gives them: nothing to say.
class _BareNotifications extends FlutterLocalNotificationsPlatform {}

/// Every Settings page, a copy stacked under another included.
final _settings = find.byType(SettingsPage, skipOffstage: false);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _start(WidgetTester tester, _Shell shell) async {
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
  await tester.pumpWidget(SshboxApp(transport: (_, _) => shell));
  await _settle(tester);
}

Future<void> _pressCmdComma(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.comma);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await _settle(tester);
}

/// A Local shell tab, the terminal focused, and the program in it asking
/// for the kitty keyboard protocol, as Claude Code does — under which xterm2
/// sends a ⌘ key on to the program.
Future<void> _openTerminal(WidgetTester tester, _Shell shell) async {
  await tester.tap(find.text('Local shell'));
  await _settle(tester);
  shell.say('\x1b[>1u');
  await tester.tap(find.byType(TerminalView));
  await _settle(tester);
  expect(
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TerminalView>(),
    isNotNull,
    reason: 'the terminal holds the focus',
  );
  shell.sent.clear();
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'sshbox.telemetry.notice': true,
    }),
  );

  group('on a Mac, ⌘, opens Settings', () {
    testWidgets('from Home, once however often it is pressed, and the same '
        'page Home\'s ⚙ opens', (tester) async {
      await _start(tester, _Shell());
      expect(_settings, findsNothing);

      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);

      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);

      // Back to Home, and in through the ⚙ instead: ⌘, finds it open.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await _settle(tester);
      expect(_settings, findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await _settle(tester);
      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('from a terminal holding the focus, and the key never '
        'reaches the program', (tester) async {
      final shell = _Shell();
      await _start(tester, shell);
      await _openTerminal(tester, shell);

      await _pressCmdComma(tester);
      // The kitty protocol's ⌘, is ESC [ 44 ; 9 u, 44 being the comma.
      expect(shell.sent.join(), isNot(contains('\x1b[44;')));
      expect(_settings, findsOneWidget);

      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('from the app menu\'s Settings…, which the Mac hands over on '
        'sshbox/menu', (tester) async {
      await _start(tester, _Shell());
      Future<void> clickMenu() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'sshbox/menu',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('openSettings'),
          ),
          (_) {},
        );
        await _settle(tester);
      }

      await clickMenu();
      expect(_settings, findsOneWidget);

      await clickMenu();
      expect(_settings, findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  testWidgets(
    'on Linux and Windows the same keys open nothing',
    (tester) async {
      final shell = _Shell();
      await _start(tester, shell);
      await _pressCmdComma(tester);
      expect(_settings, findsNothing);

      await _openTerminal(tester, shell);
      await _pressCmdComma(tester);
      expect(_settings, findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );
}
