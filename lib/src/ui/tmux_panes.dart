import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

import '../session/tmux.dart';
import 'settings_page.dart';

/// A tmux window drawn the way tmux laid it out: every pane at its own cells,
/// a thin line down the middle of the cell tmux leaves between two panes,
/// and the focused pane outlined when there is more than one.
///
/// tmux decides every pane's size, from the size of the window, so the window
/// is told how many cells fit here on every layout pass — the soft keyboard
/// coming up included — and answers with the layout this draws.
///
/// Touching a pane focuses it. A [Listener] rather than a gesture, so the
/// touch still goes on to the pane's own taps, swipes and scrolling.
///
/// Dragging a border between panes resizes them through tmux (see
/// [TmuxSession.resizeSplit]); nothing here sizes a pane by itself. A finger
/// takes a border from 12 dp either side of its line, but only once it moves
/// across the line, so a tap, a long press or a scroll along it that starts
/// there still reaches the pane. A mouse takes it from the gap tmux leaves,
/// where it shows a resize cursor.
class TmuxPaneLayout extends StatelessWidget {
  const TmuxPaneLayout({
    super.key,
    required this.tmux,
    required this.textStyle,
    required this.padding,
    required this.pane,
  });

  final TmuxSession tmux;

  /// What the panes' views draw with, so that a cell here is a cell there.
  final TerminalStyle textStyle;

  final EdgeInsets padding;

  /// One pane's view, laid out at exactly its cells. It must leave the
  /// terminal's size alone: that is tmux's to set.
  final Widget Function(TmuxPane pane, bool focused) pane;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cell = terminalCellSize(textStyle, MediaQuery.textScalerOf(context));

    return LayoutBuilder(
      builder: (context, constraints) {
        tmux.resize(
          (constraints.maxWidth - padding.horizontal) ~/ cell.width,
          (constraints.maxHeight - padding.vertical) ~/ cell.height,
        );

        Rect rect(TmuxLayout cells) => Rect.fromLTWH(
          padding.left + cells.x * cell.width,
          padding.top + cells.y * cell.height,
          cells.width * cell.width,
          cells.height * cell.height,
        );

        final layout = tmux.layout;
        final borders = layout == null
            ? const <_Border>[]
            : _dividers(layout, cell).toList();
        final panes = tmux.panes;
        final focused = tmux.focused;

        return ColoredBox(
          // The gaps between panes are the terminal's colour, not the page's,
          // so the window reads as one terminal cut up rather than several
          // floating on a card.
          color: terminalThemeOf(context).background,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _BorderDrag: GestureRecognizerFactoryWithHandlers<_BorderDrag>(
                _BorderDrag.new,
                (drag) => drag
                  ..borders = borders
                  ..cell = cell
                  ..onMove = (border, at) => tmux.resizeSplit(
                    border.split,
                    border.index,
                    border.split.sideBySide
                        ? (at.dx - padding.left) ~/ cell.width
                        : (at.dy - padding.top) ~/ cell.height,
                  ),
              ),
            },
            child: ClipRect(
              child: Stack(
                children: [
                  for (final each in panes)
                    Positioned.fromRect(
                      key: ObjectKey(each),
                      rect: rect(each.cells),
                      child: Listener(
                        onPointerDown: (_) => tmux.focus(each),
                        child: pane(each, each == focused),
                      ),
                    ),
                  for (final border in borders) ...[
                    Positioned.fromRect(
                      rect: border.line,
                      child: ColoredBox(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    Positioned.fromRect(
                      rect: border.split.sideBySide
                          ? border.line.inflate(cell.width / 2 + 3)
                          : border.line.inflate(cell.height / 2 + 3),
                      // Translucent: a cursor and nothing else, the touch going
                      // on to the pane beneath.
                      child: MouseRegion(
                        opaque: false,
                        hitTestBehavior: HitTestBehavior.translucent,
                        cursor: border.split.sideBySide
                            ? SystemMouseCursors.resizeColumn
                            : SystemMouseCursors.resizeRow,
                      ),
                    ),
                  ],
                  if (panes.length > 1 && focused != null)
                    Positioned.fromRect(
                      rect: rect(focused.cells).inflate(1.5),
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              // The theme's accent. Light primary sits nearer
                              // its background, so this much of it keeps the
                              // line at 3:1 there too.
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// A one-pixel line through the middle of each cell tmux leaves between
  /// neighbours, running the length of the split they share.
  Iterable<_Border> _dividers(TmuxLayout node, Size cell) sync* {
    for (var i = 1; i < node.children.length; i++) {
      final before = node.children[i - 1];
      final Rect line;
      if (node.sideBySide) {
        final x = padding.left + (before.x + before.width + 0.5) * cell.width;
        line = Rect.fromLTWH(
          x - 0.5,
          padding.top + node.y * cell.height,
          1,
          node.height * cell.height,
        );
      } else {
        final y = padding.top + (before.y + before.height + 0.5) * cell.height;
        line = Rect.fromLTWH(
          padding.left + node.x * cell.width,
          y - 0.5,
          node.width * cell.width,
          1,
        );
      }
      yield (
        line: line,
        split: node,
        index: i,
        id: (
          node.sideBySide,
          before.panes.first.pane,
          node.children[i].panes.first.pane,
        ),
      );
    }
    for (final child in node.children) {
      yield* _dividers(child, cell);
    }
  }
}

/// A border between two of a split's children. [id] names it across
/// layouts — the first pane on each side, which a resize leaves in place —
/// so a drag follows its border as tmux redraws it.
typedef _Border = ({
  Rect line,
  TmuxLayout split,
  int index,
  (bool, int?, int?) id,
});

/// A drag that starts on a border and moves it. Takes the pointer only when
/// it goes down near a border, and wins it from the pane beneath only once
/// it moves across that border: a few dp for a finger, sooner than the pane's
/// own scrolling or selecting would, and a pixel for a mouse, which starts in
/// the gap between panes where the panes get nothing anyway. A move along
/// the border never wins, so a scroll that starts beside one still scrolls.
class _BorderDrag extends PanGestureRecognizer {
  _BorderDrag() {
    dragStartBehavior = DragStartBehavior.down;
    onUpdate = _move;
  }

  List<_Border> borders = const [];
  Size cell = const Size(8, 16);
  void Function(_Border border, Offset at) onMove = (_, _) {};

  _Border? _border;

  /// Where on the border it was taken, so it moves with the pointer rather
  /// than jumping under it.
  Offset _grab = Offset.zero;
  Offset _down = Offset.zero;
  Offset _moved = Offset.zero;

  static bool _precise(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (event is PointerDownEvent) {
      _border = null;
      final at = event.localPosition;
      for (final border in borders) {
        final across = border.split.sideBySide;
        final reach = _precise(event.kind)
            ? (across ? cell.width : cell.height) / 2 + 3
            : 12.0;
        final line = border.line;
        final off = at - line.center;
        final inLength = across
            ? at.dy >= line.top && at.dy <= line.bottom
            : at.dx >= line.left && at.dx <= line.right;
        final distance = (across ? off.dx : off.dy).abs();
        final best = _border == null
            ? reach
            : (_border!.split.sideBySide ? _grab.dx : _grab.dy).abs();
        if (inLength && distance <= best) {
          _border = border;
          _grab = across ? Offset(off.dx, 0) : Offset(0, off.dy);
        }
      }
      _down = event.position;
      _moved = Offset.zero;
      _went = false;
    }
    return _border != null && super.isPointerAllowed(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _moved = event.position - _down;
    super.handleEvent(event);
  }

  /// Whether the pointer has gone across its border — the one thing that
  /// moves it, even when nothing else wanted the pointer and it came here.
  bool _crossed(PointerDeviceKind kind) {
    final border = _border;
    if (border == null) return false;
    final across = border.split.sideBySide ? _moved.dx : _moved.dy;
    return across.abs() > (_precise(kind) ? 1 : 6);
  }

  bool _went = false;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => _crossed(pointerDeviceKind);

  void _move(DragUpdateDetails details) {
    final grabbed = _border;
    if (grabbed == null) return;
    _went = _went || _crossed(details.kind ?? PointerDeviceKind.touch);
    if (!_went) return;
    // The border as tmux has it now, rather than as it was on grabbing.
    final border = borders.firstWhere(
      (each) => each.id == grabbed.id,
      orElse: () => grabbed,
    );
    onMove(border, details.localPosition - _grab);
  }
}

/// The size of one terminal cell, measured the way xterm2's painter measures
/// it: the widest and tallest of the printable ASCII glyphs.
// ponytail: a copy of xterm2's private TerminalPainter._measureCharSize. If
// the two drift apart the panes are off by a fraction of a cell each; a
// public measure in xterm2 would retire this.
Size terminalCellSize(TerminalStyle style, TextScaler scaler) {
  final textStyle = style.toTextStyle();
  final paragraphStyle = textStyle.getParagraphStyle();
  final run = textStyle.getTextStyle(textScaler: scaler);

  var width = 0.0;
  var height = 0.0;
  for (var code = 0x21; code <= 0x7e; code++) {
    final builder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(run)
      ..addText(String.fromCharCode(code));
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    width = math.max(width, paragraph.maxIntrinsicWidth);
    height = math.max(height, paragraph.height);
    paragraph.dispose();
  }
  return Size(width, height);
}
