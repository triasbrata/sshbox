import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

/// Holds the sticky modifier state shared by the key bar and the terminal's
/// outgoing data path.
class KeyBarController extends ChangeNotifier {
  bool _ctrl = false;
  bool _alt = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void _disarm() {
    if (!_ctrl && !_alt) return;
    _ctrl = false;
    _alt = false;
    notifyListeners();
  }

  /// Folds any armed modifier into text the soft keyboard just produced.
  ///
  /// This is the whole trick behind a usable phone terminal. A touch keyboard
  /// has no Ctrl key, so the bar arms one and we apply it to the next
  /// character on its way out — tap CTRL, then `c`, and the remote end sees
  /// a real `0x03`.
  String applyModifiers(String data) {
    if (data.isEmpty || (!_ctrl && !_alt)) return data;

    var result = data;

    if (_ctrl && data.length == 1) {
      final control = _toControlCode(data.codeUnitAt(0));
      if (control != null) result = String.fromCharCode(control);
    }

    // Alt is transmitted the way every terminal does it: ESC then the key.
    if (_alt) result = '\x1b$result';

    _disarm();
    return result;
  }

  /// Maps a printable character to the C0 code a hardware Ctrl chord sends.
  int? _toControlCode(int code) {
    if (code >= 0x61 && code <= 0x7a) return code - 0x60; // a-z
    if (code >= 0x40 && code <= 0x5f) return code - 0x40; // @ A-Z [ \ ] ^ _
    if (code == 0x20) return 0x00; // Ctrl-Space sends NUL
    if (code == 0x3f) return 0x7f; // Ctrl-? sends DEL
    return null;
  }
}

/// The accessory row that sits directly above the soft keyboard.
///
/// Without this the app cannot send Esc, Tab, Ctrl or arrows at all, which
/// rules out vim, less, tmux and job control — that is to say, most reasons
/// to open a terminal in the first place.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.controller,
    required this.terminal,
    required this.onEmit,
  });

  final KeyBarController controller;

  /// Read at tap time so cursor keys follow the application's current mode.
  final Terminal terminal;

  final void Function(String data) onEmit;

  /// Applications that request DECCKM (vim, less, many TUIs) expect the SS3
  /// form; sending CSI there produces stray characters instead of movement.
  String _cursor(String finalChar) =>
      terminal.cursorKeysMode ? '\x1bO$finalChar' : '\x1b[$finalChar';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  _KeyButton(label: 'ESC', onTap: () => onEmit('\x1b')),
                  _KeyButton(label: 'TAB', onTap: () => onEmit('\t')),
                  _KeyButton(
                    label: 'CTRL',
                    active: controller.ctrl,
                    onTap: controller.toggleCtrl,
                  ),
                  _KeyButton(
                    label: 'ALT',
                    active: controller.alt,
                    onTap: controller.toggleAlt,
                  ),
                  const _KeyDivider(),
                  _KeyButton(label: '←', onTap: () => onEmit(_cursor('D'))),
                  _KeyButton(label: '↓', onTap: () => onEmit(_cursor('B'))),
                  _KeyButton(label: '↑', onTap: () => onEmit(_cursor('A'))),
                  _KeyButton(label: '→', onTap: () => onEmit(_cursor('C'))),
                  const _KeyDivider(),
                  _KeyButton(label: '^C', onTap: () => onEmit('\x03')),
                  _KeyButton(label: '^D', onTap: () => onEmit('\x04')),
                  _KeyButton(label: '^Z', onTap: () => onEmit('\x1a')),
                  const _KeyDivider(),
                  _KeyButton(label: 'HOME', onTap: () => onEmit(_cursor('H'))),
                  _KeyButton(label: 'END', onTap: () => onEmit(_cursor('F'))),
                  _KeyButton(label: 'PGUP', onTap: () => onEmit('\x1b[5~')),
                  _KeyButton(label: 'PGDN', onTap: () => onEmit('\x1b[6~')),
                  const _KeyDivider(),
                  // Symbols the stock keyboard buries two layers deep.
                  for (final symbol in const ['-', '/', '|', '~', ':', '*'])
                    _KeyButton(label: symbol, onTap: () => onEmit(symbol)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Armed sticky modifiers stay lit so the user can see what the next
  /// keystroke will do.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground =
        active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      child: Material(
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyDivider extends StatelessWidget {
  const _KeyDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}
