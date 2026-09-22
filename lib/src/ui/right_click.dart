import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
///
/// After a frame already asked for: the click that opens it may have moved
/// focus — a group's pane takes it on the pointer going down — and that
/// frame's rebuild would otherwise take the focus from the menu it had just
/// been given, so Escape reached nothing and the menu stayed open under the
/// next click.
Future<T?> showMenuAt<T>(
  BuildContext context,
  Offset at,
  List<PopupMenuEntry<T>> items,
) async {
  if (SchedulerBinding.instance.hasScheduledFrame) {
    await SchedulerBinding.instance.endOfFrame;
  }
  if (!context.mounted) return null;
  final overlay = Overlay.of(context).context;
  if (!overlay.mounted) return null;
  final box = overlay.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      box.globalToLocal(at) & Size.zero,
      Offset.zero & box.size,
    ),
    items: items,
  );
}

/// A tab's own menu — what a right-click on its chip opens — handed down to
/// its page, so a right-click inside the page opens it too. [items] is asked
/// at the click, so it is the menu as the strip last drew it.
///
/// The shell opens it for a right-click that nothing in the page took; a
/// page with a context menu of its own, the terminal's, puts it below its
/// own items.
class TabMenu extends InheritedWidget {
  const TabMenu({super.key, required this.items, required super.child});

  final List<(String, VoidCallback)> Function() items;

  static TabMenu? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TabMenu>();

  /// The menu's entries, as the chip shows them.
  List<PopupMenuEntry<void>> entries() => [
    for (final (label, onTap) in items())
      PopupMenuItem<void>(onTap: onTap, child: Text(label)),
  ];

  @override
  bool updateShouldNotify(TabMenu oldWidget) => false;
}
