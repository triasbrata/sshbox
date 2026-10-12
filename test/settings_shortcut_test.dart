import 'dart:async';

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
  final mac = defaultTargetPlatform == TargetPlatform.macOS;
  final modifier = mac
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.comma);
  await tester.sendKeyUpEvent(modifier);
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
  // The Local shell as a plain one, which [_Shell] is: in tmux it would ask
  // for a channel [_Shell] does not have, and say so over the page.
  setUp(() => localTmux.value = (on: false, path: ''));
  tearDown(() => localTmux.value = (on: true, path: ''));

  final desktops = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  });

  NavigatorState navigator(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  group('⌘, on a Mac, Ctrl+, elsewhere, toggles Settings', () {
    testWidgets('opens it, and again closes it back to Home as it was', (
      tester,
    ) async {
      await _start(tester, _Shell());
      expect(find.text('Local shell'), findsOneWidget);
      expect(_settings, findsNothing);

      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);

      await _pressCmdComma(tester);
      expect(_settings, findsNothing);
      expect(find.text('Local shell'), findsOneWidget);

      // And once more: it opens again.
      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);
    }, variant: desktops);

    testWidgets('closes back to the terminal tab with its state kept, and '
        'the key never reaches the program', (tester) async {
      final shell = _Shell();
      await _start(tester, shell);
      await _openTerminal(tester, shell);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));

      await _pressCmdComma(tester);
      expect(_settings, findsOneWidget);
      await _pressCmdComma(tester);
      expect(_settings, findsNothing);

      // The very same terminal, never rebuilt from scratch.
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(view.terminal),
      );
      // The kitty protocol's ⌘, is ESC [ 44 ; 9 u, 44 being the comma.
      expect(shell.sent.join(), isNot(contains('\x1b[44;')));
      expect(shell.sent.join(), isNot(contains(',')));
    }, variant: desktops);

    testWidgets('from a sub-page of Settings it goes all the way out', (
      tester,
    ) async {
      await _start(tester, _Shell());
      await _pressCmdComma(tester);
      await _settle(tester);
      final row = find.bySemanticsLabel('Key bar');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await _settle(tester);
      expect(find.byType(KeyBarSettingsPage), findsOneWidget);

      await _pressCmdComma(tester);
      expect(find.byType(KeyBarSettingsPage), findsNothing);
      expect(_settings, findsNothing);
      expect(find.text('Local shell'), findsOneWidget);
    }, variant: desktops);

    testWidgets('opened by the ⚙ tap, it toggles the same way', (tester) async {
      await _start(tester, _Shell());
      await tester.tap(find.byTooltip('Settings'));
      await _settle(tester);
      expect(_settings, findsOneWidget);

      await _pressCmdComma(tester);
      expect(_settings, findsNothing);
    }, variant: desktops);

    testWidgets('with a field focused in a dialog over Settings it still '
        'works, and types no comma', (tester) async {
      await _start(tester, _Shell());
      await _pressCmdComma(tester);
      final controller = TextEditingController();
      final nav = navigator(tester);
      unawaited(
        showDialog<void>(
          context: nav.context,
          builder: (_) => AlertDialog(
            content: TextField(controller: controller, autofocus: true),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(TextField), findsOneWidget);

      await _pressCmdComma(tester);
      expect(find.byType(TextField), findsNothing);
      expect(_settings, findsNothing);
      expect(controller.text, isNot(contains(',')));
    }, variant: desktops);

    testWidgets('the comma alone does nothing', (tester) async {
      await _start(tester, _Shell());
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await _settle(tester);
      expect(_settings, findsNothing);

      await _pressCmdComma(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await _settle(tester);
      expect(_settings, findsOneWidget);
    }, variant: desktops);

    testWidgets('the Mac\'s Settings… menu item toggles too', (tester) async {
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
      expect(_settings, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  testWidgets(
    'the other platform\'s chord opens nothing: ⌘, on Linux and Windows, '
    'Ctrl+, on a Mac',
    (tester) async {
      await _start(tester, _Shell());
      final mac = defaultTargetPlatform == TargetPlatform.macOS;
      final wrong = mac
          ? LogicalKeyboardKey.controlLeft
          : LogicalKeyboardKey.metaLeft;
      await tester.sendKeyDownEvent(wrong);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(wrong);
      await _settle(tester);
      expect(_settings, findsNothing);
    },
    variant: desktops,
  );
}
