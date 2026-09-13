import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// What a toast is about — info, success, warning or error — which picks its
/// icon, and how long it stays. The package's own, so there is no second list
/// to keep in step with it.
export 'package:toastification/toastification.dart' show ToastificationType;

/// How long a toast stays unless its caller says otherwise: a second, enough
/// to take in one line in passing.
const toastDuration = Duration(seconds: 1);

/// How long an error stays unless its caller says otherwise: time to read
/// what went wrong, and to reach for a way round it, like Save with sudo.
const _errorDuration = Duration(seconds: 5);

/// The package's settings, for the wrapper around the app (`SshboxApp`).
///
/// Three toasts at most, so a fourth pushes the oldest out rather than
/// reaching down over the shell. They stack in the middle four fifths of the
/// window, which is as wide as a long message gets before it wraps: the
/// package's own fixed 400 would cut one short on a tablet, and the edges
/// stay free to tap.
const toastConfig = ToastificationConfig(
  maxToastLimit: 3,
  itemWidth: double.infinity,
  marginBuilder: _column,
);

/// A tenth of the window either side, from the window as it is now, so a
/// tablet turned on its side gets its own.
EdgeInsetsGeometry _column(BuildContext context, AlignmentGeometry _) {
  final side = MediaQuery.sizeOf(context).width / 10;
  return EdgeInsets.fromLTRB(side, 12, side, 0);
}

/// The toasts still counting down, by what they say.
final _showing = <String, ToastificationItem>{};

/// Says something in passing: a [ToastCard] that slides in at the top of the
/// screen, under the status bar, with the time it has left running out along
/// its bottom. It goes by itself after [duration]: a second, or five for an
/// error. A touch holds it, and a swipe or its × sends it away sooner.
///
/// Every message the app shows goes through here, never a snack bar, which
/// would come up at the other end of the screen. Toasts stack rather than
/// queue, so a burst of them is on screen at once instead of each waiting its
/// turn, three at most (see [toastConfig]). One that says the same as a toast
/// still counting down adds nothing: following, every folder tapped while
/// `claude` runs is refused in the same words.
///
/// [action] puts a button on it, the way a snack bar's does, and pressing it
/// closes the toast.
///
/// A [message] of more than one line is a heading and what it is about: the
/// first line goes on top, and the rest under it in lighter type — tailscale's
/// own words for a refused forward, say.
///
/// The one way into the toast package: only the wrapper around the app talks
/// to it besides.
void showToast(
  BuildContext context,
  String message, {
  ToastificationType type = ToastificationType.info,
  ({String label, VoidCallback onPressed})? action,
  Duration? duration,
}) {
  _showing.removeWhere((_, toast) => !toast.isRunning);
  if (_showing.containsKey(message)) return;

  _showing[message] = toastification.showCustom(
    context: context,
    // The top of the screen, not of whatever overlay the caller sits in: the
    // root navigator's, which the navigator's own context finds too, for a
    // message that comes from no page.
    overlayState: Navigator.of(context, rootNavigator: true).overlay,
    alignment: Alignment.topCenter,
    autoCloseDuration:
        duration ??
        (type == ToastificationType.error ? _errorDuration : toastDuration),
    builder: (context, item) =>
        ToastCard(item: item, message: message, type: type, action: action),
  );
}

/// What [showToast] puts on screen: a card in the theme's own surface and
/// ink, light or dark as the terminal is, whatever it is about. Its [type]
/// shows only as an icon, in the same ink as the words: never as a colour,
/// and never as a word of its own.
///
/// As wide as what it says, up to the column [toastConfig] gives it; a longer
/// message wraps there rather than being cut off.
///
/// Public so a test can tell a toast, and what it is about, from the rest of
/// the screen.
class ToastCard extends StatelessWidget {
  const ToastCard({
    super.key,
    required this.item,
    required this.message,
    required this.type,
    this.action,
  });

  final ToastificationItem item;
  final String message;
  final ToastificationType type;
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = scheme.onSurface;
    final [heading, ...rest] = message.split('\n');
    final action = this.action;
    void close() => toastification.dismiss(item);

    // The package's own handling around it: a swipe sends it away, and a
    // pointer resting on it holds it.
    return BuiltInContainer(
      item: item,
      margin: const EdgeInsets.symmetric(vertical: 4),
      closeOnClick: false,
      pauseOnHover: true,
      dragToClose: true,
      callbacks: const ToastificationCallbacks(),
      child: Center(
        child: Material(
          color: scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          // As wide as the row of what it says, with the countdown laid along
          // the bottom of whatever width that came to.
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icon(type), color: ink),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            heading,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: ink,
                            ),
                          ),
                          if (rest.isNotEmpty)
                            Text(
                              rest.join('\n'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: ink.withValues(alpha: .8),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (action != null)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: ink),
                        onPressed: () {
                          close();
                          action.onPressed();
                        },
                        child: Text(action.label),
                      ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: close,
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: ink.withValues(alpha: .6),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ToastTimerAnimationBuilder(
                  item: item,
                  builder: (context, elapsed, child) => FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1 - elapsed,
                    child: SizedBox(
                      height: 2,
                      child: ColoredBox(color: ink.withValues(alpha: .3)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The icon that says what a toast is about, in place of the package's
/// colour-coded set.
IconData _icon(ToastificationType type) => switch (type) {
  ToastificationType.success => Icons.check_circle_outline,
  ToastificationType.warning => Icons.warning_amber_rounded,
  ToastificationType.error => Icons.error_outline,
  // Info, and any kind the package may yet add.
  _ => Icons.info_outline,
};
