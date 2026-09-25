import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'right_click.dart';
import 'tui.dart';
import 'update_dialog.dart';

/// Whether the tab strip is drawn into the window's own title bar, the way
/// Chrome and VS Code draw theirs: on every desktop. On a Mac
/// `MainFlutterWindow.swift` hides the title and lets the Flutter view run
/// up under the window's buttons; on Windows and Linux the runner takes the
/// title bar away altogether and the app draws the buttons itself — see
/// [drawsWindowButtons].
bool get drawsInTitleBar => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// Whether minimize, maximize and close are the app's to draw, at the
/// window's top right: Windows and Linux, whose runners draw no title bar
/// (flutter_window.cpp, my_application.cc). A Mac keeps its traffic lights.
bool get drawsWindowButtons => switch (defaultTargetPlatform) {
  TargetPlatform.windows || TargetPlatform.linux => true,
  _ => false,
};

/// The height of the band the window buttons sit in: the tab strip's.
const windowButtonsHeight = 40.0;

/// Whether the window is maximized, as the runner last said.
final windowMaximized = ValueNotifier(false);

/// Whether the pointer is over the maximize button, as Windows tells it: the
/// runner answers that spot as the window's own maximize button, so Windows
/// 11's snap layouts open over it, and the pointer never reaches Flutter
/// there.
final _maximizeHover = ValueNotifier(false);

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
/// full screen comes and goes, on a Mac; on Windows and Linux, listens for
/// the window being maximized and restored.
Future<void> watchTitleBar() async {
  if (!drawsInTitleBar) return;
  _lastPress = null;
  _window.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'titleBar':
        titleBar.value = _read(call.arguments);
      case 'maximized':
        windowMaximized.value = call.arguments == true;
      case 'maximizeHover':
        _maximizeHover.value = call.arguments == true;
    }
  });
  if (drawsWindowButtons) return;
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

void _ask(String method, [Object? arguments]) =>
    unawaited(_window.invokeMethod<void>(method, arguments).catchError((_) {}));

/// The last press that moved the window, for telling a double-click.
({Duration at, Offset where})? _lastPress;

/// Moves the window with the mouse, for a press on the title bar that
/// nothing drawn there took: the primary button only, since a right-click
/// on a title bar moves nothing. On a Mac a double-click is the window's to
/// tell, and it does what the Mac is set to do with one; on Windows and
/// Linux it is told here, and maximizes or restores, as a title bar's does.
void dragWindow(PointerDownEvent event) {
  if (!drawsInTitleBar ||
      event.kind != PointerDeviceKind.mouse ||
      event.buttons != kPrimaryMouseButton) {
    return;
  }
  if (drawsWindowButtons) {
    final last = _lastPress;
    if (last != null &&
        event.timeStamp - last.at < kDoubleTapTimeout &&
        (event.position - last.where).distance < kDoubleTapSlop) {
      _lastPress = null;
      _ask('maximize');
      return;
    }
    _lastPress = (at: event.timeStamp, where: event.position);
  }
  _ask('drag');
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
  const TitleBarSpace({
    super.key,
    required this.covered,
    this.navigator,
    required this.child,
  });

  final bool Function() covered;

  /// The app's navigator, which the Help menu and what it opens are shown
  /// on: the window buttons sit above it, outside its overlay.
  final GlobalKey<NavigatorState>? navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!drawsInTitleBar) return child;
    return ValueListenableBuilder(
      valueListenable: titleBar,
      builder: (context, measured, _) {
        final bar = drawsWindowButtons
            ? (inset: 0.0, height: windowButtonsHeight)
            : measured;
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
            // Over every page, the tabs included, so the window can be
            // closed whatever covers them.
            if (drawsWindowButtons)
              Positioned(
                top: 0,
                right: 0,
                child: WindowButtons(navigator: navigator),
              ),
          ],
        );
      },
    );
  }
}

/// Help, minimize, maximize or restore, and close, at the window's top
/// right on Windows and Linux, where the runner draws no title bar.
class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key, this.navigator});

  /// See [TitleBarSpace.navigator].
  final GlobalKey<NavigatorState>? navigator;

  /// The room they take, which the tab strip leaves them.
  static const width = _help + 3 * _button;
  static const _button = 46.0;
  static const _help = 40.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: windowButtonsHeight,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The native Help menu's one item: the menu bar it sat in went with
        // the title bar.
        Builder(
          builder: (context) => _WindowButton(
            width: _help,
            icon: Icons.more_horiz,
            label: 'Help',
            onTap: () {
              // A context under the navigator's overlay, which the menu, the
              // dialog and the toasts are shown in.
              BuildContext? shown;
              void look(Element element) {
                if (shown != null) return;
                if (Overlay.maybeOf(element) != null) {
                  shown = element;
                } else {
                  element.visitChildren(look);
                }
              }

              navigator?.currentState?.overlay?.context.visitChildElements(
                look,
              );
              final inside = shown;
              if (inside == null) return;
              final box = context.findRenderObject()! as RenderBox;
              showActionsAt(
                inside,
                box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                [
                  TuiMenuItem(
                    value: () => checkForUpdates(inside),
                    label: 'Check for updates…',
                  ),
                ],
              );
            },
          ),
        ),
        _WindowButton(
          icon: Icons.remove,
          label: 'Minimize',
          onTap: () => _ask('minimize'),
        ),
        ValueListenableBuilder(
          valueListenable: windowMaximized,
          builder: (context, maximized, _) => _MaximizeButton(
            child: _WindowButton(
              icon: maximized ? Icons.filter_none : Icons.crop_square,
              iconSize: maximized ? 13 : 15,
              label: maximized ? 'Restore' : 'Maximize',
              hover: _maximizeHover,
              onTap: () => _ask('maximize'),
            ),
          ),
        ),
        _WindowButton(
          icon: Icons.close,
          label: 'Close',
          danger: true,
          onTap: () => _ask('close'),
        ),
      ],
    ),
  );
}

/// Tells Windows where the maximize button is, in the view's physical
/// pixels, whenever it may have moved: the runner answers that spot as the
/// window's own maximize button, for the snap layouts. Linux needs nothing.
class _MaximizeButton extends StatelessWidget {
  const _MaximizeButton({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    // Built again as the window resizes, the button moving with its edge.
    MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final sent = [
        for (final edge in [rect.left, rect.top, rect.right, rect.bottom])
          (edge * ratio).roundToDouble(),
      ];
      _ask('maximizeButton', sent);
    });
    return child;
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.width = WindowButtons._button,
    this.iconSize = 15,
    this.danger = false,
    this.hover,
  });

  final IconData icon;
  final double iconSize;
  final String label;
  final VoidCallback onTap;
  final double width;

  /// Red on hover, as Windows' close button is.
  final bool danger;

  /// Hover as the runner says it, where the pointer never reaches Flutter.
  final ValueListenable<bool>? hover;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    Widget look(bool hover) => Container(
      width: widget.width,
      height: windowButtonsHeight,
      alignment: Alignment.center,
      color: hover
          // Windows 10's own close red, which a close button is expected to be.
          ? (widget.danger ? const Color(0xFFE81123) : p.selection)
          : Colors.transparent,
      child: Icon(
        widget.icon,
        size: widget.iconSize,
        color: hover && widget.danger ? Colors.white : p.muted,
      ),
    );
    final hover = widget.hover;
    // Named, with no tooltip: a tooltip wants an overlay, and these sit
    // above the navigator's.
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: hover == null
              ? look(_hover)
              : ValueListenableBuilder(
                  valueListenable: hover,
                  builder: (context, over, _) => look(_hover || over),
                ),
        ),
      ),
    );
  }
}
