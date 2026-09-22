#!/usr/bin/env bash
# Crashes a real sentry-cocoa, started by apple/NativeCrashes.swift exactly as
# the Runner starts it, and holds what reaches a stand-in for Sentry to the
# allowlist: first with no beforeSend, the way sentry_flutter used to start it,
# to show what leaks and that the check sees it, then with the scrub.
#
# Needs a Mac and the Sentry.xcframework a macOS build fetches:
#   fvm flutter build macos --debug && tools/check_apple_crash_scrub.sh
# Nothing is sent anywhere but 127.0.0.1, and nothing is left but build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCF="$ROOT/build/macos/SourcePackages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework/macos-arm64_arm64e_x86_64"
[ -d "$XCF" ] || { echo "no $XCF: run fvm flutter build macos --debug first" >&2; exit 1; }
WORK="$ROOT/build/apple_crash_scrub"
rm -rf "$WORK" && mkdir -p "$WORK"

# An Info.plist in the binary, so the release and dist come out as the app's.
cat >"$WORK/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>cloud.brata.terminal</string>
  <key>CFBundleShortVersionString</key><string>1.0.79</string>
  <key>CFBundleVersion</key><string>83</string>
</dict></plist>
EOF
xcrun swiftc -O -F "$XCF" -framework Sentry -lc++ -lz \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$WORK/Info.plist" \
  "$ROOT/apple/NativeCrashes.swift" "$ROOT/tools/apple_crash_scrub/main.swift" \
  -o "$WORK/check"

PORT=$((20000 + RANDOM % 20000))
DSN="http://public@127.0.0.1:$PORT/1"
python3 "$ROOT/tools/apple_crash_scrub/sink.py" serve "$PORT" "$WORK/sent" &
SINK=$!
trap 'kill $SINK 2>/dev/null' EXIT
sleep 1

status=0
for mode in raw scrubbed; do
  : >"$WORK/sent"
  cache="$WORK/cache-$mode"
  # Dies of EXC_BAD_ACCESS, as it should.
  "$WORK/check" crash "$DSN" "$cache" $mode 2>"$WORK/crash-$mode.log" || true
  "$WORK/check" send "$DSN" "$cache" $mode >"$WORK/send-$mode.log" 2>&1
  python3 "$ROOT/tools/apple_crash_scrub/sink.py" check "$WORK/sent" $mode || status=1
done
exit $status
