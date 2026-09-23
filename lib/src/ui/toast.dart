import 'package:flutter/material.dart';

import 'termul/tui_toast.dart';

/// What a toast is about — info, success, warning or error — shown as
/// termul's glyph mark, never as a colour.
export 'termul/tui_toast.dart' show TuiToastType, TuiToastCard;

/// How long a toast stays unless its caller says otherwise: a second, enough
/// to take in one line in passing. Jeansh's, shorter than termul's three.
const toastDuration = Duration(seconds: 1);

/// Home's Add sits 24 from the bottom and is 30 tall: a toast placed low
/// leaves it, and a little air, uncovered.
const _clearOfButtons = 72.0;

/// The stacks the app's [ToastLayer] paints, at the top and low, while there
/// is one.
TuiToastController? _top;
TuiToastController? _low;

/// Where the app's toasts are drawn: termul's [TuiToastHost], twice — its own
/// stack at the top, and a second low one for a word that must not lie over
/// a page's header — each taking a touch only on a card.
///
/// Laid over the app's navigator by `SshboxApp`. Without one, as in a test of
/// a single page, toasts go to a host of their own in the root navigator's
/// overlay instead.
class ToastLayer extends StatefulWidget {
  const ToastLayer({super.key, required this.child});

  final Widget child;

  @override
  State<ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<ToastLayer> {
  final _topStack = TuiToastController();
  final _lowStack = TuiToastController();

  @override
  void initState() {
    super.initState();
    _top = _topStack;
    _low = _lowStack;
  }

  @override
  void dispose() {
    if (identical(_top, _topStack)) _top = null;
    if (identical(_low, _lowStack)) _low = null;
    _topStack.dispose();
    _lowStack.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _hosts(_topStack, _lowStack, widget.child);
}

Widget _hosts(TuiToastController top, TuiToastController low, Widget child) =>
    TuiToastHost(
      controller: top,
      child: TuiToastHost(
        controller: low,
        alignment: Alignment.bottomCenter,
        margin: const EdgeInsets.only(bottom: _clearOfButtons),
        child: child,
      ),
    );

/// The hosts put in an overlay with no [ToastLayer] over it, one per overlay.
final _fallback = Expando<(TuiToastController, TuiToastController)>();

(TuiToastController, TuiToastController) _stacksFor(BuildContext context) {
  final top = _top, low = _low;
  if (top != null && low != null) return (top, low);
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  return _fallback[overlay] ??= () {
    final stacks = (TuiToastController(), TuiToastController());
    overlay.insert(
      OverlayEntry(
        builder: (_) => _hosts(stacks.$1, stacks.$2, const SizedBox.expand()),
      ),
    );
    return stacks;
  }();
}

/// Says something in passing: termul's [TuiToastCard], sliding in at the top
/// of the screen with the time it has left running out along its bottom. It
/// goes by itself after [duration]: a second, or termul's five for an error.
/// A touch holds it, and a swipe or its × sends it away sooner.
///
/// Every message the app shows goes through here. Toasts stack rather than
/// queue, three at most, newest on top; one that says the same as a toast
/// still up adds nothing.
///
/// [action] puts a button on it, and pressing it closes the toast.
///
/// A [message] of more than one line is a heading and what it is about: the
/// first line goes on top, and the rest under it in muted type.
///
/// [low] puts it near the bottom instead, for a long word that must not lie
/// over a page's header and title.
void showToast(
  BuildContext context,
  String message, {
  TuiToastType type = TuiToastType.info,
  ({String label, VoidCallback onPressed})? action,
  Duration? duration,
  bool low = false,
}) {
  final (top, bottom) = _stacksFor(context);
  final [title, ...rest] = message.split('\n');
  (low ? bottom : top).show(
    title: title,
    body: rest.isEmpty ? null : rest.join('\n'),
    type: type,
    action: action == null
        ? null
        : TuiToastAction(label: action.label, onPressed: action.onPressed),
    duration:
        duration ??
        (type == TuiToastType.error ? tuiToastErrorDuration : toastDuration),
  );
}
