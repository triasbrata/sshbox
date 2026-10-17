# xterm2 5.2.0, with the wheel kept after a scroll position change

Copied from pub.dev's xterm2 5.2.0 (MIT, LICENSE beside this): lib/,
pubspec.yaml, LICENSE, README.md and CHANGELOG.md. Left out as bulk rather
than as a change: example/, media/, test/, tool/, script/ and bin/.

One change, in lib/src/ui/infinite_scroll_view.dart, `set position`: it now
moves `_onScroll` from the old ScrollPosition to the new one. 5.2.0 moved
`markNeedsLayout` instead, which `attach()` never added, so `_onScroll` stayed
on the old position.

Why (JEANSH-H): for a program that reads the mouse — Claude Code's fullscreen
view — xterm2 turns a scroll into wheel events through that `_onScroll`.
Flutter's Scrollable makes a new ScrollPosition whenever its dependencies
change, and they change when the terminal is moved in the tree: a tab page,
held by a GlobalKey, moves to another slot of the tabs' IndexedStack when a
tab before it opens or closes. From then on the wheel sent nothing, for as
long as the terminal lived, while PageUp still worked. Rebuilt from scratch
(leaving the alternate screen and coming back, a new tab) it worked again.

xterm2 5.3.0 has the same fix ("Keep application scrolling active when
Flutter replaces its scroll position") along with many other changes in how
keys and the mouse are encoded. Moving to 5.3.0 retires this copy: delete
third_party/xterm2 and its dependency_overrides entry together.
