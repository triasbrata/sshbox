import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

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

/// A Mac's Ctrl+click, made the right-click it is everywhere else on a Mac.
///
/// AppKit hands Flutter a Ctrl+click as what it is, the primary button with
/// Ctrl held (FlutterViewController's mouseDown:), and no Flutter widget
/// reads it as a context menu — so on a trackpad set to Ctrl+click, or a
/// one-button mouse, not one of [rightClick]'s menus opened. Every press
/// goes through [convert] before any widget sees it, so each of them, and
/// the terminal's own right-click, hears the secondary button there.
///
/// Not while Ctrl is the key that opens a terminal link, which is a
/// Ctrl+click of its own; ⌘, the Mac's default, leaves Ctrl free.
class ControlClick {
  ControlClick({required this.ctrlOpensLinks});

  final bool Function() ctrlOpensLinks;

  /// The presses made secondary, until they are up.
  final _pressed = <int>{};

  PointerEvent convert(PointerEvent event) {
    if (defaultTargetPlatform != TargetPlatform.macOS ||
        event.kind != PointerDeviceKind.mouse) {
      return event;
    }
    if (event is PointerDownEvent &&
        event.buttons == kPrimaryMouseButton &&
        HardwareKeyboard.instance.isControlPressed &&
        !ctrlOpensLinks()) {
      _pressed.add(event.pointer);
    }
    if (!_pressed.contains(event.pointer)) return event;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pressed.remove(event.pointer);
      return event;
    }
    return event.buttons & kPrimaryMouseButton == 0
        ? event
        : event.copyWith(
            buttons:
                event.buttons & ~kPrimaryMouseButton | kSecondaryMouseButton,
          );
  }
}

/// The app's binding: Flutter's own, with every pointer event passed
/// through [ControlClick] first.
class JeanshBinding extends WidgetsFlutterBinding {
  JeanshBinding._(this._controlClick);

  final ControlClick _controlClick;

  /// In place of [WidgetsFlutterBinding.ensureInitialized], first in main.
  static void ensureInitialized({required bool Function() ctrlOpensLinks}) =>
      JeanshBinding._(ControlClick(ctrlOpensLinks: ctrlOpensLinks));

  @override
  void handlePointerEvent(PointerEvent event) =>
      super.handlePointerEvent(_controlClick.convert(event));
}

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
