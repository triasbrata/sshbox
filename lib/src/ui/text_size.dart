import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart' show TerminalStyle;

import 'settings_page.dart' show TerminalSettings, terminalSettings;

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, value);
  }
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
