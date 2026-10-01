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
#   tools/e2e_desktop.sh linux --plain-name 'a diff'   # the rest goes to
#                                   # flutter test, here to run one test
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
shift $(($# > 0 ? 1 : 0))

tests=integration_test/desktop_smoke_test.dart

# integration_test/window_place_test.dart, once a phase, each a fresh start
# of the app on the same data folder: the window is moved, comes back,
# maximized comes back, and a rectangle saved off every screen comes back on
# the one there is — that last one written here, between runs, where the app
# keeps it.
window_phases() {
  local target=$1 rc=0
  shift
  for phase in move restore maximized offscreen; do
    if [ "$phase" = offscreen ]; then
      case "$target" in
        linux) printf '%s\n' '-5000 -5000 760 520 0 0' \
                 >"$XDG_DATA_HOME/cloud.brata.terminal/window.txt" ;;
        windows) printf '%s\n' '-6000 -6000 -5240 -5480 0' \
                   >"$APPDATA/cloud.brata/Jeansh/window.txt" ;;
        macos) defaults write dev.triasbrata.sshbox 'NSWindow Frame Jeansh' \
                 '-6000 -6000 760 520 0 0 1440 900 ' ;;
      esac
    fi
    flutter test integration_test/window_place_test.dart -d "$target" \
      --dart-define=JEANSH_E2E_WINDOW=$phase "$@" || { rc=1; break; }
  done
  return $rc
}

# The Linux run's second half, inside its Xvfb (below), with a window
# manager to maximize under, there from the start as on a desktop.
if [ "$target" = window-phases ]; then
  openbox >/dev/null 2>&1 &
  wm=$!
  sleep 1
  rc=0
  window_phases linux "$@" || rc=1
  kill $wm
  exit $rc
fi

case "$target" in
  linux)
    for tool in xvfb-run dbus-run-session gnome-keyring-daemon dunst; do
      command -v "$tool" >/dev/null || {
        echo "$tool is missing. On Debian/Ubuntu:" >&2
        echo "  sudo apt-get install -y xvfb dbus-x11 gnome-keyring dunst" >&2
        exit 2
      }
    done
    # Its own D-Bus, because the app asks for notifications and for
    # org.freedesktop.secrets, where saved passwords live. And on that bus
    # what every desktop session has: a Secret Service, unlocked with an empty
    # password, and a notification server, dunst. Without them libsecret times
    # out and a transfer's notification fails, and either reads as an app bug
    # rather than a runner missing half a desktop.
    #
    # All in a data folder of the run's own, gone after it: the keyring's
    # files, the app's own preferences and saved tabs, and the tmux server a
    # Local shell starts, killed as the run ends. A run starts from a clean
    # app, as on CI, and never opens this machine's keyring, leaves a restored
    # tab behind for a Jeansh someone uses here, or touches their tmux.
    #
    # And only the virtual display. xvfb-run sets DISPLAY but leaves
    # WAYLAND_DISPLAY, and GTK tries Wayland first: on a machine with a
    # Wayland session — WSLg has one — the app drew on the real desktop and
    # copied to the real clipboard, which WSLg shares with Windows, over
    # whatever the user had copied.
    exec xvfb-run -a --server-args="-screen 0 1280x900x24" \
      dbus-run-session -- sh -c '
        unset WAYLAND_DISPLAY && export GDK_BACKEND=x11
        XDG_DATA_HOME=$(mktemp -d) && export XDG_DATA_HOME
        TMUX_TMPDIR=$XDG_DATA_HOME && export TMUX_TMPDIR
        unset TMUX TMUX_PANE
        trap "kill \$notifier 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf \"$XDG_DATA_HOME\"" EXIT
        printf "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
        dunst >/dev/null 2>&1 & notifier=$!
        tests=$1 && shift
        rc=0
        flutter test "$tests" -d linux "$@" || rc=1
        "$0" window-phases "$@" || rc=1
        exit $rc' "$ROOT/tools/e2e_desktop.sh" "$tests" "$@"
    ;;
  windows | macos)
    rc=0
    flutter test "$tests" -d "$target" "$@" || rc=1
    window_phases "$target" "$@" || rc=1
    exit $rc
    ;;
  *)
    echo "Unknown target '$target'; expected linux, windows or macos" >&2
    exit 2
    ;;
esac
