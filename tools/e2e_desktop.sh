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

tests=${E2E_TESTS:-integration_test/desktop_smoke_test.dart}

# A run narrowed to some tests, or the no-portal one, is that run alone:
# the window phases follow only a whole run.
phases=1
[ -n "${JEANSH_E2E_NO_PORTAL:-}" ] && phases=
[ -n "${E2E_TESTS:-}" ] && phases=
# One share of the tests (JEANSH_E2E_SHARD=i/n): the window phases follow
# share 0 alone, so a split run still has them once.
case "${JEANSH_E2E_SHARD:-0/1}" in 0/*) ;; *) phases= ;; esac
for arg in "$@"; do
  case "$arg" in --plain-name* | --name* | -n) phases= ;; esac
done
export JEANSH_E2E_PHASES=$phases

# integration_test/window_place_test.dart, once a phase, each a fresh start
# of the app on the same data folder: the window is moved, comes back,
# maximized comes back, and a rectangle saved off every screen comes back on
# the one there is — that last one written here, between runs, where the app
# keeps it. Nothing of a Jeansh used on this machine is touched: Linux runs in
# the run's own data folder (below), Windows in a throwaway %APPDATA%, and on
# a Mac the two keys the window keeps are put back as they were. The
# arguments given to this script are the smoke tests' alone.
window_phases() {
  local target=$1 rc=0 data=""
  if [ "$target" = windows ]; then
    data=$(mktemp -d)
    mkdir -p "$data/cloud.brata/Jeansh"
  fi
  local domain=dev.triasbrata.sshbox frame='NSWindow Frame Jeansh'
  local full=JeanshWindowFullScreen kept_frame="" kept_full=""
  if [ "$target" = macos ]; then
    kept_frame=$(defaults read "$domain" "$frame" 2>/dev/null) || kept_frame=""
    kept_full=$(defaults read "$domain" "$full" 2>/dev/null) || kept_full=""
    defaults delete "$domain" "$frame" 2>/dev/null || true
    defaults delete "$domain" "$full" 2>/dev/null || true
  fi
  for phase in move restore maximized offscreen; do
    if [ "$phase" = offscreen ]; then
      case "$target" in
        linux) printf '%s\n' '-5000 -5000 760 520 0 0' \
                 >"$XDG_DATA_HOME/cloud.brata.terminal/window.txt" ;;
        windows) printf '%s\n' '-6000 -6000 -5240 -5480 0' \
                   >"$data/cloud.brata/Jeansh/window.txt" ;;
        macos) defaults write "$domain" "$frame" \
                 '-6000 -6000 760 520 0 0 1440 900 ' ;;
      esac
    fi
    if [ "$target" = windows ]; then
      APPDATA=$(cygpath -w "$data") flutter test \
        integration_test/window_place_test.dart -d windows \
        --dart-define=JEANSH_E2E_WINDOW=$phase || { rc=1; break; }
    else
      flutter test integration_test/window_place_test.dart -d "$target" \
        --dart-define=JEANSH_E2E_WINDOW=$phase || { rc=1; break; }
    fi
  done
  if [ "$target" = macos ]; then
    defaults delete "$domain" "$frame" 2>/dev/null || true
    defaults delete "$domain" "$full" 2>/dev/null || true
    [ -n "$kept_frame" ] && defaults write "$domain" "$frame" "$kept_frame"
    [ -n "$kept_full" ] && defaults write "$domain" "$full" -bool "$kept_full"
  fi
  [ -n "$data" ] && rm -rf "$data"
  return $rc
}

# integration_test/multi_window_phases_test.dart, several windows (#344): a
# phase a fresh start of the app on a data folder of its own, under a window
# manager. The last phase ends with the app quitting, since its last window
# closes, so flutter test is expected to fail there: what it must have seen
# is written to a file by the test and by a watcher that outlives it, and
# read here.
mw_phases() {
  local rc=0 data note
  data=$(mktemp -d)
  note="$data/jeansh-e2e-mw-last.txt"
  for phase in ${E2E_MW_PHASES:-t1 t2 t3 t4 save restore buttons churn drop last}; do
    echo "experiment: ${JEANSH_WIN_EXPERIMENT:-control} phase: $phase"
    # A drag between windows is run with no window manager, as the smoke
    # tests' file drops are: under openbox the same drag reached no window.
    if [ "$phase" = drop ] && [ -n "${MW_WM_PID:-}" ]; then
      kill "$MW_WM_PID" 2>/dev/null
      MW_WM_PID=
      sleep 1
    fi
    if [ "$phase" = last ]; then
      JEANSH_E2E_MW_DIR=$data XDG_DATA_HOME=$data timeout 240 flutter test \
        integration_test/multi_window_phases_test.dart -d linux \
        --dart-define=JEANSH_E2E_MWINDOW=$phase 2>&1 | tee "$data/last.log" || true
      # The process is gone when the test never got to write "windows left"
      # (3 s after the click) or the watcher saw it end; and no question.
      if grep -q ready "$note" 2>/dev/null && ! grep -q asked "$note" &&
        { grep -q ended "$note" || ! grep -q 'windows left' "$note"; }; then
        echo "✅ multi-window: the last window closed with no question and the process ended"
      else
        echo "❌ multi-window: the last window: $(cat "$note" 2>/dev/null | tr '\n' ' ')"
        echo "trace: $(cat "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null | tr '\n' ' ')"
        echo "--- the last phase's output, its tail:"
        tail -n 80 "$data/last.log"
        rc=1
      fi
    elif [ "$phase" = bisect ]; then
      JEANSH_E2E_MW_DIR=$data XDG_DATA_HOME=$data timeout 240 flutter test \
        integration_test/multi_window_phases_test.dart -d linux \
        --dart-define=JEANSH_E2E_MWINDOW=$phase 2>&1 | tee "$data/bisect.log" || true
      echo "BISECT RESULT: $(grep -a bisect "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null | tr '\n' ' ')"
      if [ -n "$BISECT_LOG" ]; then
        echo "--- the jeansh: lines of the app's stderr, in order:"
        grep -a "jeansh:" "$data/bisect.log" | tail -n 600
        echo "--- the last 60 lines of the output:"
        tail -n 60 "$data/bisect.log"
      fi
      rm -f "$data/jeansh-e2e-mw-trace.txt"
    elif [ "$phase" = churn ]; then
      # The app's stderr is in flutter test's output, kept to be read for a
      # crash line.
      JEANSH_E2E_MW_DIR=$data XDG_DATA_HOME=$data timeout 400 flutter test \
        integration_test/multi_window_phases_test.dart -d linux \
        --dart-define=JEANSH_E2E_MWINDOW=$phase 2>&1 | tee "$data/churn.log" || true
      rounds=$(grep -c 'churn round' "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null)
      crashes=$(grep -ciE 'segmentation|signal 11|core dumped|CRITICAL|Lost connection' "$data/churn.log")
      if [ "$rounds" = 10 ] && [ "$crashes" = 0 ]; then
        echo "✅ multi-window: 10 of 10 A+B+C rounds, no quit, no crash line in stderr"
      else
        echo "❌ multi-window: $rounds of 10 A+B+C rounds, $crashes crash lines"
        echo "trace: $(cat "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null | tr '\n' ' ' | tail -c 6000)"
        rc=1
      fi
    else
      # The first four checks are independent: a data folder each, so one
      # that fails leaves no window behind for the next.
      case "$phase" in
        t[1-4] | drop) home=$(mktemp -d) ;;
        *) home=$data ;;
      esac
      JEANSH_E2E_MW_DIR=$data XDG_DATA_HOME=$home flutter test \
        integration_test/multi_window_phases_test.dart -d linux \
        --dart-define=JEANSH_E2E_MWINDOW=$phase || {
          rc=1
          echo "trace: $(cat "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null | tr '\n' ' ')"
        }
    fi
  done
  rm -rf "$data"
  return $rc
}

if [ "$target" = mw-phases ]; then
  openbox >/dev/null 2>&1 &
  wm=$!
  MW_WM_PID=$wm
  sleep 1
  rc=0
  mw_phases || rc=1
  kill $wm 2>/dev/null
  exit $rc
fi

# The several-windows phases on Windows (#344), the ones that prove the
# Windows runner's own windows: the key that opens one, the close button of
# each, the first closing while another stays, and the windows coming back
# after a restart. Win32 calls from the app's own process (integration_test/
# win_desk.dart) press the keys and click; no window manager here, no
# maximize or minimize, no file drag. A data folder (APPDATA) a phase for the
# independent ones, one for the phases that follow each other.
mw_phases_windows() {
  local rc=0 data home note phase rounds flutter_rc
  data=$(mktemp -d)
  note="$data/jeansh-e2e-mw-last.txt"
  for phase in ${E2E_MW_PHASES:-t1 t2 t3 t4 save restore churn last}; do
    echo "experiment: windows phase: $phase"
    case "$phase" in
      t[1-4]) home=$(mktemp -d) ;;
      *) home=$data ;;
    esac
    JEANSH_E2E_MW_DIR=$(cygpath -m "$data") APPDATA=$(cygpath -w "$home") \
      timeout 400 flutter test integration_test/multi_window_phases_test.dart \
      -d windows --dart-define=JEANSH_E2E_MWINDOW=$phase 2>&1 | tee "$data/$phase.log"
    flutter_rc=${PIPESTATUS[0]}
    case "$phase" in
      last)
        if grep -q ready "$note" 2>/dev/null && ! grep -q asked "$note" &&
          { grep -q ended "$note" || ! grep -q 'windows left' "$note"; }; then
          echo "✅ multi-window: the last window closed with no question and the process ended"
        else
          echo "❌ multi-window: the last window: $(tr '\n' ' ' <"$note" 2>/dev/null)"
          echo "trace: $(tr '\n' ' ' <"$data/jeansh-e2e-mw-trace.txt" 2>/dev/null)"
          rc=1
        fi ;;
      churn)
        rounds=$(grep -c 'churn round' "$data/jeansh-e2e-mw-trace.txt" 2>/dev/null)
        if [ "$rounds" = 10 ]; then
          echo "✅ multi-window: 10 of 10 A+B+C rounds, no quit"
        else
          echo "❌ multi-window: $rounds of 10 A+B+C rounds"
          echo "trace: $(tr '\n' ' ' <"$data/jeansh-e2e-mw-trace.txt" 2>/dev/null | tail -c 6000)"
          rc=1
        fi ;;
      *)
        if [ "$flutter_rc" != 0 ]; then
          rc=1
          echo "trace: $(tr '\n' ' ' <"$data/jeansh-e2e-mw-trace.txt" 2>/dev/null)"
        fi ;;
    esac
  done
  rm -rf "$data"
  return $rc
}

# The Linux run's second half, inside its Xvfb (below), with a window
# manager to maximize under, there from the start as on a desktop.
if [ "$target" = window-phases ]; then
  openbox >/dev/null 2>&1 &
  wm=$!
  sleep 1
  rc=0
  window_phases linux || rc=1
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
    #
    # JEANSH_E2E_NO_PORTAL=1 leaves every XDG portal off that bus, as on a
    # desktop that runs none: the bus offers the services the machine has,
    # less each *portal* one, so nothing can start one.
    bus=()
    if [ -n "${JEANSH_E2E_NO_PORTAL:-}" ]; then
      services=$(mktemp -d)
      for service in /usr/share/dbus-1/services/*.service; do
        case "$service" in *portal*) ;; *) ln -s "$service" "$services/" ;; esac
      done
      config=$(mktemp)
      sed "s#<standard_session_servicedirs */>#<servicedir>$services</servicedir>#" \
        /usr/share/dbus-1/session.conf > "$config"
      bus=(--config-file="$config")
    fi
    # Not exec when a no-portal bus was made, so its files go with the run.
    if [ -n "${JEANSH_E2E_NO_PORTAL:-}" ]; then
      trap 'rm -rf "$services" "$config"' EXIT
      run=
    else
      run=exec
    fi
    $run xvfb-run -a --server-args="-screen 0 1280x900x24" \
      dbus-run-session "${bus[@]}" -- sh -c '
        unset WAYLAND_DISPLAY && export GDK_BACKEND=x11
        XDG_DATA_HOME=$(mktemp -d) && export XDG_DATA_HOME
        TMUX_TMPDIR=$XDG_DATA_HOME && export TMUX_TMPDIR
        unset TMUX TMUX_PANE
        trap "kill \$notifier 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf \"$XDG_DATA_HOME\"" EXIT
        # A throwaway password and a default keyring named login: with an
        # empty one the first secret written pops a prompt nobody sees, and
        # saving a host hangs for ever.
        mkdir -p "$XDG_DATA_HOME/keyrings" && printf login >"$XDG_DATA_HOME/keyrings/default"
        printf e2e | gnome-keyring-daemon --unlock --components=secrets >/dev/null
        dunst >/dev/null 2>&1 & notifier=$!
        tests=$1 && shift
        # E2E_MW_ONLY=1: the several-windows phases alone, no smoke run.
        [ -z "$E2E_MW_ONLY" ] || exec "$0" mw-phases
        rc=0
        flutter test "$tests" -d linux "$@" || rc=1
        # Only after a whole run, as above.
        [ -z "$JEANSH_E2E_PHASES" ] || "$0" window-phases || rc=1
        [ -z "$JEANSH_E2E_PHASES" ] || "$0" mw-phases || rc=1
        exit $rc' "$ROOT/tools/e2e_desktop.sh" "$tests" "$@"
    ;;
  windows | macos)
    # E2E_MW_ONLY=1: the several-windows phases alone, no smoke run.
    if [ -n "${E2E_MW_ONLY:-}" ] && [ "$target" = windows ]; then
      mw_phases_windows
      exit $?
    fi
    rc=0
    flutter test "$tests" -d "$target" "$@" || rc=1
    # Only after a whole run, as above.
    [ -z "$JEANSH_E2E_PHASES" ] || window_phases "$target" || rc=1
    [ -z "$JEANSH_E2E_PHASES" ] || [ "$target" != windows ] || mw_phases_windows || rc=1
    exit $rc
    ;;
  *)
    echo "Unknown target '$target'; expected linux, windows or macos" >&2
    exit 2
    ;;
esac
