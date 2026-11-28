#!/usr/bin/env bash
# lost_result in tools/e2e_desktop.sh accepts a non-zero phase only when it is
# the flutter_tools lost-result pattern AND the test wrote a new "done" line.
# A 2x2 and a mutation: the marker's check taken out must turn the negative
# cases red. Usage: tools/test_e2e_desktop_lost.sh [script]
set -u
cd "$(dirname "$0")/.."
script=${1:-tools/e2e_desktop.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/^lost_result() {/,/^}/p' "$script" >"$tmp/fn.sh"
# shellcheck disable=SC1091
. "$tmp/fn.sh"

err="unhandled error during finalization of test:
/x/integration_test/multi_window_phases_test.dart
PathNotFoundException: Deletion failed, path = '/tmp/flutter_tools.A/flutter_test_listener.B' (OS Error)"
fails=0
expect() { # NAME WANT(0 accepted | 1 refused) OUT DONE_NOW DONE_BEFORE
  printf '%s\n' "$3" >"$tmp/out"
  lost_result "$tmp/out" "$4" "$5"
  got=$?
  if [ "$got" = "$2" ]; then echo "ok: $1"; else echo "FAIL: $1 (want $2, got $got)"; fails=1; fi
}
expect "the lost result, marker written"            0 "$err" 1 0
expect "the lost result, no marker"                 1 "$err" 0 0
expect "the lost result, only an earlier marker"    1 "$err" 1 1
expect "marker, but a failed test line"             1 "$err
❌ multi-window phase t1" 1 0
expect "marker, but flutter says tests failed"      1 "$err
Some tests failed." 1 0
expect "marker, a failure that is not the listener" 1 "unhandled error during finalization of test:
SomethingElse: boom" 1 0
expect "marker, no finalization error at all"       1 "0 tests passed." 1 0
exit "$fails"
