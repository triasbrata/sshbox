#!/usr/bin/env bash
# Every unit in tools/e2e_android.sh's UNITS has a u_<unit> function. A unit
# without one made every shard exit at "no u_<unit> for unit <unit>" after
# the emulator was up and the app installed, failing the release gate for
# hours (v1.0.122). The script cannot be run off the emulator, so this takes
# the definitions at its end (from u_smoke to the script's own check, nothing
# but function definitions and the loop that evals some) and runs that alone.
set -eu
cd "$(dirname "$0")/.."
script=${1:-tools/e2e_android.sh}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo 'UNITS=('
  E2E_UNITS=list bash "$script"
  echo ')'
  sed -n '/^u_smoke()/,/^  declare -F "u_\$unit"/p' "$script"
  echo 'done'
} >"$tmp"
bash "$tmp"
echo "every unit has its function"
