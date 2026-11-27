#!/usr/bin/env bash
# Whether the FlutterMacOS framework in a built Jeansh.app still has the
# engine call the app's several windows are made with.
#
# `FlutterEngine.enableMultiView` and `addViewController:` are not in
# FlutterMacOS's public headers. The runner asks for them only where the
# engine answers to the selector (Windows.makeEngine in MainFlutterWindow.swift),
# so a Flutter without them leaves the app one window and ⌘N not offered —
# nothing crashes. This script is the canary: it fails when that has
# happened, so a Flutter upgrade that drops the call is noticed here and not
# by a user who finds ⌘N gone.
#
#   tools/check_macos_multiview.sh build/macos/Build/Products/Debug/Jeansh.app
set -euo pipefail

app="${1:?usage: $0 path/to/Jeansh.app}"
binary="$app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
[ -f "$binary" ] || { echo "no FlutterMacOS binary at $binary" >&2; exit 2; }

# Once, into a variable: grep -q ends early and would kill strings with
# SIGPIPE, which pipefail reads as a miss.
names="$(strings "$binary")"
missing=0
for selector in enableMultiView addViewController:; do
  if grep -qxF "$selector" <<<"$names"; then
    echo "ok: $selector"
  else
    echo "MISSING: $selector" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "This Flutter has no several-views call for macOS: the app stays single-window." >&2
  exit 1
fi
