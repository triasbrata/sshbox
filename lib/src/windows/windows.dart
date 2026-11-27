import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState;
import 'package:shared_preferences/shared_preferences.dart';

import '../session/session_manager.dart';

/// Where a window is: its top left, its size, and whether it is maximized.
/// What the runner reports as a window moves, and what is saved to open the
/// window there again.
@immutable
class WindowFrame {
  const WindowFrame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.maximized = false,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final bool maximized;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'maximized': maximized,
  };

  /// A frame from what was saved or what a runner sent, or null for
  /// anything that is not one: a file somebody edited, or an older build's.
  /// Every number within ±100000, and a size of at least 1.
  static WindowFrame? fromJson(Object? json) {
    if (json is! Map) return null;
    double? number(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite || value.abs() > 100000) return null;
      return value.toDouble();
    }

    final x = number('x');
    final y = number('y');
    final width = number('width');
    final height = number('height');
    if (x == null || y == null || width == null || height == null) return null;
    if (width < 1 || height < 1) return null;
    return WindowFrame(
      x: x,
      y: y,
      width: width,
      height: height,
      maximized: json['maximized'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowFrame &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, maximized);
}

/// What the runner tells the app about its windows.
sealed class WindowEvent {
  const WindowEvent(this.id);

  final int id;
}

/// A window's view is there to draw into. [viewId] is Flutter's id for it.
class WindowOpened extends WindowEvent {
  const WindowOpened(super.id, this.viewId);

  final int viewId;
}

/// The user focused this window: keys, links and shares go to it.
class WindowFocused extends WindowEvent {
  const WindowFocused(super.id);
}

/// The user asked to close this window, with its button or a key. Nothing
/// closes until the app answers with [WindowBackend.close].
class WindowCloseRequested extends WindowEvent {
  const WindowCloseRequested(super.id);
}

/// The window is gone, for whatever reason.
class WindowClosed extends WindowEvent {
  const WindowClosed(super.id);
}

/// The window moved or was resized.
class WindowMoved extends WindowEvent {
  const WindowMoved(super.id, this.frame);

  final WindowFrame frame;
}

/// The one small interface the app's windows go through: each platform's
/// runner is behind it, so a platform that cannot open a second window says
/// so and the app stays as it was, with one.
///
/// Window 0 is the window the app starts with, whose view is Flutter's
/// implicit view, 0. It is never destroyed while the app runs, the engine
/// assuming that view always exists: [close] on it hides it, and [open]
/// shows it again before it makes a new one.
abstract interface class WindowBackend {
  /// Whether this runner can open more than one window.
  Future<bool> get supported;

  Stream<WindowEvent> get events;

  /// Opens a window, at [frame] when given; its [WindowOpened] follows.
  /// Null when the runner could not.
  Future<int?> open({WindowFrame? frame});

  Future<void> close(int id);

  Future<void> activate(int id);
}

/// No second window: mobile, a runner without the native half, and tests.
class SingleWindow implements WindowBackend {
  const SingleWindow();

  @override
  Future<bool> get supported async => false;

  @override
  Stream<WindowEvent> get events => const Stream.empty();

  @override
  Future<int?> open({WindowFrame? frame}) async => null;

  @override
  Future<void> close(int id) async {}

  @override
  Future<void> activate(int id) async {}
}

/// The runner's half, over the `sshbox/windows` channel.
///
/// Calls to it: `supported`, `open` (an optional frame, answering the new
/// window's id), `close` and `activate` (a window id). Calls from it:
/// `opened` (id, viewId), `focused`, `closeRequested`, `closed` (an id) and
/// `moved` (id and a frame).
class ChannelWindowBackend implements WindowBackend {
  ChannelWindowBackend([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('sshbox/windows') {
    _channel.setMethodCallHandler(_heard);
  }

  final MethodChannel _channel;
  final _events = StreamController<WindowEvent>.broadcast();

  @override
  Stream<WindowEvent> get events => _events.stream;

  @override
  Future<bool> get supported async {
    try {
      // The engine's id goes with it: a runner that opens windows through
      // the engine's C API, as Windows' does, finds the engine by it.
      return await _channel.invokeMethod<bool>(
            'supported',
            PlatformDispatcher.instance.engineId,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<int?> open({WindowFrame? frame}) async {
    try {
      return await _channel.invokeMethod<int>('open', frame?.toJson());
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> close(int id) => _channel.invokeMethod<void>('close', id);

  @override
  Future<void> activate(int id) => _channel.invokeMethod<void>('activate', id);

  Future<Object?> _heard(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is int) {
      switch (call.method) {
        case 'focused':
          _events.add(WindowFocused(arguments));
        case 'closeRequested':
          _events.add(WindowCloseRequested(arguments));
        case 'closed':
          _events.add(WindowClosed(arguments));
      }
    } else if (arguments is Map) {
      final id = arguments['id'];
      if (id is! int) return null;
      switch (call.method) {
        case 'opened':
          final view = arguments['viewId'];
          if (view is int) _events.add(WindowOpened(id, view));
        case 'moved':
          final frame = WindowFrame.fromJson(arguments);
          if (frame != null) _events.add(WindowMoved(id, frame));
      }
    }
    return null;
  }
}

/// One window of the app: the tabs it holds, and the navigator they sit in.
///
/// What lives in the process once, the hosts, keys, settings, chat and the
/// notification listeners, is not here: a window is only its own tabs.
class AppWindow {
  AppWindow({
    required this.id,
    required this.key,
    required this.sessions,
    this.frame,
  });

  /// The runner's id for it, and null until it has one.
  int id;

  /// Flutter's id for its view, null until the runner says the view is up.
  int? viewId;

  /// Where its tabs are saved: see [SessionManager.savedKey].
  String key;

  final SessionManager sessions;

  /// Where it was last seen, saved to open it there again.
  WindowFrame? frame;

  /// What the window's own `MaterialApp` navigates with.
  final navigator = GlobalKey<NavigatorState>();
}

/// What is saved of the windows: `sshbox.windows.v1` holds, for each open
/// window in order, where its tabs are saved and where it was. The first
/// window keeps the key every build before several windows saved its tabs
/// under, so what an older build saved comes back as that window's, and
/// with no registry at all there is that one window.
class WindowRegistry {
  const WindowRegistry();

  static const prefsKey = 'sshbox.windows.v1';

  Future<List<({String key, WindowFrame? frame})>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(prefsKey) ?? '{}');
      final windows = saved is Map ? saved['windows'] : null;
      return [
        if (windows is List)
          for (final window in windows)
            if (window is Map && _keyOk(window['key']))
              (
                key: window['key'] as String,
                frame: WindowFrame.fromJson(window['frame']),
              ),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<({String key, WindowFrame? frame})> windows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        'windows': [
          for (final window in windows)
            {'key': window.key, 'frame': window.frame?.toJson()},
        ],
      }),
    );
  }

  /// Forgets a window's tabs.
  Future<void> forget(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// A saved key is one this registry made, so what it is given back can
  /// never name another setting.
  static bool _keyOk(Object? key) =>
      key is String && RegExp(r'^sshbox\.tabs\.v1(\.w[0-9]+)?$').hasMatch(key);

  /// A key no window of [taken] has.
  static String newKey(Iterable<String> taken) {
    var n = 1;
    while (taken.contains('sshbox.tabs.v1.w$n')) {
      n++;
    }
    return 'sshbox.tabs.v1.w$n';
  }
}

/// Every open window, and which one the user is in.
///
/// Opening, closing and focus go through a [WindowBackend]; what each window
/// holds is the app's, handed over by [make] and [restore]. With a backend
/// that does not [WindowBackend.supported] the app has its one window, as it
/// always had.
class WindowSet extends ChangeNotifier {
  WindowSet({
    required this.backend,
    required AppWindow first,
    required this.make,
    required this.restore,
    bool multi = false,
    this.registry = const WindowRegistry(),
  }) : _multi = multi {
    first
      ..id = 0
      ..viewId = 0;
    _windows[0] = first;
  }

  final WindowBackend backend;

  /// A window holding no tabs yet, with its own tab manager.
  final AppWindow Function(String key, WindowFrame? frame) make;

  /// Brings back the tabs a window had saved.
  final Future<void> Function(AppWindow window) restore;

  final WindowRegistry registry;

  /// Whether the runner can open more than one window, as the app was told
  /// when it began, and as [start] asks again.
  bool get multi => _multi;
  bool _multi;

  final Map<int, AppWindow> _windows = {};
  StreamSubscription<WindowEvent>? _events;
  int _focused = 0;
  bool _closing = false;

  /// The window's tabs, asked before it closes: a yes closes it, a no keeps
  /// it. Left unset, a window closes with no question.
  Future<bool> Function(AppWindow window)? mayClose;

  List<AppWindow> get windows => List.unmodifiable(_windows.values);

  /// The window the user last focused, the first one at first.
  AppWindow get focused => _windows[_focused] ?? _windows.values.first;

  /// Starts with the window the app opened with and, where the runner can,
  /// brings back the others that were open when the app last went away. The
  /// first window saved is the one in the runner's first window, so what
  /// stood in it stands in it again.
  Future<void> start() async {
    final first = _windows[0]!;
    _multi = await backend.supported;
    notifyListeners();
    if (!_multi) {
      await restore(first);
      return;
    }
    final saved = await registry.load();
    if (saved.isNotEmpty) {
      first
        ..key = saved.first.key
        ..frame = saved.first.frame;
      first.sessions.savedKey = saved.first.key;
    }
    _events = backend.events.listen(_heard);
    final restoring = restore(first);
    for (final other in saved.skip(1)) {
      final window = make(other.key, other.frame);
      final id = await backend.open(frame: other.frame);
      if (id == null) continue;
      _register(window, id);
      await restore(window);
    }
    await restoring;
  }

  /// Views the runner announced before its window was known here.
  final Map<int, int> _viewsEarly = {};

  void _register(AppWindow window, int id) {
    window.id = id;
    window.viewId ??= _viewsEarly.remove(id);
    _windows[id] = window;
    notifyListeners();
  }

  /// Opens an empty window, which is Cmd+N or Ctrl+N. Null where the runner
  /// cannot.
  Future<AppWindow?> openNew() async {
    if (!_multi) return null;
    final key = WindowRegistry.newKey([
      for (final window in _windows.values) window.key,
    ]);
    final window = make(key, null);
    final id = await backend.open();
    if (id == null) return null;
    // The first window, hidden after it was closed, is opened again before
    // a new one is made, and answers with its own id.
    _register(window, id);
    _focused = id;
    await _save();
    return window;
  }

  void _heard(WindowEvent event) {
    switch (event) {
      case WindowOpened(:final id, :final viewId):
        final window = _windows[id];
        if (window == null) {
          _viewsEarly[id] = viewId;
          return;
        }
        window.viewId = viewId;
        notifyListeners();
      case WindowFocused(:final id):
        if (_windows.containsKey(id)) {
          _focused = id;
          notifyListeners();
        }
      case WindowMoved(:final id, :final frame):
        final window = _windows[id];
        if (window == null || window.frame == frame) return;
        window.frame = frame;
        unawaited(_save());
      case WindowCloseRequested(:final id):
        final window = _windows[id];
        if (window != null) unawaited(closeWindow(window));
      case WindowClosed(:final id):
        _gone(id);
    }
  }

  /// Closes [window] if the user lets it, asking first when it holds tabs.
  /// The last window closing is the app quitting: its tabs stay saved, and
  /// come back at the next start.
  Future<void> closeWindow(AppWindow window) async {
    if (_closing || !_windows.containsKey(window.id)) return;
    _closing = true;
    try {
      // The last window closing is the app quitting, which asks nothing.
      if (_windows.length <= 1) {
        await backend.close(window.id);
        return;
      }
      final ask = mayClose;
      if (ask != null && !await ask(window)) return;
      _windows.remove(window.id);
      if (_focused == window.id) _focused = _windows.keys.first;
      notifyListeners();
      await window.sessions.retire();
      await registry.forget(window.key);
      await _save();
      await backend.close(window.id);
    } finally {
      _closing = false;
    }
  }

  /// A window that went without being asked: nothing is kept of it.
  void _gone(int id) {
    final window = _windows[id];
    if (window == null || _windows.length <= 1) return;
    _windows.remove(id);
    if (_focused == id) _focused = _windows.keys.first;
    notifyListeners();
    unawaited(window.sessions.retire());
    unawaited(registry.forget(window.key));
    unawaited(_save());
  }

  Future<void> _save() => registry.save([
    for (final window in _windows.values)
      (key: window.key, frame: window.frame),
  ]);

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }
}
