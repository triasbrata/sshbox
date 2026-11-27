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

## Several windows

A second change, for the app's several windows on one engine:

- macOS: with the engine's views on, the registrar has no view, so the
  plugin no longer looks for one only. `DesktopDropPlugin.attach(to:)` puts
  a drop target on a window's Flutter view, and the app calls it for each
  window; its events say which view they are for with a "view" call before
  each one.
- Dart: `DesktopDrop.eventView` holds that view (0 where the platform does not
  say: Linux and Windows attach to the first window's view alone), and a
  `DropTarget` ignores an event for a view it is not in, so a file dropped on
  one window is not handed to the targets of another.
