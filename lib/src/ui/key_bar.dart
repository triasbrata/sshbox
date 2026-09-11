import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart' show CodeLineEditingController;
import 'package:xterm2/xterm.dart';

/// Applications that request DECCKM (vim, less, many TUIs) expect the SS3
/// form; sending CSI there produces stray characters instead of movement.
String cursorKey(Terminal terminal, String finalChar) =>
    terminal.cursorKeysMode ? '\x1bO$finalChar' : '\x1b[$finalChar';

/// How far a drag must travel before it counts as a direction rather than a
/// wobble during a tap.
const _swipeDeadzone = 20.0;

/// The cursor key a drag of [offset] from where the finger landed stands for,
/// or null while it is still inside the deadzone.
String? swipeArrow(Offset offset) {
  if (offset.distance < _swipeDeadzone) return null;
  if (offset.dx.abs() > offset.dy.abs()) return offset.dx > 0 ? 'C' : 'D';
  return offset.dy > 0 ? 'B' : 'A';
}

/// Reach this far and holding still starts repeating; short of it the drag is
/// a single press however long you hold it, which is what you want when you
/// only meant to step one line.
const _swipeRepeatFrom = 60.0;

/// Reach this far and the repeat is as fast as it gets.
const _swipeFullSpeedFrom = 200.0;

/// Milliseconds between repeats while a drag of [distance] is held, or null
/// when the drag is still short enough to mean one press and no more.
///
/// The far end is deliberately unhurried: a held finger that runs away at
/// keyboard speed overshoots the line you were aiming for, and on a terminal
/// an overshoot costs you a trip back.
int? swipeRepeatMs(double distance) {
  if (distance < _swipeRepeatFrom) return null;

  final reach = ((distance - _swipeRepeatFrom) /
          (_swipeFullSpeedFrom - _swipeRepeatFrom))
      .clamp(0.0, 1.0);
  return (2000 - reach * 1700).round();
}

/// How many chevrons the readout shows for a drag of [distance]: one for the
/// nudge that will not repeat, then one more for each step up in speed.
int swipeSpeedLevel(double distance) {
  final interval = swipeRepeatMs(distance);
  if (interval == null) return 1;
  return interval > 1000 ? 2 : 3;
}

/// The idle arms of the readout, and the chevrons the live one is drawn with.
const _swipeArmIcons = <String, IconData>{
  'A': Icons.arrow_upward,
  'B': Icons.arrow_downward,
  'C': Icons.arrow_forward,
  'D': Icons.arrow_back,
};

const _swipeChevronIcons = <String, IconData>{
  'A': Icons.keyboard_arrow_up,
  'B': Icons.keyboard_arrow_down,
  'C': Icons.keyboard_arrow_right,
  'D': Icons.keyboard_arrow_left,
};

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

/// Turns a drag into cursor-key steps.
///
/// Holding the space bar on iOS and Android turns the on-screen keyboard into
/// a trackpad for moving the caret. The OS runs that gesture against its own
/// text field and reports it as a floating cursor, which never reaches us —
/// so the key bar grows a space key that behaves the same way.
class CursorPad {
  CursorPad({this.stepX = 20, this.stepY = 28});

  /// Distance to travel per cursor key. Vertical is deliberately coarser: in a
  /// shell an accidental up is a recalled command, not just a moved caret.
  final double stepX;
  final double stepY;

  int _x = 0;
  int _y = 0;

  void reset() {
    _x = 0;
    _y = 0;
  }

  /// [offset] is measured from where the drag began, so what comes back is
  /// whatever movement the distance travelled so far still owes — nothing if
  /// the finger has not crossed the next threshold, and the reverse key if it
  /// has come back.
  List<String> advance(Offset offset) {
    final steps = <String>[];
    final x = offset.dx ~/ stepX;
    final y = offset.dy ~/ stepY;

    while (_x < x) {
      _x++;
      steps.add('C');
    }
    while (_x > x) {
      _x--;
      steps.add('D');
    }
    while (_y < y) {
      _y++;
      steps.add('B');
    }
    while (_y > y) {
      _y--;
      steps.add('A');
    }

    return steps;
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
    this.leading = const [],
    this.showKeys = true,
  });

  final KeyBarController controller;

  /// Read at tap time so cursor keys follow the application's current mode.
  final Terminal terminal;

  final void Function(String data) onEmit;

  /// The session's own buttons, ahead of ESC. Plain [IconButton]s: the bar
  /// dresses them as keys.
  final List<Widget> leading;

  /// False while there is no shell, when the keys would have nothing to talk
  /// to. [leading] stays either way, the way the header it replaced always
  /// showed its buttons, greyed out until there was something to reach.
  final bool showKeys;

  String _cursor(String finalChar) => cursorKey(terminal, finalChar);

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
                  for (final button in leading) _IconKey(button),
                  if (showKeys) ...[
                    const _KeyDivider(),
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
                    _SpacePad(
                      onSpace: () => onEmit(' '),
                      onCursor: (finalChar) => onEmit(_cursor(finalChar)),
                    ),
                    const _KeyDivider(),
                    _KeyButton(label: '^C', onTap: () => onEmit('\x03')),
                    _KeyButton(label: '^D', onTap: () => onEmit('\x04')),
                    _KeyButton(label: '^Z', onTap: () => onEmit('\x1a')),
                    const _KeyDivider(),
                    _KeyButton(
                      label: 'HOME',
                      onTap: () => onEmit(_cursor('H')),
                    ),
                    _KeyButton(
                      label: 'END',
                      onTap: () => onEmit(_cursor('F')),
                    ),
                    _KeyButton(label: 'PGUP', onTap: () => onEmit('\x1b[5~')),
                    _KeyButton(label: 'PGDN', onTap: () => onEmit('\x1b[6~')),
                    const _KeyDivider(),
                    // Symbols the stock keyboard buries two layers deep.
                    for (final symbol in const ['-', '/', '|', '~', ':', '*'])
                      _KeyButton(label: symbol, onTap: () => onEmit(symbol)),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The accessory row under the code editor: the keys a touch keyboard lacks,
/// acting on the editor's own cursor rather than sending bytes to a shell.
///
/// ponytail: no PgUp/PgDn, which re_editor 0.10 leaves unimplemented; the
/// space bar's trackpad and scrolling cover long moves until it has them.
class EditorKeyBar extends StatelessWidget {
  const EditorKeyBar({
    super.key,
    required this.controller,
    this.useTabs = false,
  });

  final CodeLineEditingController controller;

  /// Tab types a real tab instead of spaces: for a Makefile, where a recipe
  /// indented with spaces does not run, and for any file already indented
  /// with tabs.
  final bool useTabs;

  static const _arrows = {
    'A': AxisDirection.up,
    'B': AxisDirection.down,
    'C': AxisDirection.right,
    'D': AxisDirection.left,
  };

  /// What config files and scripts are made of, and the stock keyboard buries
  /// a layer or two down.
  static const _symbols = [
    '{', '}', '[', ']', '(', ')', '<', '>', '"', "'", ';', ':', //
    '/', r'\', '|', r'$', '=', '-', '_', '#', '&', '*', '~',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget arrow(String label, String key) => _KeyButton(
          label: label,
          onTap: () => controller.moveCursor(_arrows[key]!),
        );

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          // Only undo and redo change with the text, but they change on the
          // first keystroke and the last undo, so they are watched.
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                _IconKey(IconButton(
                  tooltip: 'Undo',
                  onPressed: controller.canUndo ? controller.undo : null,
                  icon: const Icon(Icons.undo),
                )),
                _IconKey(IconButton(
                  tooltip: 'Redo',
                  onPressed: controller.canRedo ? controller.redo : null,
                  icon: const Icon(Icons.redo),
                )),
                const _KeyDivider(),
                _KeyButton(
                  label: 'TAB',
                  onTap: useTabs
                      ? () => controller.replaceSelection('\t')
                      : controller.applyIndent,
                ),
                _KeyButton(label: '⇤', onTap: controller.applyOutdent),
                const _KeyDivider(),
                arrow('←', 'D'),
                arrow('↓', 'B'),
                arrow('↑', 'A'),
                arrow('→', 'C'),
                _SpacePad(
                  onSpace: () => controller.replaceSelection(' '),
                  onCursor: (key) => controller.moveCursor(_arrows[key]!),
                ),
                const _KeyDivider(),
                _KeyButton(
                  label: 'HOME',
                  onTap: controller.moveCursorToLineStart,
                ),
                _KeyButton(label: 'END', onTap: controller.moveCursorToLineEnd),
                const _KeyDivider(),
                for (final symbol in _symbols)
                  _KeyButton(
                    label: symbol,
                    onTap: () => controller.replaceSelection(symbol),
                  ),
              ],
            ),
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
    this.minWidth = 44,
  });

  final String label;
  final VoidCallback onTap;

  /// Armed sticky modifiers stay lit so the user can see what the next
  /// keystroke will do.
  final bool active;

  final double minWidth;

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
            constraints: BoxConstraints(minWidth: minWidth),
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

/// A space key that doubles as a cursor trackpad: tap for a space, hold and
/// slide to move.
///
/// Long press is what claims the gesture — the bar scrolls horizontally, and a
/// plain drag belongs to the scroll. Holding first is also the gesture the
/// stock keyboards teach, so the muscle memory carries over.
class _SpacePad extends StatefulWidget {
  const _SpacePad({required this.onSpace, required this.onCursor});

  final VoidCallback onSpace;

  /// Receives the final character of a cursor sequence: A, B, C or D.
  final void Function(String finalChar) onCursor;

  @override
  State<_SpacePad> createState() => _SpacePadState();
}

class _SpacePadState extends State<_SpacePad> {
  final _pad = CursorPad();

  bool _moving = false;

  void _startMoving(LongPressStartDetails _) {
    _pad.reset();
    // The only signal that the key changed meaning, since the finger is
    // covering it.
    HapticFeedback.selectionClick();
    setState(() => _moving = true);
  }

  void _stopMoving() {
    if (_moving) setState(() => _moving = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: _startMoving,
      onLongPressMoveUpdate: (details) {
        for (final finalChar in _pad.advance(details.localOffsetFromOrigin)) {
          widget.onCursor(finalChar);
        }
      },
      onLongPressEnd: (_) => _stopMoving(),
      onLongPressCancel: _stopMoving,
      child: _KeyButton(
        label: _moving ? '↔ MOVE' : 'SPACE',
        active: _moving,
        minWidth: 96,
        onTap: widget.onSpace,
      ),
    );
  }
}

/// An [IconButton] the page hands in, given the face of the keys around it so
/// the header it came from does not show.
class _IconKey extends StatelessWidget {
  const _IconKey(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: colors.onSurface,
            backgroundColor: colors.surfaceContainerHigh,
            // Greyed out rather than gone: still a key, just not one to press.
            disabledBackgroundColor: colors.surfaceContainerHigh,
            iconSize: 20,
            minimumSize: const Size(44, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        child: child,
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

/// Wraps the terminal so a long press arms the arrow keys and the drag that
/// follows holds one down: the direction picks the key, and how far the finger
/// has reached sets how fast it repeats for as long as it stays down. A short
/// reach is one press however long you hold it; further out it ticks about
/// once every two seconds, and further still every 300ms. Lifting the finger
/// stops it.
///
/// Holding first is what claims the gesture, the same split the space key
/// makes with the bar's own scroll: a plain drag is left to the terminal, and
/// scrolls the scrollback the way it would in any other app.
///
/// A double tap sends Tab, which is what a shell wants far more often than it
/// wants a word selected, and a single tap still raises the keyboard.
///
/// That long press is also the one xterm2 selects text with on touch, so what
/// a hold means is settled by what is under the finger when it fires. On a
/// character it selects the word, the way xterm2 would, and the drag that
/// follows widens it word by word; on a space, an empty cell or the padding it
/// arms the arrows. Once the finger lifts, the selection wears Flutter's own
/// handles and toolbar, the way selected text does anywhere else on the
/// phone: drag a handle to move that end, and hold it at the top or bottom
/// edge to scroll on to text out of sight; drag anywhere else to scroll, tap
/// to let go. A mouse still selects with a drag; xterm2's pan recogniser for
/// that is mouse-only.
class SwipeKeyPad extends StatefulWidget {
  const SwipeKeyPad({
    super.key,
    required this.terminal,
    required this.controller,
    required this.onEmit,
    required this.child,
  });

  /// Read at emit time so cursor keys follow the application's current mode.
  final Terminal terminal;

  /// The one [child]'s TerminalView was given, so the word picked here is the
  /// one it paints, and whoever clears it — a key sent, xterm2 changing
  /// screens — ends selecting here too.
  final TerminalController controller;

  final void Function(String data) onEmit;

  final Widget child;

  @override
  State<SwipeKeyPad> createState() => _SwipeKeyPadState();
}

/// How often the held drag is re-examined. Short enough that reaching further
/// speeds the repeat up under the finger, long enough to be free.
const _swipeTick = Duration(milliseconds: 50);

/// How deep the zone along the terminal's top and bottom edges is, where a
/// held handle scrolls it on: 48dp, room for a fingertip to pick a speed in,
/// or two rows when those are more.
const _edgeZone = 48.0;
const _edgeZoneRows = 2;

/// Lines a second the scroll runs at the zone's inner edge — a line every
/// 100ms, slow enough to stop on the one you want — and at the terminal's
/// edge itself: four a frame at 60Hz, for the far end of the scrollback.
const _edgeSlowest = 10.0;
const _edgeFastest = 240.0;

/// Lines a second a handle held at an edge scrolls the terminal on by, for a
/// finger [reach] of the zone deep: 0 at its inner edge, 1 at the terminal's
/// edge. Past the edge is no faster, so the finger never has to leave the
/// terminal: above it are the tab strip and the status bar, where Android
/// pulls its notification shade down, and below it the key bar and the
/// gesture bar. Squared, so it picks up gently from the inner edge and only
/// climbs steeply near the terminal's.
double _edgeLines(double reach) {
  final r = math.min(reach, 1.0);
  return _edgeSlowest + (_edgeFastest - _edgeSlowest) * r * r;
}

class _SwipeKeyPadState extends State<SwipeKeyPad>
    with SingleTickerProviderStateMixin {
  Timer? _repeat;
  Offset _travelled = Offset.zero;
  String? _arrow;

  /// Milliseconds the current key has been held down for since it last
  /// repeated.
  int _held = 0;

  /// Drives the readout: whether it is up, how many chevrons it shows, and
  /// which top corner it sits in.
  bool _swiping = false;
  int _level = 1;
  bool _hudOnRight = true;

  /// On from a hold that lands on a character until the selection goes.
  bool _selecting = false;

  /// Where that hold landed, in the terminal's own coordinates, for as long as
  /// the finger stays down and the drag is still widening the first word.
  Offset? _wordFrom;

  /// The end of the selection a handle drag leaves alone, while one lasts.
  CellOffset? _pinned;

  /// Where the end being dragged has got to, in the terminal's own
  /// coordinates: where its handle pointed, plus however far the finger has
  /// moved since.
  Offset _dragAt = Offset.zero;

  /// The terminal's scroll, while a drag that missed the handles drives it.
  Drag? _scroll;

  /// Scrolls the terminal on while a held handle sits at its top or bottom
  /// edge: every frame rather than on a timer, so the text glides under the
  /// finger instead of jumping at it.
  late final Ticker _edge;

  /// How fast [_edge] scrolls, in pixels a second, negative for up; and how
  /// far into its run the last frame came, so each frame moves by the time it
  /// took, whatever the screen's refresh rate.
  double _edgeSpeed = 0;
  Duration _edgeLast = Duration.zero;

  /// How the selection sits in this pad, worked out from xterm2's cells each
  /// time it or the text under it moves: the feet its two handles hang from,
  /// null for one out of sight, the height of a row, and where the toolbar
  /// goes. Null while there is no selection to show.
  ({
    Offset? start,
    Offset? end,
    double line,
    TextSelectionToolbarAnchors toolbar,
  })? _shown;

  /// Set while a re-placing waits for the frame to be out.
  bool _placing = false;

  @override
  void initState() {
    super.initState();
    _edge = createTicker(_edgeTick);
    widget.controller.addListener(_onSelectionChanged);
    widget.terminal.addListener(_onOutput);
  }

  @override
  void didUpdateWidget(SwipeKeyPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onSelectionChanged);
      widget.controller.addListener(_onSelectionChanged);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onOutput);
      widget.terminal.addListener(_onOutput);
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _edge.dispose();
    widget.controller.removeListener(_onSelectionChanged);
    widget.terminal.removeListener(_onOutput);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (!_selecting) return;
    if (widget.controller.selection != null) {
      setState(_place);
      return;
    }

    // The drag recogniser goes with the selection, and would leave the scroll
    // hanging mid-drag.
    _scroll?.cancel();
    setState(() {
      _selecting = false;
      _wordFrom = null;
      _pinned = null;
      _shown = null;
    });
  }

  /// New output can move the selected text, so the handles and the toolbar
  /// are placed again — once the frame is out, because a terminal sitting on
  /// its last line takes the scroll that brings new output up while it lays
  /// out, and tells nobody.
  void _onOutput() {
    if (!_selecting || _placing) return;
    _placing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placing = false;
      if (mounted && _selecting) setState(_place);
    });
  }

  /// The first [T] inside [SwipeKeyPad.child], or inside [under] — its
  /// TerminalView, or the Scrollable that scrolls it — found rather than
  /// handed in so a pad needs nothing beyond the controller its view was
  /// already given.
  T? _find<T extends State>([BuildContext? under]) {
    T? found;
    void look(Element element) {
      if (element is StatefulElement && element.state is T) {
        found ??= element.state as T;
      } else {
        element.visitChildren(look);
      }
    }

    (under ?? context).visitChildElements(look);
    return found;
  }

  /// The scroll the terminal lays its text out by, which is the innermost
  /// Scrollable in its view. While a program reads the mouse, or has the
  /// alternate screen up, xterm2 wraps that one in a Scrollable of its own
  /// that turns scrolling into wheel events or arrow keys for the program,
  /// and [_find] meets the wrapper first.
  ScrollPosition? _scrollback() {
    ScrollPosition? position;
    for (var scrollable = _find<ScrollableState>();
        scrollable != null;
        scrollable = _find<ScrollableState>(scrollable.context)) {
      position = scrollable.position;
    }
    return position;
  }

  TerminalViewState? _view() => _find<TerminalViewState>();

  /// Whether [global] is on a character rather than a space, an empty cell,
  /// an empty row or the padding round the grid.
  bool _onText(TerminalViewState view, Offset global) {
    final render = view.renderTerminal;
    final at = render.globalToLocal(global);
    final cell = render.getCellOffset(at);
    // getCellOffset pulls a point in the padding onto the nearest cell, so the
    // point has to be inside the cell it came back with.
    if (!(render.getOffset(cell) & render.cellSize).contains(at)) return false;

    final line = widget.terminal.buffer.lines[cell.y];
    var x = cell.x;
    // The right half of a wide character is an empty cell of its own.
    if (x > 0 && line.getWidth(x) == 0 && line.getWidth(x - 1) == 2) x--;
    return x < line.length && line.getCodePoint(x) > 0x20;
  }

  void _select(TerminalViewState view, Offset global) {
    assert(
      identical(view.widget.controller, widget.controller),
      'SwipeKeyPad and its TerminalView need the same TerminalController',
    );
    final render = view.renderTerminal;
    final at = render.globalToLocal(global);
    render.selectWord(at);
    // A separator hemmed in by separators is no word to xterm2, but it is
    // still what the finger is on.
    if (widget.controller.selection == null) render.selectCharacters(at);
    // Lighter than the bump that arms the arrows, so the hand can tell which
    // of the two the hold became.
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      _wordFrom = at;
      _place();
    });
  }

  /// Works out [_shown] from xterm2's cell geometry: a cell's offset in the
  /// terminal, which already takes the scroll into account, and the cell
  /// size, brought into this pad's coordinates.
  ///
  /// The handles hang from the foot of the first cell and of the gap after
  /// the last, which is the text's baseline as near as a terminal has one.
  /// The toolbar goes over the middle of a selection on one row and over the
  /// middle of the pad for one across rows, above the selection, or below it
  /// when there is no room above — the anchors a text field would give it.
  void _place() {
    final range = widget.controller.selection?.normalized;
    final render = _view()?.renderTerminal;
    final box = context.findRenderObject() as RenderBox?;
    if (range == null || render == null || box == null) {
      _shown = null;
      return;
    }

    final line = render.cellSize.height;
    Offset foot(CellOffset cell) => box.globalToLocal(
          render.localToGlobal(render.getOffset(cell) + Offset(0, line)),
        );
    final start = foot(range.begin);
    final end = foot(range.end);
    final size = box.size;
    // Both kept, clipped, while a handle is held: with the ends crossed the
    // finger is on the one at the far end, which the edge scroll can take out
    // of sight, and a handle that leaves the tree takes its drag with it.
    Offset? inSight(Offset foot) =>
        _pinned != null || (foot.dy >= 0 && foot.dy <= size.height)
            ? foot
            : null;
    final x = start.dy == end.dy ? (start.dx + end.dx) / 2 : size.width / 2;
    // Held inside the pad, as a text field holds them inside itself. The
    // lower one is held a toolbar short of the bottom, because this pad clips
    // where an overlay would not, and a selection running off both edges —
    // Select all, say — would otherwise put Copy out of reach.
    final lowest = math.max(
      0.0,
      size.height -
          kMinInteractiveDimension -
          TextSelectionToolbar.kToolbarContentDistanceBelow,
    );
    _shown = (
      start: inSight(start),
      end: inSight(end),
      line: line,
      toolbar: TextSelectionToolbarAnchors(
        primaryAnchor: Offset(x, (start.dy - line).clamp(0.0, size.height)),
        secondaryAnchor: Offset(x, end.dy.clamp(0.0, lowest)),
      ),
    );
  }

  /// A handle is picked up: the other end stays where it is, and this one
  /// follows the finger from where the handle points rather than from where
  /// the finger landed, a line or so lower, so picking it up moves nothing.
  void _grab(bool start) {
    final range = widget.controller.selection?.normalized;
    final render = _view()?.renderTerminal;
    if (range == null || render == null) return;

    setState(() {
      _pinned = start ? range.end : range.begin;
      _dragAt = render.getOffset(start ? range.begin : range.end) +
          Offset(0, render.cellSize.height / 2);
    });
  }

  /// Moves the dragged end, a cell at a time, to the gap between cells
  /// nearest the finger. The ends may cross: the range is normalised
  /// wherever it is read, so the handles trade places, as they do in a text
  /// field.
  ///
  /// Held in the zone inside the top or bottom edge, the finger scrolls the
  /// terminal on towards that edge, as a text field's handle does, and
  /// faster the nearer the edge it is: see [_edgeLines].
  void _drag(DragUpdateDetails details) {
    final render = _view()?.renderTerminal;
    if (_pinned == null || render == null) return;

    _dragAt += details.delta;
    _follow();

    final line = render.cellSize.height;
    final height = render.size.height;
    final y = render.globalToLocal(details.globalPosition).dy;
    // Never so deep that a short tmux pane is all edge.
    final zone =
        math.min(math.max(_edgeZoneRows * line, _edgeZone), height / 3);
    // How far into a zone the finger is: negative along the top, nothing
    // between the two.
    final into = y < zone ? y - zone : math.max(0.0, y - height + zone);
    _edgeSpeed = into.sign * _edgeLines(into.abs() / zone) * line;
    if (into == 0) {
      _edge.stop();
    } else if (!_edge.isActive) {
      _edgeLast = Duration.zero;
      _edge.start();
    }
  }

  /// Puts the dragged end in the gap between cells nearest [_dragAt], held to
  /// the rows in sight: a finger past the edge takes the end to the row along
  /// it, and the edge scroll brings the rest to it, rather than the end
  /// running on out of sight with its handle.
  void _follow() {
    final pinned = _pinned;
    final render = _view()?.renderTerminal;
    if (pinned == null || render == null) return;

    final at = Offset(
      _dragAt.dx,
      _dragAt.dy.clamp(
        0.0,
        math.max(0.0, render.size.height - render.cellSize.height),
      ),
    );
    final cell = render.getCellOffset(at);
    final pastMiddle =
        at.dx - render.getOffset(cell).dx > render.cellSize.width / 2;
    final gap = pastMiddle ? CellOffset(cell.x + 1, cell.y) : cell;
    // Nothing selected is no selection, and the same end twice is no move.
    if (gap == pinned || gap == widget.controller.selection?.end) return;

    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(pinned),
      buffer.createAnchorFromOffset(gap),
    );
  }

  /// A frame's worth of the scroll a handle held at an edge asks for, then the
  /// dragged end put under the finger again: it has not moved, but the text
  /// under it has. The handles and toolbar follow the scroll as they do any
  /// other. Stops at the end of the scrollback, where there is nothing left to
  /// bring into sight.
  ///
  /// It scrolls the scrollback itself, never the program: the text beyond the
  /// edge is what the handle is reaching for. A wheel event sent instead
  /// would scroll the program a line, and the page lets go of a selection on
  /// anything the terminal sends, so the selection, and the scroll with it,
  /// would end a line in. On the alternate screen there is no scrollback,
  /// and so nothing to scroll.
  void _edgeTick(Duration elapsed) {
    final position = _scrollback();
    if (_pinned == null || position == null) {
      _edge.stop();
      return;
    }

    final seconds = (elapsed - _edgeLast).inMicroseconds /
        Duration.microsecondsPerSecond;
    _edgeLast = elapsed;
    final to = (position.pixels + _edgeSpeed * seconds)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    position.jumpTo(to);
    _follow();
    final extent =
        _edgeSpeed < 0 ? position.minScrollExtent : position.maxScrollExtent;
    if (to == extent) _edge.stop();
  }

  /// A finger that was shaping the selection has lifted, so the toolbar can
  /// come back without being under it, the edge scroll ends, and a handle
  /// kept while held goes if it is out of sight.
  void _settle() {
    _edge.stop();
    setState(() {
      _wordFrom = null;
      _pinned = null;
      if (_selecting) _place();
    });
  }

  /// While a selection is up the pad takes every touch, so a drag that missed
  /// the handles is handed to the scroll position of the terminal's own
  /// Scrollable — the one it would have driven itself, fling and all.
  void _scrollStart(DragStartDetails details) => _scroll =
      _find<ScrollableState>()?.position.drag(details, () => _scroll = null);

  void _copy() {
    final range = widget.controller.selection;
    if (range != null) {
      Clipboard.setData(
        ClipboardData(text: widget.terminal.buffer.getText(range, true)),
      );
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
      );
    }
    widget.controller.clearSelection();
  }

  /// The clipboard goes to the shell through xterm2's own paste, the one a
  /// hardware Ctrl+V takes, so it arrives bracketed when the shell asked for
  /// that.
  ///
  /// ponytail: offered whether or not the clipboard holds any text. A
  /// ClipboardStatusNotifier would hide it when empty, as a text field does.
  Future<void> _paste() async {
    widget.controller.clearSelection();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null) widget.terminal.paste(text);
  }

  /// Everything the terminal holds, scrollback and all, as xterm2's own
  /// Ctrl+A takes it.
  void _selectAll() {
    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth, buffer.height - 1),
      mode: SelectionMode.line,
    );
  }

  void _onUpdate(LongPressMoveUpdateDetails details) {
    final from = _wordFrom;
    if (from != null) {
      final render = _view()?.renderTerminal;
      render?.selectWord(from, render.globalToLocal(details.globalPosition));
      return;
    }
    // A hold whose selection went while it was down steers nothing.
    if (!_swiping) return;

    // Measured from where the finger landed, not from where the hold was
    // recognised, so a finger that crept a little while holding still is not
    // judged short of where it actually is.
    _travelled = details.localOffsetFromOrigin;

    final arrow = swipeArrow(_travelled);
    final level = swipeSpeedLevel(_travelled.distance);
    // Repaint when the readout would actually differ, not on every pixel the
    // finger crosses — the terminal underneath is expensive to rebuild.
    if (arrow == _arrow && level == _level) return;

    // A new direction is one press straight away, so a short drag does
    // something without being held at all.
    if (arrow != _arrow) {
      _held = 0;
      if (arrow != null) widget.onEmit(cursorKey(widget.terminal, arrow));
    }

    setState(() {
      _arrow = arrow;
      _level = level;
    });
  }

  /// Reads the reach afresh every tick rather than scheduling one repeat at a
  /// time, so a finger that reaches further mid-hold speeds up immediately
  /// instead of waiting out the two seconds already in flight.
  void _onTick(Timer _) {
    final arrow = _arrow;
    final interval = arrow == null ? null : swipeRepeatMs(_travelled.distance);

    // Pulled back to a nudge: stop repeating, and do not bank the wait.
    if (interval == null) {
      _held = 0;
      return;
    }

    _held += _swipeTick.inMilliseconds;
    if (_held < interval) return;

    _held = 0;
    widget.onEmit(cursorKey(widget.terminal, arrow!));
  }

  void _start(LongPressStartDetails details) {
    final view = _view();
    if (view != null && _onText(view, details.globalPosition)) {
      _select(view, details.globalPosition);
      return;
    }

    // Never leave an earlier tick running: two of them would race the same
    // key out at twice the rate the reach asked for.
    _repeat?.cancel();
    // The finger is still, and covering the spot; nothing else says the drag
    // that follows will steer instead of scroll. The same bump the magic key
    // gives when its ring opens, since it is the same kind of hold.
    HapticFeedback.mediumImpact();

    final width = context.size?.width;

    setState(() {
      _reset();
      _swiping = true;
      // Sit on the far side from the finger. The hand comes in over the side
      // it started on, and a readout under your own palm tells you nothing.
      _hudOnRight = width == null || details.localPosition.dx < width / 2;
    });

    _repeat = Timer.periodic(_swipeTick, _onTick);
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
    // The recogniser can cancel us on its way out, after we are already gone.
    if (!mounted) return;
    setState(() {
      _reset();
      _swiping = false;
    });
  }

  void _reset() {
    _arrow = null;
    _level = 1;
    _held = 0;
    _travelled = Offset.zero;
  }

  /// One of Flutter's own selection handles, hung by its anchor from [foot]
  /// the way a text field hangs it from the baseline, in a touch target as
  /// big as the one Flutter's own overlay gives it. Keyed by its side, so a
  /// handle keeps its drag while the other one comes and goes.
  Widget _handle(TextSelectionHandleType type, Offset foot, double line) {
    final controls = materialTextSelectionControls;
    final size = controls.getHandleSize(line);
    final at = foot -
        controls.getHandleAnchor(type, line) -
        Offset(
          (kMinInteractiveDimension - size.width) / 2,
          (kMinInteractiveDimension - size.height) / 2,
        );

    return Positioned(
      key: ValueKey(type),
      left: at.dx,
      top: at.dy,
      child: GestureDetector(
        // Opaque, and above the pad, so a touch on it goes nowhere else and
        // the drag starts the moment the finger lands.
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _grab(type == TextSelectionHandleType.left),
        onPanUpdate: _drag,
        onPanEnd: (_) => _settle(),
        child: SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: Center(child: controls.buildHandle(context, type, line)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;

    return Stack(
      children: [
        // The terminal's scrolling, heard on its way up, so the handles and
        // the toolbar go where the text goes.
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (_) {
            if (_selecting) setState(_place);
            return false;
          },
          child: widget.child,
        ),
        // A layer over the terminal rather than a wrapper round it, so it
        // meets every touch before xterm2 does. That order is what decides the
        // long press: xterm2 holds one too, for selecting text, both wait out
        // the same platform timeout, and of two timers due together the one
        // started first fires first and wins. Wrapped, that would be xterm2's,
        // and every hold would select, even on the blank the arrows want.
        // Translucent, so the touch still reaches the terminal underneath for
        // the taps and drags this lets go of — except while a selection is
        // up. xterm2 lets go of a selection once a touch has lasted 100ms,
        // which a slow drag does well before it counts as a scroll, so while
        // one is up the pad keeps every touch and hands a drag on to the
        // terminal's scroll itself.
        Positioned.fill(
          child: RawGestureDetector(
            behavior: _selecting
                ? HitTestBehavior.opaque
                : HitTestBehavior.translucent,
            excludeFromSemantics: true,
            gestures: {
              // ponytail: the one cell under the finger decides, so a hold on
              // the space between two words steers rather than selects. Look
              // a cell either side too if people keep missing the letter.
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  debugOwner: this,
                  supportedDevices: const {PointerDeviceKind.touch},
                ),
                (instance) {
                  instance
                    ..onLongPressStart = _start
                    ..onLongPressMoveUpdate = _onUpdate
                    ..onLongPressEnd = (_) {
                      _swiping ? _stop() : _settle();
                    }
                    ..onLongPressCancel = _stop;
                },
              ),
              // ponytail: this holds the arena for kDoubleTapTimeout, so a
              // single tap raises the keyboard ~300ms later than it used to.
              // Detect the second tap from a plain Listener instead if that
              // lag ever grates — at the cost of xterm2 also selecting a word
              // under the double tap.
              if (!_selecting)
                DoubleTapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        DoubleTapGestureRecognizer>(
                  () => DoubleTapGestureRecognizer(debugOwner: this),
                  (instance) =>
                      instance.onDoubleTap = () => widget.onEmit('\t'),
                ),
              if (_selecting) ...{
                VerticalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(debugOwner: this),
                  (instance) {
                    instance
                      ..onStart = _scrollStart
                      ..onUpdate = (details) {
                        _scroll?.update(details);
                      }
                      ..onEnd = (details) {
                        _scroll?.end(details);
                      };
                  },
                ),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(debugOwner: this),
                  (instance) =>
                      instance.onTap = widget.controller.clearSelection,
                ),
              },
            },
          ),
        ),
        if (_swiping)
          Positioned(
            top: 12,
            left: _hudOnRight ? null : 12,
            right: _hudOnRight ? 12 : null,
            // Never in the way of the drag it is reporting on.
            child: IgnorePointer(
              child: _SwipeReadout(arrow: _arrow, level: _level),
            ),
          ),
        if (shown != null) ...[
          if (shown.start case final foot?)
            _handle(TextSelectionHandleType.left, foot, shown.line),
          if (shown.end case final foot?)
            _handle(TextSelectionHandleType.right, foot, shown.line),
          // Over the handles, where Flutter's own overlay puts it, and gone
          // whenever a finger is shaping the selection, so it is never under
          // one.
          if (_wordFrom == null && _pinned == null)
            Positioned.fill(
              child: AdaptiveTextSelectionToolbar.buttonItems(
                anchors: shown.toolbar,
                buttonItems: [
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: _copy,
                  ),
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.paste,
                    onPressed: _paste,
                  ),
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.selectAll,
                    onPressed: _selectAll,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// The compass that comes up under a swipe: four idle arms, and the one being
/// held drawn as a stack of chevrons — one for a nudge, three when the cursor
/// is running as fast as the gesture goes.
class _SwipeReadout extends StatelessWidget {
  const _SwipeReadout({required this.arrow, required this.level});

  final String? arrow;
  final int level;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        // Lifted off the background rather than frosted: a BackdropFilter over
        // a terminal repaints the blur on every line of output, which is a lot
        // to pay for a hint. Opaque enough to knock back whatever it lands on —
        // it sits in a corner where the prompt usually is, and a bright line of
        // shell output showing through drowns the arms out.
        color: const Color(0xD8262626),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Stack(
        children: [
          _arm('A', Alignment.topCenter),
          _arm('D', Alignment.centerLeft),
          _arm('C', Alignment.centerRight),
          _arm('B', Alignment.bottomCenter),
        ],
      ),
    );
  }

  Widget _arm(String direction, Alignment at) {
    final live = direction == arrow;

    return Align(
      alignment: at,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: live
            ? _chevrons(direction)
            : Icon(
                _swipeArmIcons[direction],
                size: 22,
                color: Colors.white.withValues(alpha: 0.45),
              ),
      ),
    );
  }

  /// Overlapped rather than spaced out, so three of them still fit the arm.
  Widget _chevrons(String direction) {
    const icon = 24.0;
    const step = 9.0;
    final sideways = direction == 'C' || direction == 'D';
    final run = icon + step * (level - 1);

    return SizedBox(
      width: sideways ? run : icon,
      height: sideways ? icon : run,
      child: Stack(
        children: [
          for (var i = 0; i < level; i++)
            Positioned(
              left: sideways ? i * step : 0,
              top: sideways ? 0 : i * step,
              child: Icon(
                _swipeChevronIcons[direction],
                size: icon,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}
