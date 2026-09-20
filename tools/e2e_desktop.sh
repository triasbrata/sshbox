#!/usr/bin/env bash
# Runs integration_test/ against the real desktop app, natively and unattended.
#
# One script, three platforms, because each is headless in a different way:
#
#   Linux    a virtual framebuffer, so genuinely no display at all
#   Windows  a window in the runner's own session that nobody looks at
#   macOS    the same
#
# Only Linux is headless in the strict sense. Saying otherwise would be a lie
# a CI log would eventually tell on.
#
#   tools/e2e_desktop.sh            # this machine's platform
#   tools/e2e_desktop.sh linux      # or windows, macos
#
# Exits non-zero if any test fails, which is what a release gate reads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

target="${1:-}"
if [ -z "$target" ]; then
  case "$(uname -s)" in
    Linux) target=linux ;;
    Darwin) target=macos ;;
    MINGW* | MSYS* | CYGWIN*) target=windows ;;
    *) echo "Unknown platform $(uname -s); pass linux, windows or macos" >&2
       exit 2 ;;
  esac
fi

tests=integration_test

case "$target" in
  linux)
    for tool in xvfb-run dbus-run-session; do
      command -v "$tool" >/dev/null || {
        echo "$tool is missing. On Debian/Ubuntu:" >&2
        echo "  sudo apt-get install -y xvfb dbus-x11" >&2
        exit 2
      }
    done
    # Its own D-Bus, because the app asks for org.freedesktop.secrets (saved
    # passwords) and for notifications. Without a bus those calls fail in ways
    # that read as app bugs rather than as a runner with no session.
    exec xvfb-run -a --server-args="-screen 0 1280x900x24" \
      dbus-run-session -- \
      flutter test "$tests" -d linux
    ;;
  windows)
    exec flutter test "$tests" -d windows
    ;;
  macos)
    exec flutter test "$tests" -d macos
    ;;
  *)
    echo "Unknown target '$target'; expected linux, windows or macos" >&2
    exit 2
    ;;
esac
