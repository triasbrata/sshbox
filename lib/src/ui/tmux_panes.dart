import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

import '../session/tmux.dart';

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
        final panes = tmux.panes;
        final focused = tmux.focused;

        return ColoredBox(
          // The gaps between panes are the terminal's colour, not the page's,
          // so the window reads as one terminal cut up rather than several
          // floating on a card.
          color: TerminalThemes.defaultTheme.background,
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
                if (layout != null)
                  for (final line in _dividers(layout, cell))
                    Positioned.fromRect(
                      rect: line,
                      child: ColoredBox(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                if (panes.length > 1 && focused != null)
                  Positioned.fromRect(
                    rect: rect(focused.cells).inflate(1.5),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A one-pixel line through the middle of each cell tmux leaves between
  /// neighbours, running the length of the split they share.
  Iterable<Rect> _dividers(TmuxLayout node, Size cell) sync* {
    for (var i = 1; i < node.children.length; i++) {
      final before = node.children[i - 1];
      if (node.sideBySide) {
        final x = padding.left + (before.x + before.width + 0.5) * cell.width;
        yield Rect.fromLTWH(
          x - 0.5,
          padding.top + node.y * cell.height,
          1,
          node.height * cell.height,
        );
      } else {
        final y = padding.top + (before.y + before.height + 0.5) * cell.height;
        yield Rect.fromLTWH(
          padding.left + node.x * cell.width,
          y - 0.5,
          node.width * cell.width,
          1,
        );
      }
    }
    for (final child in node.children) {
      yield* _dividers(child, cell);
    }
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
