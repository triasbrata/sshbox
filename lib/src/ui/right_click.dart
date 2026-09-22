import 'package:flutter/material.dart';

import '../platform.dart';

/// A right-click that opens whatever a long press opens, for a widget's
/// `onSecondaryTapUp`: a desktop is driven by a mouse, which has no long
/// press, so there the second button is how a menu is asked for. [open] is
/// handed where the click landed, in global coordinates, for [showMenuAt].
///
/// Null on a phone or a tablet, where nothing changes, and when [open] is:
/// nothing to open. It adds the click and takes nothing away, so a desktop
/// touchscreen still long-presses.
GestureTapUpCallback? rightClick(void Function(Offset at)? open) =>
    isDesktop && open != null
    ? (details) => open(details.globalPosition)
    : null;

/// Opens a menu with its corner at [at], a global position — the pointer's,
/// as a context menu opens, or the finger's.
Future<T?> showMenuAt<T>(
  BuildContext context,
  Offset at,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      overlay.globalToLocal(at) & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}
