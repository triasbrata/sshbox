import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/windows/windows.dart';

const _plain = HostProfile(
  id: 'plain',
  label: 'plain',
  host: 'plain.example',
  username: 'me',
);
const _other = HostProfile(
  id: 'other',
  label: 'other',
  host: 'other.example',
  username: 'me',
);

/// A runner that opens windows when [canOpen], numbering them from 1 as the
/// real ones do, and keeps what it was asked.
class _Runner implements WindowBackend {
  _Runner({this.canOpen = true});

  final bool canOpen;
  final opened = <WindowFrame?>[];
  final closed = <int>[];
  final activated = <int>[];
  final say = StreamController<WindowEvent>.broadcast();
  int _next = 1;

  @override
  Future<bool> get supported async => canOpen;

  /// 0 where the runner has an implicit view, as Linux's and Windows' do.
  int first = 0;

  @override
  Future<int> get firstView async => first;

  @override
  Stream<WindowEvent> get events => say.stream;

  @override
  Future<int?> open({WindowFrame? frame}) async {
    opened.add(frame);
    return _next++;
  }

  @override
  Future<void> close(int id) async => closed.add(id);

  @override
  Future<void> activate(int id) async => activated.add(id);

  final placed = <(int, WindowFrame)>[];

  @override
  Future<void> place(int id, WindowFrame frame) async =>
      placed.add((id, frame));
}

/// What a window of the app is made of in a test: a tab manager at [key].
AppWindow _make(String key, WindowFrame? frame) => AppWindow(
  id: -1,
  key: key,
  sessions: SessionManager(savedKey: key),
  frame: frame,
);

WindowSet _set(_Runner runner, {List<AppWindow>? restored}) => WindowSet(
  backend: runner,
  first: _make(SessionManager.defaultSavedKey, null),
  make: _make,
  restore: (window) async {
    restored?.add(window);
    await window.sessions.restoreTabs(hosts: [_plain, _other], databases: []);
  },
);

Map<String, Object?> _tabs(String hostId) => {
  'sessions': [
    {'hostId': hostId, 'tmux': null, 'files': [], 'web': []},
  ],
  'databases': [],
};

Future<String?> _pref(String key) async =>
    (await SharedPreferences.getInstance()).getString(key);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('WindowFrame', () {
    test('comes back from what it saved', () {
      const frame = WindowFrame(
        x: -20,
        y: 30.5,
        width: 900,
        height: 600,
        maximized: true,
      );
      expect(WindowFrame.fromJson(frame.toJson()), frame);
    });

    test('is equal to a frame of the same numbers, and to no other', () {
      const frame = WindowFrame(x: 1, y: 2, width: 300, height: 400);
      expect(frame, const WindowFrame(x: 1, y: 2, width: 300, height: 400));
      expect(
        frame.hashCode,
        const WindowFrame(x: 1, y: 2, width: 300, height: 400).hashCode,
      );
      expect(
        frame,
        isNot(const WindowFrame(x: 9, y: 2, width: 300, height: 400)),
      );
      expect(
        frame,
        isNot(
          const WindowFrame(
            x: 1,
            y: 2,
            width: 300,
            height: 400,
            maximized: true,
          ),
        ),
      );
      expect(frame, isNot('not a frame'));
    });

    test('is nothing for what is not a frame', () {
      expect(WindowFrame.fromJson(null), isNull);
      expect(WindowFrame.fromJson('x'), isNull);
      expect(WindowFrame.fromJson({'x': 1, 'y': 1, 'width': 9}), isNull);
      expect(
        WindowFrame.fromJson({'x': 1, 'y': 1, 'width': 0, 'height': 5}),
        isNull,
      );
      expect(
        WindowFrame.fromJson({'x': 1e9, 'y': 1, 'width': 5, 'height': 5}),
        isNull,
      );
      expect(
        WindowFrame.fromJson({
          'x': double.nan,
          'y': 1,
          'width': 5,
          'height': 5,
        }),
        isNull,
      );
    });
  });

  group('WindowRegistry', () {
    test('numbers a new key past the ones taken', () {
      expect(WindowRegistry.newKey(['sshbox.tabs.v1']), 'sshbox.tabs.v1.w1');
      expect(
        WindowRegistry.newKey(['sshbox.tabs.v1', 'sshbox.tabs.v1.w1']),
        'sshbox.tabs.v1.w2',
      );
    });

    test(
      'keeps only keys it made, so a saved list names no other setting',
      () async {
        SharedPreferences.setMockInitialValues({
          WindowRegistry.prefsKey: jsonEncode({
            'windows': [
              {'key': 'sshbox.tabs.v1'},
              {'key': 'sshbox.theme'},
              {'key': 'sshbox.tabs.v1.w3'},
              {'key': 7},
              'junk',
            ],
          }),
        });
        final saved = await const WindowRegistry().load();
        expect(
          [for (final w in saved) w.key],
          ['sshbox.tabs.v1', 'sshbox.tabs.v1.w3'],
        );
      },
    );

    test('reads nothing from a file that is not JSON', () async {
      SharedPreferences.setMockInitialValues({
        WindowRegistry.prefsKey: '{not json',
      });
      expect(await const WindowRegistry().load(), isEmpty);
    });
  });

  group('WindowSet', () {
    test(
      'with a runner that opens no second window there is the one',
      () async {
        final runner = _Runner(canOpen: false);
        final restored = <AppWindow>[];
        final set = _set(runner, restored: restored);
        await set.start();
        expect(set.multi, isFalse);
        expect(set.windows, hasLength(1));
        expect(restored, hasLength(1));
        expect(await set.openNew(), isNull);
        expect(runner.opened, isEmpty);
      },
    );

    test('the first window draws in the view the runner says', () async {
      final runner = _Runner()..first = 1;
      final set = _set(runner);
      expect(set.windows.single.viewId, 0);
      await set.start();
      expect(set.windows.single.viewId, 1);
    });

    test('brings back what an older build saved as the one window', () async {
      // The key every build before several windows saved its tabs under, and
      // no registry at all.
      SharedPreferences.setMockInitialValues({
        'sshbox.tabs.v1': jsonEncode(_tabs('plain')),
      });
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      expect(set.multi, isTrue);
      expect(set.windows, hasLength(1));
      expect(set.windows.single.key, 'sshbox.tabs.v1');
      expect(
        [for (final s in set.windows.single.sessions.sessions) s.host.id],
        ['plain'],
      );
      expect(runner.opened, isEmpty);
    });

    test(
      'brings every window back with its own tabs and its own place',
      () async {
        const place = WindowFrame(x: 10, y: 20, width: 800, height: 500);
        SharedPreferences.setMockInitialValues({
          'sshbox.tabs.v1': jsonEncode(_tabs('plain')),
          'sshbox.tabs.v1.w1': jsonEncode(_tabs('other')),
          WindowRegistry.prefsKey: jsonEncode({
            'windows': [
              {'key': 'sshbox.tabs.v1'},
              {'key': 'sshbox.tabs.v1.w1', 'frame': place.toJson()},
            ],
          }),
        });
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        expect(runner.opened, [place]);
        final tabs = {
          for (final w in set.windows)
            w.key: [for (final s in w.sessions.sessions) s.host.id],
        };
        expect(tabs, {
          'sshbox.tabs.v1': ['plain'],
          'sshbox.tabs.v1.w1': ['other'],
        });
        expect(set.windows[1].id, 1);
      },
    );

    test('the first window of the list is the runner\'s first', () async {
      // The window that held the first place was closed last time, and the
      // one that is left was saved first.
      SharedPreferences.setMockInitialValues({
        'sshbox.tabs.v1.w2': jsonEncode(_tabs('other')),
        WindowRegistry.prefsKey: jsonEncode({
          'windows': [
            {'key': 'sshbox.tabs.v1.w2'},
          ],
        }),
      });
      final set = _set(_Runner());
      await set.start();
      expect(set.windows.single.id, 0);
      expect(set.windows.single.key, 'sshbox.tabs.v1.w2');
      expect(set.windows.single.sessions.savedKey, 'sshbox.tabs.v1.w2');
      expect(
        [for (final s in set.windows.single.sessions.sessions) s.host.id],
        ['other'],
      );
    });

    test('a new window is empty, saved, and the one the user is in', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      set.windows.single.sessions.open(_plain);
      final window = await set.openNew();
      expect(window, isNotNull);
      expect(window!.key, 'sshbox.tabs.v1.w1');
      expect(window.sessions.sessions, isEmpty);
      expect(set.windows, hasLength(2));
      expect(set.focused, same(window));
      expect(runner.opened, [null]);
      final saved = jsonDecode((await _pref(WindowRegistry.prefsKey))!);
      expect(
        [for (final w in saved['windows']) w['key']],
        ['sshbox.tabs.v1', 'sshbox.tabs.v1.w1'],
      );
    });

    test('a window\'s tabs are saved under its own key and no other', () async {
      final set = _set(_Runner());
      await set.start();
      final second = (await set.openNew())!;
      await second.sessions.restoreTabs(hosts: [_plain], databases: []);
      second.sessions.open(_plain);
      await pumpEventQueue();
      expect(await _pref('sshbox.tabs.v1.w1'), contains('plain'));
      expect(await _pref('sshbox.tabs.v1'), isNot(contains('plain')));
    });

    test(
      'focus follows what the runner says, and ignores a window not here',
      () async {
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        final second = (await set.openNew())!;
        runner.say.add(const WindowFocused(0));
        await pumpEventQueue();
        expect(set.focused.id, 0);
        runner.say.add(WindowFocused(second.id));
        await pumpEventQueue();
        expect(set.focused, same(second));
        runner.say.add(const WindowFocused(99));
        await pumpEventQueue();
        expect(set.focused, same(second));
      },
    );

    test(
      'a view that is up is kept for its window, even announced first',
      () async {
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        runner.say.add(const WindowOpened(1, 5));
        await pumpEventQueue();
        final second = (await set.openNew())!;
        expect(second.viewId, 5);
        final third = (await set.openNew())!;
        expect(third.viewId, isNull);
        runner.say.add(WindowOpened(third.id, 6));
        await pumpEventQueue();
        expect(third.viewId, 6);
      },
    );

    test('a window moved is saved where it is, once', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final second = (await set.openNew())!;
      const place = WindowFrame(x: 1, y: 2, width: 300, height: 400);
      runner.say.add(WindowMoved(second.id, place));
      await pumpEventQueue();
      expect(second.frame, place);
      final saved = jsonDecode((await _pref(WindowRegistry.prefsKey))!);
      expect(WindowFrame.fromJson(saved['windows'][1]['frame']), place);
      // The same place again writes nothing new.
      await SharedPreferences.getInstance().then(
        (prefs) => prefs.remove(WindowRegistry.prefsKey),
      );
      runner.say.add(WindowMoved(second.id, place));
      await pumpEventQueue();
      expect(await _pref(WindowRegistry.prefsKey), isNull);
    });

    test('closing a window asks, and a no keeps it', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final second = (await set.openNew())!;
      var asked = 0;
      set.mayClose = (window) async {
        asked++;
        return false;
      };
      await set.closeWindow(second);
      expect(asked, 1);
      expect(set.windows, hasLength(2));
      expect(runner.closed, isEmpty);
    });

    test(
      'a yes closes it and forgets its tabs, without saving them again',
      () async {
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        final second = (await set.openNew())!;
        await second.sessions.restoreTabs(hosts: [_plain], databases: []);
        second.sessions.open(_plain);
        await pumpEventQueue();
        expect(await _pref('sshbox.tabs.v1.w1'), isNotNull);
        set.mayClose = (_) async => true;
        await set.closeWindow(second);
        await pumpEventQueue();
        expect(set.windows, hasLength(1));
        expect(second.sessions.sessions, isEmpty);
        expect(runner.closed, [second.id]);
        expect(await _pref('sshbox.tabs.v1.w1'), isNull);
        final saved = jsonDecode((await _pref(WindowRegistry.prefsKey))!);
        expect(
          [for (final w in saved['windows']) w['key']],
          ['sshbox.tabs.v1'],
        );
      },
    );

    test(
      'a window is taken down natively only once its view has left',
      () async {
        final runner = _Runner();
        final order = <String>[];
        final gate = Completer<void>();
        final set = WindowSet(
          backend: runner,
          first: _make(SessionManager.defaultSavedKey, null),
          make: _make,
          restore: (_) async {},
          settle: () async {
            order.add('settle');
            await gate.future;
          },
        );
        await set.start();
        final second = (await set.openNew())!;
        final closing = set.closeWindow(second);
        await pumpEventQueue();
        // Out of the set at once, so the tree drops its view; the runner is not
        // asked until that has been seen.
        expect(set.windows, hasLength(1));
        expect(runner.closed, isEmpty);
        gate.complete();
        await closing;
        expect(order, ['settle']);
        expect(runner.closed, [second.id]);
      },
    );

    test(
      'the last window closes with no question, and keeps its tabs',
      () async {
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        set.windows.single.sessions.open(_plain);
        await pumpEventQueue();
        var asked = false;
        set.mayClose = (_) async => asked = true;
        await set.closeWindow(set.windows.single);
        expect(asked, isFalse);
        expect(runner.closed, [0]);
        expect(set.windows, hasLength(1));
        expect(await _pref('sshbox.tabs.v1'), contains('plain'));
      },
    );

    test('the first window closed while others are open hands its place to '
        'another, whose own view is the one that goes', () async {
      SharedPreferences.setMockInitialValues({
        'sshbox.tabs.v1': jsonEncode(_tabs('plain')),
      });
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final first = set.windows.single;
      // A runner whose first window draws in a view other than 0.
      first.viewId = 7;
      final second = (await set.openNew())!;
      final third = (await set.openNew())!;
      await second.sessions.restoreTabs(hosts: [_other], databases: []);
      second.sessions.open(_other);
      await pumpEventQueue();
      const place = WindowFrame(x: 40, y: 50, width: 700, height: 500);
      runner.say.add(WindowMoved(second.id, place));
      await pumpEventQueue();
      final secondId = second.id;

      await set.closeWindow(first);
      await pumpEventQueue();

      // The window that stayed is the first one now, in the view and at the
      // place the runner's first window has, with the tabs it had.
      expect(set.windows, [second, third]);
      expect(second.id, 0);
      expect(second.viewId, 7);
      expect([for (final s in second.sessions.sessions) s.host.id], ['other']);
      expect(runner.placed, [(0, place)]);
      // The view that was its own is what goes, and the first window's
      // never does.
      expect(runner.closed, [secondId]);
      expect(set.focused, same(second));
      // What the user closed is gone, tabs and all, and what is saved
      // starts with the window the first one now is.
      expect(first.sessions.sessions, isEmpty);
      expect(await _pref('sshbox.tabs.v1'), isNull);
      final saved = jsonDecode((await _pref(WindowRegistry.prefsKey))!);
      expect(
        [for (final w in saved['windows']) w['key']],
        [second.key, third.key],
      );
    });

    test('a close asked for while another is finishing is answered', () async {
      final runner = _Runner();
      final gate = Completer<void>();
      final set = WindowSet(
        backend: runner,
        first: _make(SessionManager.defaultSavedKey, null),
        make: _make,
        restore: (_) async {},
        settle: () => gate.future,
      );
      await set.start();
      final first = set.windows.single;
      final second = (await set.openNew())!;
      final third = (await set.openNew())!;
      final closingFirst = set.closeWindow(first);
      await pumpEventQueue();
      // The second window is the first now, on screen where the user clicks
      // its close while the first one's closing is still being finished.
      expect(set.windows.first, same(second));
      final closingSecond = set.closeWindow(second);
      await pumpEventQueue();
      expect(set.windows, [third]);
      gate.complete();
      await closingFirst;
      await closingSecond;
      expect(set.windows.single.id, 0);
    });

    test('a window that never moved leaves the first where it was', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final first = set.windows.single;
      final second = (await set.openNew())!;
      await set.closeWindow(first);
      expect(set.windows.single, same(second));
      expect(second.id, 0);
      expect(runner.placed, isEmpty);
    });

    test('a close request from the runner closes that window', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final second = (await set.openNew())!;
      runner.say.add(WindowCloseRequested(second.id));
      await pumpEventQueue();
      expect(set.windows, hasLength(1));
      expect(runner.closed, [second.id]);
    });

    test('a window the runner closed on its own is let go', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      final second = (await set.openNew())!;
      runner.say.add(WindowClosed(second.id));
      await pumpEventQueue();
      expect(set.windows, hasLength(1));
      expect(await _pref('sshbox.tabs.v1.w1'), isNull);
      // Nothing was asked of the runner: it had closed it.
      expect(runner.closed, isEmpty);
    });

    test(
      'the last window going without a word leaves its tabs saved',
      () async {
        final runner = _Runner();
        final set = _set(runner);
        await set.start();
        set.windows.single.sessions.open(_plain);
        await pumpEventQueue();
        runner.say.add(const WindowClosed(0));
        await pumpEventQueue();
        expect(set.windows, hasLength(1));
        expect(await _pref('sshbox.tabs.v1'), contains('plain'));
      },
    );

    test('a request for a window that is not here is nothing', () async {
      final runner = _Runner();
      final set = _set(runner);
      await set.start();
      runner.say.add(const WindowCloseRequested(42));
      await pumpEventQueue();
      expect(runner.closed, isEmpty);
    });
  });

  group('the channel backend', () {
    const channel = MethodChannel('sshbox/windows');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'supported' => true,
              'open' => 3,
              _ => null,
            };
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    Future<void> tell(String method, Object? arguments) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );
    }

    test('asks the runner, and passes a frame on', () async {
      final backend = ChannelWindowBackend(channel);
      expect(await backend.supported, isTrue);
      const place = WindowFrame(x: 1, y: 2, width: 3, height: 4);
      expect(await backend.open(frame: place), 3);
      await backend.close(3);
      await backend.activate(3);
      expect(
        [for (final c in calls) c.method],
        ['supported', 'open', 'close', 'activate'],
      );
      expect(calls[1].arguments, place.toJson());
      expect(calls[2].arguments, 3);
    });

    test(
      'asks which view the first window draws in, and says 0 when not told',
      () async {
        final backend = ChannelWindowBackend(channel);
        expect(await backend.firstView, 0);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => 1);
        expect(await backend.firstView, 1);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'no');
            });
        expect(await backend.firstView, 0);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        expect(await backend.firstView, 0);
      },
    );

    test(
      'places a window, and leaves it where it is when the runner cannot',
      () async {
        final backend = ChannelWindowBackend(channel);
        const place = WindowFrame(x: 1, y: 2, width: 300, height: 400);
        await backend.place(0, place);
        expect(calls.single.method, 'place');
        expect(calls.single.arguments, {'id': 0, ...place.toJson()});
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'no');
            });
        await backend.place(0, place);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await backend.place(0, place);
      },
    );

    test('is single where the runner has no half of it', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final backend = ChannelWindowBackend(channel);
      expect(await backend.supported, isFalse);
    });

    test('is single where the runner refuses', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'no');
          });
      final backend = ChannelWindowBackend(channel);
      expect(await backend.supported, isFalse);
      expect(await backend.open(), isNull);
    });

    test('turns what the runner says into events', () async {
      final backend = ChannelWindowBackend(channel);
      final seen = <WindowEvent>[];
      backend.events.listen(seen.add);
      await tell('opened', {'id': 2, 'viewId': 7});
      await tell('focused', 2);
      await tell('closeRequested', 2);
      await tell('closed', 2);
      await tell('moved', {
        'id': 2,
        'x': 1,
        'y': 2,
        'width': 30,
        'height': 40,
        'maximized': true,
      });
      // Said wrongly, and so not heard.
      await tell('opened', {'id': 2});
      await tell('opened', {'viewId': 2});
      await tell('moved', {'id': 2, 'x': 1});
      await tell('focused', 'two');
      await tell('unknown', 1);
      await tell('unknown', {'id': 1});
      await pumpEventQueue();
      expect(seen.map((e) => e.runtimeType), [
        WindowOpened,
        WindowFocused,
        WindowCloseRequested,
        WindowClosed,
        WindowMoved,
      ]);
      expect((seen[0] as WindowOpened).viewId, 7);
      expect((seen[4] as WindowMoved).frame.maximized, isTrue);
    });
  });

  group('SingleWindow', () {
    test('opens nothing and says nothing', () async {
      const single = SingleWindow();
      expect(await single.supported, isFalse);
      expect(await single.firstView, 0);
      expect(await single.open(), isNull);
      await single.close(0);
      await single.activate(0);
      await single.place(0, const WindowFrame(x: 0, y: 0, width: 1, height: 1));
      expect(await single.events.isEmpty, isTrue);
    });
  });

  group('the app', () {
    Future<_Runner> start(WidgetTester tester, {bool canOpen = true}) async {
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
      final runner = _Runner(canOpen: canOpen);
      // The root is the views, as `runWidget` makes it, when the runner can.
      await tester.pumpWidget(
        SshboxApp(windows: runner, multiWindow: canOpen),
        wrapWithView: !canOpen,
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return runner;
    }

    Future<void> chord(
      WidgetTester tester,
      List<LogicalKeyboardKey> modifiers,
    ) async {
      for (final key in modifiers) {
        await tester.sendKeyDownEvent(key);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      for (final key in modifiers.reversed) {
        await tester.sendKeyUpEvent(key);
      }
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('⌘N opens a window on a Mac, and nothing else does', (
      tester,
    ) async {
      final runner = await start(tester);
      await chord(tester, [LogicalKeyboardKey.controlLeft]);
      await chord(tester, [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.shiftLeft,
      ]);
      expect(runner.opened, isEmpty);
      await chord(tester, [LogicalKeyboardKey.metaLeft]);
      expect(runner.opened, hasLength(1));
      // The window is the one the first still draws beside.
      expect(find.byType(MaterialApp), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Ctrl+Shift+N opens a window on Linux, and Ctrl+N never does', (
      tester,
    ) async {
      final runner = await start(tester);
      await chord(tester, [LogicalKeyboardKey.controlLeft]);
      await chord(tester, [LogicalKeyboardKey.metaLeft]);
      expect(runner.opened, isEmpty);
      await chord(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ]);
      expect(runner.opened, hasLength(1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets(
      'where the runner opens no second window the key is left alone',
      (tester) async {
        final runner = await start(tester, canOpen: false);
        await chord(tester, [LogicalKeyboardKey.metaLeft]);
        expect(runner.opened, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
}

/// Notifications as a desktop's plugin gives them: nothing to say.
class _BareNotifications extends FlutterLocalNotificationsPlatform {}
