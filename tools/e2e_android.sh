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
REPORT_ONLY=(tabs file_browser logs duplicate_session)

# No HOST_LABEL here. Maestro 2.10 applies a flow's own `env:` block after the
# -e values, so every flow's default of "WSL via" would win over anything passed
# -- the first run proved it, typing the defaults in place of these. The label
# is only a name the flows agree on, so they keep their shared default. What
# must come from here are the credentials, which no flow defaults any more.
maestro_env=(
  -e "SSH_HOST=10.0.2.2"
  -e "SSH_PORT=22"
  -e "SSH_USER=$SSH_USER"
  -e "SSH_PASSWORD=$SSH_PASSWORD"
)

# flow NAME [-e KEY=VALUE ...]: extra -e values for this run only.
flow() {
  local name=$1
  shift
  maestro test "${maestro_env[@]}" "$@" ".maestro/$name.yaml"
}

# Screenshots taken as evidence, on success as well as failure, so a feature can
# be shown working rather than only reported green. e2e.yml uploads this folder.
EVIDENCE="$ROOT/build/e2e-evidence"
mkdir -p "$EVIDENCE"

# A stand-in claude on this runner, which is the SSH host the emulator signs in
# to, where the chat finder looks second: ~/.local/bin. With an argument it
# answers `claude --version` with exactly that; with none it is removed, and the
# runner, which ships no Claude Code, then has none anywhere.
stand_in() {
  local bin=/home/$SSH_USER/.local/bin/claude
  if [ -z "${1:-}" ]; then
    sudo rm -f "$bin"
    return 0
  fi
  sudo -u "$SSH_USER" mkdir -p "$(dirname "$bin")"
  printf '#!/bin/sh\necho %s\n' "'$1'" | sudo -u "$SSH_USER" tee "$bin" >/dev/null
  sudo chmod 755 "$bin"
}

# On a slow runner the emulator's own apps stall, and Android puts up "<app>
# isn't responding". The first time, it was Pixel Launcher, over Jeansh, just as
# seed_host looked for Add: the dialog is modal, so it hid the app from Maestro
# and the run failed over the emulator, not the build -- and seed_host runs in
# the release gate too, so it could have held back a release. hide_error_dialogs
# keeps such dialogs down. It hides no fault of ours: a Jeansh that crashes or
# freezes still fails its flow, since only the blocking dialog is gone.
adb shell settings put global hide_error_dialogs 1 || true

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

# The chat button's Claude Code check, UAT issue #22: one flow, three hosts, the
# stand-in swapped between them. Report-only until it has earned the gate. Each
# expected toast is the app's own wording (ClaudeChat.versionRefusal).
chat_version() {
  local label=$1 answer=$2 expect=$3 shot=chat-version-$1 found
  echo "::group::chat_version: $label (report only)"
  stand_in "$answer"
  # Said here, from the host, so a run that finds no toast shows whether the
  # stand-in was in place or the toast simply came and went unseen.
  echo "the host's claude --version now answers: $(sudo -u "$SSH_USER" sh -lc \
    'c=$HOME/.local/bin/claude; [ -x "$c" ] && "$c" --version || echo "(no claude)"')"
  # A bare name: Maestro 2.10 refuses a screenshot path that resolves outside its
  # own directory, and this one gets moved into the evidence folder after.
  flow chat_version -e "EXPECT=$expect" -e "SHOT=$shot" ||
    echo "::warning::chat_version ($label) failed -- report only, not gating"
  # Where Maestro puts a bare-named screenshot is not documented to be one place:
  # the working directory, the flow's own, or its own results folder. Look in all.
  found=$(find "$ROOT" -maxdepth 2 -name "$shot.png" -print -quit 2>/dev/null)
  [ -n "$found" ] || found=$(find "$HOME/.maestro" -name "$shot.png" -print -quit 2>/dev/null)
  if [ -n "$found" ]; then
    mv -f "$found" "$EVIDENCE/" && echo "evidence: $shot.png (was at $found)"
  else
    echo "::warning::no evidence screenshot $shot.png was written"
  fi
  echo "::endgroup::"
}
chat_version too-old '2.1.100 (Claude Code)' \
  '(?s).*Claude Code 2\.1\.100 on this host is too old for chat.*2\.1\.259.*'
chat_version not-a-version 'claude: something went wrong' \
  '(?s).*Could not tell which Claude Code this host has.*2\.1\.259.*'
chat_version not-installed '' \
  '(?s).*Claude Code is not installed on this host.*'
stand_in ''

# OSC 52: a program may copy to the clipboard and never read it (b11f5bc). The
# host sends the query and records what comes back; empty is refused, and ANY
# bytes are the hole, whatever the clipboard held. Report-only until it has been
# green a few times, then gating -- it guards a hole in every earlier release.
osc52_query_refused() {
  local script=/home/$SSH_USER/osc52-query.sh reply=/tmp/osc52-reply done=/tmp/osc52-done
  sudo rm -f "$reply" "$done"
  sudo -u "$SSH_USER" tee "$script" >/dev/null <<'SH'
#!/bin/sh
stty -echo raw
printf '\033]52;c;?\a'
timeout 2 cat -v > /tmp/osc52-reply
stty sane
touch /tmp/osc52-done
SH
  flow osc52_query || return 1
  # No marker means the command never ran, and silence from a command that
  # never ran must not pass for a refusal.
  if [ ! -f "$done" ]; then
    echo "::warning::the query script never finished, so nothing was checked"
    return 1
  fi
  if [ -s "$reply" ]; then
    # The length only: on a real device these bytes would be the clipboard.
    echo "::error::the app ANSWERED the clipboard query ($(wc -c < "$reply") bytes) -- the OSC 52 hole is open"
    return 1
  fi
  echo "refused: the clipboard query got nothing back"
}
echo "::group::osc52_query (report only)"
osc52_query_refused || echo "::warning::osc52_query failed -- report only, not gating"
echo "::endgroup::"

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::gating flows failed: ${failed[*]}"
  exit 1
fi
echo "Every gating flow passed: seed_host ${GATING[*]}"
