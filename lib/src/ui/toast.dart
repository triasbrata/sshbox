import 'dart:async';

import 'package:flutter/material.dart';

/// The toast on screen, if any, so the next one can take its place.
OverlayEntry? _toast;

/// Says something in passing: a line that fades in near the bottom of the
/// screen, stays about two seconds and fades out.
///
/// For a remark that wants no answer, where a snack bar would be too much. It
/// moves nothing and takes no touches, so the finger that caused it carries
/// on through it, and a new one replaces the one still showing rather than
/// waiting behind it.
void showToast(BuildContext context, String message) {
  _toast
    ?..remove()
    ..dispose();
  late final OverlayEntry entry;
  entry = _toast = OverlayEntry(
    builder: (context) => _Toast(
      message: message,
      onDone: () {
        // Replaced while it faded, and the one showing is not this one.
        if (_toast != entry) return;
        _toast = null;
        entry
          ..remove()
          ..dispose();
      },
    ),
  );
  Overlay.of(context).insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.onDone});

  final String message;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final Timer _hold;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    // Never finishes if the toast is replaced first: disposing stops both.
    _hold = Timer(const Duration(seconds: 2), () async {
      await _fade.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _hold.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    return Positioned(
      left: 24,
      right: 24,
      // Clear of the soft keyboard or the system bar, and of the 48dp key bar
      // that rides on top of them.
      bottom: media.viewInsets.bottom + media.padding.bottom + 64,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: Center(
            child: Material(
              color: theme.colorScheme.inverseSurface.withValues(alpha: 0.9),
              // Round as a chip on one line, and still tidy on two.
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
