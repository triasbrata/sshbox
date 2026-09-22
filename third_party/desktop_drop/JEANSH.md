# desktop_drop 0.8.4, without Android

Copied from pub.dev's desktop_drop 0.8.4 (Apache-2.0, mixin.dev) with one
change: `android` is gone from `flutter.plugin.platforms` in pubspec.yaml,
and with it the android/ folder. example/ was left out as bulk.

Why: Jeansh uses it for files dropped from the OS file manager onto a
terminal on macOS, Windows and Linux. Its Android half, registered in every
build whether a DropTarget is on screen or not, sets a drag listener on the
activity's content view that accepts every drag, and dereferences the
activity with `!!` on a drop. Android is meant to be unchanged by this, so it
does not get the plugin at all.

To move to a newer version, copy it here the same way and take `android` out
of its pubspec again.
