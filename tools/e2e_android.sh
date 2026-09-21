#!/usr/bin/env bash
# The Android release gate: installs the candidate on the emulator and drives
# it with Maestro, against the sshd this runner started on its own loopback.
#
# Two sets of flows, deliberately:
#
#   GATING       a failure here fails the gate, and no release is promoted.
#                Kept small on purpose: a flaky flow in this set does not go
#                red, it stops every release until someone fixes it.
#   REPORT-ONLY  run and reported, never gating. A flow earns its way into
#                GATING by being green here for a while, not by being written.
#
# seed_host runs first and alone: it makes the host every other flow needs.
# If it fails, nothing after it can mean anything, so the run stops there and
# says so rather than reporting ten failures that are really one.
#
# 10.0.2.2 is how an Android emulator reaches the machine running it, which is
# where e2e.yml's sshd listens.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APK="${APK:-build/app/outputs/flutter-apk/app-debug.apk}"
: "${SSH_USER:?SSH_USER must be set}"
: "${SSH_PASSWORD:?SSH_PASSWORD must be set}"

GATING=(smoke connect_and_keybar)
REPORT_ONLY=(tabs file_browser)

# One label for every flow. The flows default to "WSL via", which would be a
# lie on a CI runner; what matters is that seed_host and the rest agree.
LABEL="E2E via"

maestro_env=(
  -e "HOST_LABEL=$LABEL"
  -e "SSH_HOST=10.0.2.2"
  -e "SSH_PORT=22"
  -e "SSH_USER=$SSH_USER"
  -e "SSH_PASSWORD=$SSH_PASSWORD"
)

flow() { maestro test "${maestro_env[@]}" ".maestro/$1.yaml"; }

echo "::group::Install the candidate"
adb install -r -t "$APK" || { echo "::error::could not install $APK"; exit 1; }
echo "::endgroup::"

echo "::group::seed_host"
if ! flow seed_host; then
  echo "::endgroup::"
  echo "::error::seed_host failed, so no other flow can run meaningfully. The" \
       "host every flow connects to was never made."
  exit 1
fi
echo "::endgroup::"

failed=()
for name in "${GATING[@]}"; do
  echo "::group::$name (gating)"
  flow "$name" || failed+=("$name")
  echo "::endgroup::"
done

for name in "${REPORT_ONLY[@]}"; do
  echo "::group::$name (report only)"
  flow "$name" || echo "::warning::$name failed -- report only, not gating"
  echo "::endgroup::"
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::gating flows failed: ${failed[*]}"
  exit 1
fi
echo "Every gating flow passed: seed_host ${GATING[*]}"
