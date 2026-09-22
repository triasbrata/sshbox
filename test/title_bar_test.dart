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

  testWidgets(
    'elsewhere the window has a title bar of its own: the strip '
    'leaves no room and never asks the window to move',
    (tester) async {
      final asked = _answerAsAMac(tester);
      await watchTitleBar();
      // Even with a Mac's measure somehow in hand.
      titleBar.value = (inset: 78, height: 28);
      await _pumpStrip(tester);

      expect(tester.getRect(find.byTooltip('Home')).left, lessThan(20));
      await _click(tester, const Offset(700, 20));
      expect(asked, isEmpty);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.linux,
    }),
  );

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
}
