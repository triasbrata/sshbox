import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the tab strip is drawn into the window's own title bar, the way
/// Chrome and VS Code draw theirs: on a Mac, where `MainFlutterWindow.swift`
/// hides the title and lets the Flutter view run up under the window's
/// buttons. Windows and Linux keep a title bar of their own above the view,
/// so there the strip has no buttons to leave room for and nothing to drag.
bool get drawsInTitleBar => defaultTargetPlatform == TargetPlatform.macOS;

/// The Mac's title bar as the window last measured it. [inset] is where the
/// window's buttons end, from its left edge, so the tabs start after them;
/// [height] is the band at the top that a page other than the tabs keeps
/// clear of. Both are 0 in full screen, which hides the buttons, and
/// everywhere but a Mac.
final titleBar = ValueNotifier<({double inset, double height})>((
  inset: 0,
  height: 0,
));

const _window = MethodChannel('sshbox/window');

/// Asks the window where its buttons are, and listens for it saying again as
/// full screen comes and goes. Nothing but on a Mac.
Future<void> watchTitleBar() async {
  if (!drawsInTitleBar) return;
  _window.setMethodCallHandler((call) async {
    if (call.method == 'titleBar') titleBar.value = _read(call.arguments);
  });
  try {
    titleBar.value = _read(await _window.invokeMethod<Object?>('titleBar'));
  } on Exception {
    // No answer, as from a window without its half of this: a strip that
    // leaves no room is what such a window wants anyway.
  }
}

({double inset, double height}) _read(Object? answer) {
  double at(String key) =>
      answer is Map ? (answer[key] as num?)?.toDouble() ?? 0 : 0;
  return (inset: at('inset'), height: at('height'));
}

/// Moves the window with the mouse, for a press on the title bar that
/// nothing drawn there took: the primary button only, since a right-click
/// on a title bar moves nothing. A double-click is the window's to tell, and
/// it does what the Mac is set to do with one.
void dragWindow(PointerDownEvent event) {
  if (!drawsInTitleBar ||
      event.kind != PointerDeviceKind.mouse ||
      event.buttons != kPrimaryMouseButton) {
    return;
  }
  unawaited(_window.invokeMethod<void>('drag').catchError((_) {}));
}

/// Keeps every page clear of the Mac's title bar, as a phone's pages keep
/// clear of its status bar: the band is top padding in the [MediaQuery],
/// which an app bar, a [SafeArea] and the toasts already make room for. The
/// tab shell takes it away again, its strip being drawn into the band on
/// purpose.
///
/// While a page covers the tabs, the band moves the window, as the title bar
/// it stands for did; [covered] says when one does. Over the tabs it stands
/// aside, the strip's own empty space moving the window, so that a press on
/// a tab under the band is only ever the tab's.
class TitleBarSpace extends StatelessWidget {
  const TitleBarSpace({super.key, required this.covered, required this.child});

  final bool Function() covered;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!drawsInTitleBar) return child;
    return ValueListenableBuilder(
      valueListenable: titleBar,
      builder: (context, bar, _) {
        final media = MediaQuery.of(context);
        return Stack(
          fit: StackFit.expand,
          children: [
            MediaQuery(
              data: media.copyWith(
                padding: media.padding.copyWith(top: bar.height),
                viewPadding: media.viewPadding.copyWith(top: bar.height),
              ),
              child: child,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: bar.height,
              // Translucent: what is under the band hears the press too, and
              // over a page that is only the empty top of its app bar.
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (covered()) dragWindow(event);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
