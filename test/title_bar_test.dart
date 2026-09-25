import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/title_bar.dart';

/// Never asked for anything: the strip reads only a session's name and
/// status, and nothing here connects.
class _Unused implements SessionTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

const _window = MethodChannel('sshbox/window');

/// Answers the window's channel as a Mac's window does, its buttons ending
/// 78 from its left edge under a title bar 28 tall, and keeps what it was
/// asked.
List<String> _answerAsAMac(WidgetTester tester) {
  final asked = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_window, (call) async {
    asked.add(call.method);
    return call.method == 'titleBar' ? {'inset': 78.0, 'height': 28.0} : null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_window, null);
    titleBar.value = (inset: 0, height: 0);
  });
  return asked;
}

TabRef _shell(String id, String label) {
  final session = LiveSession(
    host: HostProfile(id: id, label: label, host: '10.0.2.2', username: 'me'),
    transport: (_, _) => _Unused(),
  );
  addTearDown(session.dispose);
  return (session: session, kind: TabKind.terminal, path: null, web: null);
}

/// Two tabs on the default 800-wide surface, which leaves the strip empty
/// from about 400 on, after the new-tab button.
Future<void> _pumpStrip(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TabStrip(
            tabs: [_shell('host-1', 'box'), _shell('host-2', 'pi')],
            activeIndex: 1,
            onSelect: (_, {kind = TabKind.terminal, path, web}) {},
            onClose: (_) {},
            onReconnect: (_) {},
            onDuplicate: (_) {},
          ),
        ],
      ),
    ),
  ),
);

/// A click of the mouse's main button at [at].
Future<void> _click(WidgetTester tester, Offset at) async {
  final mouse = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await mouse.up();
  await tester.pump();
}

int _drags(List<String> asked) => asked.where((m) => m == 'drag').length;

void main() {
  testWidgets('on a Mac the strip leaves the window buttons their room, and '
      'a press on its empty space moves the window', (tester) async {
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    await _pumpStrip(tester);

    expect(
      tester.getRect(find.byTooltip('Home')).left,
      greaterThanOrEqualTo(78),
    );

    // After the last tab and the new-tab button, and beside the buttons.
    await _click(tester, const Offset(700, 20));
    await _click(tester, const Offset(40, 20));
    expect(_drags(asked), 2);

    // A tab, Home and + are theirs, as a tab in Chrome's title bar is.
    await _click(tester, tester.getCenter(find.text('box')));
    await _click(tester, tester.getCenter(find.byTooltip('Home')));
    await _click(tester, tester.getCenter(find.byTooltip('New tab')));
    expect(_drags(asked), 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('on a phone there is no title bar at all: the strip '
      'leaves no room and never asks the window to move', (tester) async {
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    // Even with a Mac's measure somehow in hand.
    titleBar.value = (inset: 78, height: 28);
    await _pumpStrip(tester);

    expect(tester.getRect(find.byTooltip('Home')).left, lessThan(20));
    await _click(tester, const Offset(700, 20));
    expect(asked, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('on a Mac the tabs are drawn up into the title bar, and a page '
      'over them keeps clear of it and moves the window from it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    final navigator = GlobalKey<NavigatorState>();
    final sessions = SessionManager();
    addTearDown(sessions.closeAll);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => TitleBarSpace(
          covered: () => navigator.currentState?.canPop() ?? false,
          child: child!,
        ),
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: sessions,
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pump();

    // The strip at the very top, beside the window's buttons, and the page
    // under it with nothing more to keep clear of.
    expect(tester.getRect(find.byType(TabStrip)).top, 0);
    final home = tester.element(find.byType(HostsPage));
    expect(MediaQuery.paddingOf(home).top, 0);

    // Over the tabs, a press in the band is Home's, not the window's.
    await _click(tester, tester.getCenter(find.byTooltip('Home')));
    expect(_drags(asked), 0);

    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(appBar: AppBar(title: const Text('Settings'))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      tester.getRect(find.byType(BackButton)).top,
      greaterThanOrEqualTo(28),
    );
    await _click(tester, const Offset(400, 10));
    expect(_drags(asked), 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  final drawnButtons = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.linux,
  });

  testWidgets('on Windows and Linux the app draws the window buttons at the '
      "strip's right, each asking the window", (tester) async {
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    await _pumpApp(tester);

    final close = tester.getRect(find.bySemanticsLabel('Close'));
    expect(close.topRight, const Offset(800, 0));
    // The tabs keep clear of them.
    expect(
      tester.getRect(find.byTooltip('New tab')).right,
      lessThanOrEqualTo(800 - WindowButtons.width),
    );

    for (final label in ['Minimize', 'Maximize', 'Close']) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    expect(_windowCalls(asked), ['minimize', 'maximize', 'close']);

    // The runner says the window is maximized: the button restores it.
    await _tellWindow(tester, 'maximized', true);
    expect(find.bySemanticsLabel('Restore'), findsOneWidget);
    expect(find.bySemanticsLabel('Maximize'), findsNothing);
    await _tellWindow(tester, 'maximized', false);
    expect(find.bySemanticsLabel('Maximize'), findsOneWidget);
  }, variant: drawnButtons);

  testWidgets("a double-click on the strip's empty space maximizes or "
      'restores, where a click moves the window', (tester) async {
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    await _pumpApp(tester);

    await _click(tester, const Offset(450, 20));
    expect(_windowCalls(asked), ['drag']);
    await _click(tester, const Offset(451, 21));
    expect(_windowCalls(asked), ['drag', 'maximize']);
    // A third is a click of its own again.
    await _click(tester, const Offset(451, 21));
    expect(_windowCalls(asked), ['drag', 'maximize', 'drag']);
  }, variant: drawnButtons);

  testWidgets('a page over the tabs keeps the window buttons, and its band '
      'moves the window', (tester) async {
    final asked = _answerAsAMac(tester);
    await watchTitleBar();
    final navigator = await _pumpApp(tester);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(appBar: AppBar(title: const Text('Settings'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(BackButton)).top,
      greaterThanOrEqualTo(windowButtonsHeight),
    );
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    await _click(tester, const Offset(300, 10));
    expect(_windowCalls(asked), ['drag']);
  }, variant: drawnButtons);

  testWidgets(
    'a Mac and a phone draw no window buttons',
    (tester) async {
      _answerAsAMac(tester);
      await watchTitleBar();
      await _pumpApp(tester);
      expect(find.bySemanticsLabel('Close'), findsNothing);
      expect(find.bySemanticsLabel('Help'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
    }),
  );

  testWidgets('on Windows the maximize button tells the window where it is, '
      'for the snap layouts, and lights while the window says the pointer is '
      'over it', (tester) async {
    final asked = _answerAsAMac(tester);
    final sent = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_window, (
      call,
    ) async {
      asked.add(call.method);
      if (call.method == 'maximizeButton') sent.add(call.arguments);
      return null;
    });
    await watchTitleBar();
    await _pumpApp(tester);
    await tester.pump();

    final button = tester.getRect(find.bySemanticsLabel('Maximize'));
    final ratio = tester.view.devicePixelRatio;
    expect(sent.last, [
      button.left * ratio,
      button.top * ratio,
      button.right * ratio,
      button.bottom * ratio,
    ]);

    Color? fill() => tester
        .widget<Container>(
          find.descendant(
            of: find.bySemanticsLabel('Maximize'),
            matching: find.byType(Container),
          ),
        )
        .color;
    final idle = fill();
    await _tellWindow(tester, 'maximizeHover', true);
    expect(fill(), isNot(idle));
    await _tellWindow(tester, 'maximizeHover', false);
    expect(fill(), idle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

/// The window's channel asked for what moves or sizes the window, in order.
List<String> _windowCalls(List<String> asked) => [
  for (final method in asked)
    if (const {'drag', 'minimize', 'maximize', 'close'}.contains(method))
      method,
];

/// The runner telling the app [method] on the window's channel.
Future<void> _tellWindow(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'sshbox/window',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
  await tester.pump();
}

/// The tab shell under the app's own [TitleBarSpace], and its navigator.
Future<GlobalKey<NavigatorState>> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final navigator = GlobalKey<NavigatorState>();
  final sessions = SessionManager();
  addTearDown(sessions.closeAll);
  addTearDown(() => windowMaximized.value = false);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      builder: (context, child) => TitleBarSpace(
        navigator: navigator,
        covered: () => navigator.currentState?.canPop() ?? false,
        child: child!,
      ),
      home: TabsShell(
        repository: HostRepository(_NoSecrets()),
        secrets: _NoSecrets(),
        sessions: sessions,
        onOpenHost: (_) async {},
      ),
    ),
  );
  await tester.pump();
  return navigator;
}
