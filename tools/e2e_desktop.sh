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
    for tool in xvfb-run dbus-run-session gnome-keyring-daemon; do
      command -v "$tool" >/dev/null || {
        echo "$tool is missing. On Debian/Ubuntu:" >&2
        echo "  sudo apt-get install -y xvfb dbus-x11 gnome-keyring" >&2
        exit 2
      }
    done
    # Its own D-Bus, because the app asks for notifications and for
    # org.freedesktop.secrets, where saved passwords live. And on that bus a
    # Secret Service, as every desktop session has: without one, libsecret
    # times out, and what fails reads as an app bug rather than a runner
    # missing its keyring. Unlocked with an empty password.
    #
    # Both in a data folder of the run's own, gone after it: the keyring's
    # files, and the app's own preferences and saved tabs. A run starts from a
    # clean app, as on CI, and never opens this machine's keyring or leaves a
    # restored tab behind for a Jeansh someone uses here.
    exec xvfb-run -a --server-args="-screen 0 1280x900x24" \
      dbus-run-session -- sh -c '
        XDG_DATA_HOME=$(mktemp -d) && export XDG_DATA_HOME
        trap "rm -rf \"$XDG_DATA_HOME\"" EXIT
        printf "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
        flutter test "$1" -d linux' sh "$tests"
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
