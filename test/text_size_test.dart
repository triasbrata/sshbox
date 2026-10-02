import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

import 'tui_finders.dart';

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

  final sent = <String>[];

  @override
  void send(String data) => sent.add(data);

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

  testWidgets('the UI text size slider reads its value as its readout says '
      'it, 100% rather than 100.00, under the name the e2e flow finds', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    expect(find.bySemanticsLabel('Set the UI text size'), findsOneWidget);
    final slider = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.slider == true,
    );
    expect(tester.getSemantics(slider.first).value, '100%');
    semantics.dispose();
  });

  group('a saved size that cannot be used gives way to the default, and '
      'never stops the app starting', () {
    for (final (name, saved) in [
      ('NaN', double.nan),
      ('another type', 'large'),
      ('out of range', 9.0),
    ]) {
      test('the UI size, $name', () async {
        SharedPreferences.setMockInitialValues({'sshbox.ui.textScale': saved});
        uiTextSize.value = 1.4;
        await uiTextSize.load();
        expect(uiTextSize.value, 1);
      });
    }
    for (final (name, saved) in [
      ('NaN', double.nan),
      ('another type', 'large'),
    ]) {
      test('the content size, $name', () async {
        SharedPreferences.setMockInitialValues({
          'sshbox.terminal.fontSize': saved,
          'sshbox.terminal.fontFamily': 42,
        });
        await terminalSettings.load();
        expect(terminalSettings.value, TerminalSettings.defaultStyle);
      });
    }
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

  group('more ways to change the UI text size', () {
    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      LogicalKeyboardKey? hold,
      bool shift = false,
    }) async {
      if (hold != null) await tester.sendKeyDownEvent(hold);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (hold != null) await tester.sendKeyUpEvent(hold);
      await tester.pump();
    }

    const ctrl = LogicalKeyboardKey.controlLeft;
    const meta = LogicalKeyboardKey.metaLeft;
    const minus = LogicalKeyboardKey.minus;

    for (final (platform, held, wrong) in [
      (TargetPlatform.macOS, meta, ctrl),
      (TargetPlatform.linux, ctrl, meta),
      (TargetPlatform.windows, ctrl, meta),
      (TargetPlatform.android, ctrl, meta),
    ]) {
      testWidgets('${platform.name}: the zoom chord steps the one setting, '
          'says the size, and the other modifier does nothing', (tester) async {
        await _start(tester, _Box(), const Size(800, 1280));
        await chord(tester, LogicalKeyboardKey.equal, hold: held);
        expect(uiTextSize.value, 1.1);
        expect(find.text('UI text size 110%'), findsOneWidget);
        await chord(tester, LogicalKeyboardKey.equal, hold: held, shift: true);
        expect(uiTextSize.value, 1.2, reason: '+ needs Shift on most layouts');
        await chord(tester, minus, hold: held);
        await chord(tester, minus, hold: held);
        expect(uiTextSize.value, 1.0);
        await chord(tester, LogicalKeyboardKey.equal, hold: held);
        await chord(tester, LogicalKeyboardKey.digit0, hold: held);
        expect(uiTextSize.value, 1);
        expect(
          (await SharedPreferences.getInstance()).getDouble(
            'sshbox.ui.textScale',
          ),
          1,
        );

        await chord(tester, LogicalKeyboardKey.equal, hold: wrong);
        await chord(tester, LogicalKeyboardKey.equal);
        expect(uiTextSize.value, 1, reason: "not this platform's chord");
        await tester.pump(const Duration(seconds: 2));
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets("the bounds are the slider's", (tester) async {
      await _start(tester, _Box(), const Size(800, 1280));
      for (var i = 0; i < 12; i++) {
        await chord(tester, LogicalKeyboardKey.equal, hold: ctrl);
      }
      expect(uiTextSize.value, UiTextSize.max);
      for (var i = 0; i < 12; i++) {
        await chord(tester, minus, hold: ctrl);
      }
      expect(uiTextSize.value, UiTextSize.min);
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a terminal still gets every key the zoom leaves it, '
        'Ctrl+Shift+- as ^_ included, and loses only Ctrl+-', (tester) async {
      final box = _Box();
      await _start(tester, box, const Size(800, 1280));
      await _open(tester);
      box.sent.clear();

      await chord(tester, minus, hold: ctrl, shift: true);
      await chord(tester, LogicalKeyboardKey.slash, hold: ctrl);
      await chord(tester, LogicalKeyboardKey.keyC, hold: ctrl);
      await chord(
        tester,
        LogicalKeyboardKey.equal,
        hold: LogicalKeyboardKey.altLeft,
      );
      expect(uiTextSize.value, 1);
      expect(box.sent, contains('\x1f'), reason: '^_ still reachable');
      expect(box.sent, contains('\x03'));
      final before = box.sent.length;

      await chord(tester, minus, hold: ctrl);
      expect(uiTextSize.value, 0.9);
      expect(box.sent.length, before, reason: "Ctrl+- is the zoom's");
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    Future<void> wheel(WidgetTester tester, Offset at, double dy) async {
      await tester.sendKeyDownEvent(ctrl);
      await tester.sendEventToBinding(pointer.hover(at));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.sendKeyUpEvent(ctrl);
      await tester.pump();
    }

    testWidgets('Ctrl with the wheel over the UI zooms, wheel up bigger; '
        'inside a terminal it is left to the program', (tester) async {
      await _start(tester, _Box(), const Size(800, 1280));
      await wheel(tester, const Offset(400, 600), -100);
      expect(uiTextSize.value, 1.1);
      await wheel(tester, const Offset(400, 600), 100);
      await wheel(tester, const Offset(400, 600), 100);
      expect(uiTextSize.value, 0.9);

      await _open(tester);
      await wheel(tester, tester.getCenter(find.byType(TerminalView)), -100);
      expect(uiTextSize.value, 0.9, reason: "the terminal's wheel");

      // And without Ctrl, nothing zooms anywhere.
      await tester.sendEventToBinding(pointer.hover(const Offset(400, 20)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      expect(uiTextSize.value, 0.9);
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("the desktop menu's View items arrive over sshbox/menu", (
      tester,
    ) async {
      await _start(tester, _Box(), const Size(800, 1280));
      Future<void> click(String method) =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'sshbox/menu',
            const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
            (_) {},
          );
      await click('zoomIn');
      await click('zoomIn');
      expect(uiTextSize.value, 1.2);
      await click('zoomOut');
      expect(uiTextSize.value, 1.1);
      await click('zoomReset');
      expect(uiTextSize.value, 1);
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets("Windows and Linux: the window buttons' menu has the zoom "
        'items', (tester) async {
      await _start(tester, _Box(), const Size(800, 1280));
      await tester.tap(find.bySemanticsLabel('Help'));
      await _settle(tester);
      await tester.tap(find.text('Zoom in'));
      await _settle(tester);
      expect(uiTextSize.value, 1.1);
      await tester.tap(find.bySemanticsLabel('Help'));
      await _settle(tester);
      await tester.tap(find.text('Actual size'));
      await _settle(tester);
      expect(uiTextSize.value, 1);
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("Home's Text size control, for touch, steps the same "
        'setting', (tester) async {
      await _start(tester, _Box(), const Size(800, 1280));
      Finder inDialog(String text) => find.descendant(
        of: find.byType(TuiDialog),
        matching: find.text(text),
      );
      await tester.tap(find.byTooltip('Text size'));
      await _settle(tester);
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(inDialog('+'));
      await _settle(tester);
      expect(uiTextSize.value, 1.1);
      expect(find.text('110%'), findsOneWidget);
      await tester.tap(inDialog('−'));
      await tester.tap(inDialog('−'));
      await _settle(tester);
      expect(uiTextSize.value, 0.9);
      await tester.tap(findTuiButton('Reset'));
      await _settle(tester);
      expect(uiTextSize.value, 1);
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'sshbox.ui.textScale',
        ),
        1,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
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
