import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart' show TerminalStyle;

import '../telemetry/app_log.dart';
import 'settings_page.dart' show TerminalSettings, terminalSettings;
import 'toast.dart';

/// Two text sizes, as Settings sets them: one for the app's own chrome — the
/// tab strip, the key bar, menus, dialogs, toasts, Settings and Home — and one
/// for what is read inside a tab.
///
/// The UI size is a factor on the system's own text scaling, applied once at
/// the app's root ([UiTextScaler]), so every chrome text follows it, termul's
/// components untouched. The content size is the terminal's font size: what
/// is read in a tab is wrapped in [ContentText], which takes the UI factor
/// back out and puts the content's in.
class UiTextSize extends ValueNotifier<double> {
  UiTextSize() : super(1);

  static const _key = 'sshbox.ui.textScale';
  static const min = 0.8;
  static const max = 1.6;

  /// Reads the saved choice. Nothing saved, or out of range, is 100%.
  ///
  /// Read before the app runs, so nothing saved may stop it starting: a
  /// value of another type, or NaN, is 100% too.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    double? saved;
    try {
      saved = prefs.getDouble(_key);
    } catch (_) {}
    value = saved != null && saved >= min && saved <= max ? saved : 1;
  }

  /// Applies at once, and is saved for the next start.
  Future<void> choose(double scale) async {
    value = scale.clamp(min, max).toDouble();
    appLog.add('setting ui text size $value');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, value);
  }

  /// One step of Settings' slider, 10%, up or down; 0 is back to 100%.
  Future<void> zoom(int direction) =>
      choose(direction == 0 ? 1 : ((value * 10).round() + direction.sign) / 10);
}

/// The app's one; `main` reads the saved choice into it.
final uiTextSize = UiTextSize();

/// [base], the system's own scaling, times [factor]. The factor goes in
/// before the system's, so Android's non-linear scaling still treats a large
/// size as large.
class UiTextScaler extends TextScaler {
  const UiTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize * factor);

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is UiTextScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

/// The system's own scaling under [context], with the UI size taken out.
TextScaler systemTextScaler(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return scaler is UiTextScaler ? scaler.base : scaler;
}

/// What is read inside a tab, at the content size rather than the UI's.
///
/// [scale] grows the text by the content size against the terminal's default
/// of 13 — chat, the Markdown preview, the editor, diffs and the database
/// grid. A terminal sets false: its font size already is the content size, so
/// it takes only the system's scaling, and the UI size can never change its
/// cells, its columns and rows, or send the host a window-change.
class ContentText extends StatelessWidget {
  const ContentText({super.key, this.scale = true, required this.child});

  final bool scale;
  final Widget child;

  static final _default = TerminalSettings.defaultStyle.fontSize;

  @override
  Widget build(BuildContext context) {
    final system = systemTextScaler(context);
    if (!scale) return _with(context, system);
    return ValueListenableBuilder<TerminalStyle>(
      valueListenable: terminalSettings,
      builder: (context, style, _) {
        final factor = style.fontSize / _default;
        return _with(
          context,
          factor == 1 ? system : UiTextScaler(system, factor),
        );
      },
    );
  }

  Widget _with(BuildContext context, TextScaler scaler) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: scaler),
    child: child,
  );
}

/// [UiTextSize.zoom], and a toast saying the size it came to. [context] may
/// be null before the app is up: the size still changes.
void zoomUiText(BuildContext? context, int direction) {
  unawaited(uiTextSize.zoom(direction));
  if (context != null && context.mounted) {
    showToast(context, 'UI text size ${(uiTextSize.value * 100).round()}%');
  }
}

/// ⌘= (⌘+), ⌘− and ⌘0 on a Mac, Ctrl+= (Ctrl++), Ctrl+− and Ctrl+0 elsewhere,
/// as a browser and desktop terminals zoom.
///
/// Taken by an early key handler, before any widget, so a focused terminal
/// never sees them. That costs one thing: Ctrl+− is ^_, readline's and
/// emacs's undo. As GNOME Terminal and Windows Terminal do, it is the
/// zoom's, and Ctrl+Shift+− is left alone, which sends ^_ as it always did
/// (the key bar's CTRL with / does too). A Mac loses nothing: ⌘ reaches no
/// program there, and Ctrl keeps every use. Shift is read only for +, which
/// needs it on most layouts; Alt and the other modifier key take the chord
/// out of it.
class UiZoomKeys {
  UiZoomKeys(this.onZoom);

  /// Called with 1, -1 or 0 (back to 100%).
  final void Function(int direction) onZoom;

  final _down = <LogicalKeyboardKey>{};

  KeyEventResult handle(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      return _down.remove(key)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final direction = _direction(key);
    if (direction == null) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final chord = mac ? keys.isMetaPressed : keys.isControlPressed;
    final other = mac ? keys.isControlPressed : keys.isMetaPressed;
    final plus = direction > 0;
    if (!chord || other || keys.isAltPressed) return KeyEventResult.ignored;
    if (keys.isShiftPressed && !plus) return KeyEventResult.ignored;
    _down.add(key);
    onZoom(direction);
    return KeyEventResult.handled;
  }

  static int? _direction(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      return 1;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      return -1;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      return 0;
    }
    return null;
  }
}

/// Ctrl or ⌘ with the mouse wheel, over the app's own UI, zooms the UI text.
///
/// Wrap the app's root in [UiZoomWheel]; wrap a terminal's pointer handling
/// in [UiZoomWheel.keep], which takes the wheel out of the zoom: over a
/// terminal it belongs to the program, as before.
class UiZoomWheel extends StatefulWidget {
  const UiZoomWheel({super.key, required this.onZoom, required this.child});

  final void Function(int direction) onZoom;
  final Widget child;

  static PointerEvent? _kept;

  /// For a [Listener.onPointerSignal] inside a terminal: the event goes
  /// innermost first, so this is seen before the root's.
  static void keep(PointerSignalEvent event) => _kept = event.original ?? event;

  @override
  State<UiZoomWheel> createState() => _UiZoomWheelState();
}

class _UiZoomWheelState extends State<UiZoomWheel> {
  /// A notch is one step; a trackpad's many small deltas add up to one.
  static const _perStep = 40.0;
  double _carried = 0;

  void _signal(PointerSignalEvent event) {
    // Each listener is handed the event in its own coordinates, a copy
    // whose original is the one event.
    final whole = event.original ?? event;
    if (event is! PointerScrollEvent || identical(whole, UiZoomWheel._kept)) {
      return;
    }
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    if (_carried.sign != dy.sign) _carried = 0;
    _carried += dy;
    if (_carried.abs() < _perStep) return;
    // Wheel up, away from the user, is bigger.
    widget.onZoom(_carried < 0 ? 1 : -1);
    _carried = 0;
  }

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerSignal: _signal, child: widget.child);
}

/// Under the app's root, so a list, the file tree or the editor does not
/// scroll as Ctrl or ⌘ with the wheel zooms. A scrollable claims a wheel turn
/// before the zoom's root Listener can, but reads it along the other axis
/// when one of [pointerAxisModifiers] is held, as Shift does, and a vertical
/// list finds nothing there to claim. A terminal opts out.
class ZoomScrollBehavior extends MaterialScrollBehavior {
  const ZoomScrollBehavior();

  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers => {
    ...super.pointerAxisModifiers,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };
}
