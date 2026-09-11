import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// What a toast is about — info, success, warning or error — which picks its
/// colour and its icon. The package's own, so there is no second list to keep
/// in step with it.
export 'package:toastification/toastification.dart' show ToastificationType;

/// How long a toast stays unless its caller says otherwise: a second, enough
/// to take in one line in passing.
const toastDuration = Duration(seconds: 1);

/// The toasts still counting down, by what they say.
final _showing = <String, ToastificationItem>{};

/// Says something in passing: a card in [type]'s colour and icon that slides
/// in at the top of the screen, under the status bar, with the time it has
/// left running out along its bottom. It goes by itself after [duration]; a
/// touch holds it, and a swipe or its × sends it away sooner.
///
/// For a remark that wants no answer, where a snack bar would be too much.
/// Toasts stack rather than queue, so a burst of them is on screen at once
/// instead of each waiting its turn, and the app keeps at most three (see
/// `SshboxApp`). One that says the same as a toast still counting down adds
/// nothing: following, every folder tapped while `claude` runs is refused in
/// the same words.
///
/// [action] puts a button on it, the way a snack bar's does, and pressing it
/// closes the toast.
///
/// A [message] of more than one line is a heading and what it is about: the
/// first line is the title and the rest goes under it, in lighter type. The
/// package cuts a title at two lines, and a reason — tailscale's own words
/// for a refused forward, which run to three — needs all of its own.
///
/// The one way into the toast package: only the wrapper around the app talks
/// to it besides.
void showToast(
  BuildContext context,
  String message, {
  ToastificationType type = ToastificationType.info,
  ({String label, VoidCallback onPressed})? action,
  Duration duration = toastDuration,
}) {
  _showing.removeWhere((_, toast) => !toast.isRunning);
  if (_showing.containsKey(message)) return;

  final [heading, ...rest] = message.split('\n');
  late final ToastificationItem toast;
  toast = _showing[message] = toastification.show(
    context: context,
    // The top of the screen, not of whatever overlay the caller sits in.
    overlayState: Overlay.of(context, rootOverlay: true),
    alignment: Alignment.topCenter,
    // Type colour and white whatever the theme, so it reads the same on a
    // light screen as on this dark one.
    style: ToastificationStyle.fillColored,
    type: type,
    autoCloseDuration: duration,
    showProgressBar: true,
    title: action == null
        ? Text(heading)
        : Row(
            children: [
              Expanded(child: Text(heading)),
              TextButton(
                // The filled style's own white, on the toast's colour.
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () {
                  toastification.dismiss(toast);
                  action.onPressed();
                },
                child: Text(action.label),
              ),
            ],
          ),
    description: rest.isEmpty ? null : Text(rest.join('\n')),
  );
}
