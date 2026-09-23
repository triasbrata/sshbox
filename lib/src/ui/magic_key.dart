import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'key_bar.dart';
import 'tui.dart';

/// One slot on the magic key's ring. [send] is resolved at emit time because
/// what a cursor key has to send depends on the mode the remote application
/// has put the terminal in.
typedef MagicKeyAction = ({String label, String Function(Terminal) send});

/// The ring, clockwise from north.
///
/// The arrows sit where the finger points, so the dpad needs no learning; the
/// diagonals hold the keys a shell wants most and a touch keyboard lacks.
final List<MagicKeyAction> magicKeys = [
  (label: '↑', send: (t) => cursorKey(t, 'A')),
  (label: 'ESC', send: (_) => '\x1b'),
  (label: '→', send: (t) => cursorKey(t, 'C')),
  (label: 'TAB', send: (_) => '\t'),
  (label: '↓', send: (t) => cursorKey(t, 'B')),
  (label: '^C', send: (_) => '\x03'),
  (label: '←', send: (t) => cursorKey(t, 'D')),
  (label: '^D', send: (_) => '\x04'),
];

/// Ring 2: the keys behind each of ring 1's, keyed by its label, reached by
/// sliding past it further the same way. Two at most: the first right behind
/// it, the second one step clockwise of that.
///
/// Each is a key that goes with its parent — further the same way, or the same
/// key for another job — so the hand is already nearly there. ESC ESC is
/// Claude Code's double Esc, and Shift+Tab cycles its modes.
final Map<String, List<MagicKeyAction>> magicSubKeys = {
  '↑': [(label: 'PGUP', send: (_) => '\x1b[5~'), _home],
  'ESC': [(label: 'ESC²', send: (_) => '\x1b\x1b')],
  '→': [_end, (label: 'W→', send: (_) => '\x1bf')],
  'TAB': [(label: '⇧TAB', send: (_) => '\x1b[Z')],
  '↓': [(label: 'PGDN', send: (_) => '\x1b[6~'), _end],
  '^C': [
    (label: '^Z', send: (_) => '\x1a'),
    (label: '^\\', send: (_) => '\x1c'),
  ],
  '←': [_home, (label: 'W←', send: (_) => '\x1bb')],
  '^D': [
    (label: '^L', send: (_) => '\x0c'),
    (label: '^R', send: (_) => '\x12'),
  ],
};

/// Home and End follow DECCKM the way the arrows do: xterm sends them as
/// `ESC O H` / `ESC O F` in application mode and `ESC [ H` / `ESC [ F` outside
/// it.
final MagicKeyAction _home = (label: 'HOME', send: (t) => cursorKey(t, 'H'));
final MagicKeyAction _end = (label: 'END', send: (t) => cursorKey(t, 'F'));

/// termul's magic key's geometry, which Jeansh's was the model for.
const freeArc = tuiMagicFreeArc;
const ringLayout = tuiMagicRingLayout;
const petalFor = tuiMagicPetalFor;

/// A floating Enter key that doubles as a radial key picker and can be parked
/// anywhere over the terminal: termul's [TuiMagicKey], sending what each of
/// its labels means to [terminal] and keeping its place across launches.
///
/// Tap it for Enter. Hold it and two rings open around it: [magicKeys] close
/// in, and further out [magicSubKeys]; slide toward a key and lift to send
/// it. Drag it to move it, throw it at a side to tuck it in half off the
/// screen, and a tap brings it back out. Left alone, it fades part way.
///
/// Give it the whole terminal area with [Positioned.fill]: it is a layer, and
/// only the button inside it takes touches.
class MagicKey extends StatefulWidget {
  const MagicKey({super.key, required this.terminal, required this.onEmit});

  final Terminal terminal;
  final void Function(String data) onEmit;

  @override
  State<MagicKey> createState() => _MagicKeyState();
}

class _MagicKeyState extends State<MagicKey> {
  static const _prefsX = 'sshbox.magickey.x';
  static const _prefsY = 'sshbox.magickey.y';
  static const _prefsDocked = 'sshbox.magickey.docked';

  /// Where it was left, once read: termul's key takes its place at the start.
  ({Offset spot, bool docked})? _saved;

  /// Every label's action, ring 1's and ring 2's, found by its label.
  late final Map<String, MagicKeyAction> _actions = {
    for (final action in [...magicKeys, ...magicSubKeys.values.expand((k) => k)])
      action.label: action,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_prefsX);
    final y = prefs.getDouble(_prefsY);
    if (!mounted) return;
    setState(
      () => _saved = (
        spot: x != null && y != null
            ? Offset(x.clamp(0, 1), y.clamp(0, 1))
            : const Offset(0.95, 0.92),
        docked: prefs.getBool(_prefsDocked) ?? false,
      ),
    );
  }

  Future<void> _remember(Offset spot, bool docked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsX, spot.dx);
    await prefs.setDouble(_prefsY, spot.dy);
    await prefs.setBool(_prefsDocked, docked);
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    if (saved == null) return const SizedBox.shrink();
    return TuiMagicKey(
      initialSpot: saved.spot,
      initialDocked: saved.docked,
      keys: [for (final key in magicKeys) (label: key.label)],
      subKeys: {
        for (final MapEntry(:key, :value) in magicSubKeys.entries)
          key: [for (final sub in value) (label: sub.label)],
      },
      onSpotChanged: (spot, docked) => unawaited(_remember(spot, docked)),
      onEmit: (label) => widget.onEmit(
        label == tuiMagicEnterLabel
            ? '\r'
            : _actions[label]?.send(widget.terminal) ?? '',
      ),
    );
  }
}
