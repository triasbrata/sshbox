#!/usr/bin/env bash
# Tests tools/e2e_android.sh's flow(): its watch for a Maestro that falls
# silent, and its one retry of a run that hung before it did anything. Drives
# the real functions, taken out of the script, against a fake maestro, with a
# silence of 3 s. Runs anywhere, touching no device: bash
# tools/test_e2e_flow_watch.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# flow, only_app_lifecycle, maestro_watched and stop_tailer, as they are.
grep '^FLOW_SILENCE=' "$ROOT/tools/e2e_android.sh" >"$WORK/funcs.sh"
for f in flow only_app_lifecycle maestro_watched stop_tailer; do
  sed -n "/^$f() {/,/^}/p" "$ROOT/tools/e2e_android.sh" >>"$WORK/funcs.sh"
done

# The fake: each run takes the next line of $WORK/script, a mode, and counts
# itself in $WORK/runs. Modes:
#   pass        two steps, exits 0
#   fail        a step fails, exits 1
#   hang_launch stops the app, starts the launch, never ends
#   hang_late   stops and launches the app, taps, then never ends
mkdir -p "$WORK/bin"
cat >"$WORK/bin/maestro" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$WORK/runs" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$WORK/runs"
mode=$(sed -n "${n}p" "$WORK/script")
echo " > Flow e2e"
case $mode in
  pass) echo '  Stop cloud.brata.terminal... COMPLETED'
        echo '  Launch app "cloud.brata.terminal"... COMPLETED' ;;
  fail) echo '  Assert that "x" is visible... FAILED'; exit 1 ;;
  hang_launch) echo '  Stop cloud.brata.terminal... COMPLETED'
               printf '  Launch app "cloud.brata.terminal"...'
               exec sleep 6007 ;;
  hang_late) echo '  Stop cloud.brata.terminal... COMPLETED'
             echo '  Launch app "cloud.brata.terminal"... COMPLETED'
             echo '  Tap on "Send"... COMPLETED'
             printf '  Assert that "x" is visible...'
             exec sleep 6007 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/maestro"
export WORK PATH="$WORK/bin:$PATH"

failures=0
# case NAME WANT_RC WANT_RUNS WANT_TEXT MODES...
case_() {
  local name=$1 want_rc=$2 want_runs=$3 want_text=$4 rc runs out
  shift 4
  printf '%s\n' "$@" >"$WORK/script"
  rm -f "$WORK/runs"
  out=$(
    # shellcheck source=/dev/null
    source "$WORK/funcs.sh"
    FLOW_SILENCE=3
    maestro_env=()
    flow e2e 2>&1
    echo "rc=$?"
  )
  rc=${out##*rc=}
  runs=$(cat "$WORK/runs")
  if [ "$rc" = "$want_rc" ] && [ "$runs" = "$want_runs" ] &&
    { [ -z "$want_text" ] || grep -qF -- "$want_text" <<<"$out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc $rc (want $want_rc), runs $runs (want $want_runs)"
    echo "$out" | sed 's/^/     /'
    failures=$((failures + 1))
  fi
  # Nothing of a killed run is left behind.
  if pgrep -xf "sleep 6007" >/dev/null; then
    echo "FAIL $name: a maestro is still running"
    failures=$((failures + 1))
  fi
}

case_ 'a run that passes passes, once, its output shown' 0 1 'Launch app "cloud.brata.terminal"... COMPLETED' pass
case_ 'a run that fails fails, not retried' 1 1 'FAILED' fail
case_ 'a hang at launch is killed and run once more, which passes' 0 2 \
  'Maestro printed nothing for 3 s, at:   Launch app "cloud.brata.terminal"...' hang_launch pass
case_ 'a hang at launch twice fails, after two runs' 1 2 'once more' hang_launch hang_launch
case_ 'a hang after the flow did something fails, not retried' 1 1 \
  'at:   Assert that "x" is visible...' hang_late pass
case_ 'a hang at launch, then a failure, fails' 1 2 'once more' hang_launch fail

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "every case passed"
