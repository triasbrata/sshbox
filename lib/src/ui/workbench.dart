import 'package:flutter/material.dart';

/// Two panes and the seam between them.
///
/// Knows nothing about terminals or files — it is given two widgets and the
/// rule for sharing width. That keeps the split out of [TerminalPage], where
/// it would otherwise sit tangled up with session state, and lets the geometry
/// be tested on its own.
///
/// With no [secondary] the primary pane simply gets the whole width, which is
/// how a session starts and how it stays on a phone.
class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    required this.primary,
    this.secondary,
    this.initialFraction = 0.42,
    this.minFraction = 0.25,
    this.maxFraction = 0.75,
  });

  final Widget primary;
  final Widget? secondary;

  /// How much width the primary pane starts with. Slightly under half: the
  /// editor is the thing being read closely, the terminal is being watched.
  final double initialFraction;

  /// How far the seam can be dragged. Neither pane may be squeezed to a
  /// sliver, because a pane too narrow to read is worse than a closed one.
  final double minFraction;
  final double maxFraction;

  /// The draggable divider, so a test can grab it by name rather than by
  /// hunting through gesture detectors.
  static const seamKey = ValueKey('workbench-seam');

  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late double _fraction = widget.initialFraction;

  @override
  Widget build(BuildContext context) {
    final secondary = widget.secondary;
    if (secondary == null) return widget.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Row(
          children: [
            SizedBox(width: width * _fraction, child: widget.primary),
            _Seam(
              key: Workbench.seamKey,
              onDrag: (delta) => setState(() {
                _fraction = ((width * _fraction + delta) / width)
                    .clamp(widget.minFraction, widget.maxFraction);
              }),
            ),
            Expanded(child: secondary),
          ],
        );
      },
    );
  }
}

/// The draggable divider.
///
/// A fixed split is wrong for both of the things people do here: reading a
/// long line of code wants the right pane, watching a build wants the left.
class _Seam extends StatelessWidget {
  const _Seam({super.key, required this.onDrag});

  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        // Opaque so the whole strip drags: a one-pixel line is not a target
        // anyone can hit with a finger.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 12,
          alignment: Alignment.center,
          child: Container(
            width: 1,
            height: double.infinity,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}
