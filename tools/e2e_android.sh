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

# This writes into $SSH_USER's home — a stand-in claude on its PATH, chat
# transcripts under its ~/.claude — and takes them away again. That is safe
# only for a user made for the run and gone with it, as e2e.yml's e2e is. On a
# machine someone uses, ~/.local/bin/claude is their real Claude Code, the
# native installer's symlink into its versions, and a write through it would
# replace the binary every session there runs on. So: a CI runner, and never
# as the user running it.
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "tools/e2e_android.sh writes into \$SSH_USER's home, so it runs on a CI" \
       "runner only (GITHUB_ACTIONS=true), for a user made for the run." >&2
  exit 2
fi
if [ "$SSH_USER" = "$(id -un)" ]; then
  echo "SSH_USER is the user running this; it must be a throwaway one." >&2
  exit 2
fi

GATING=(smoke connect_and_keybar)
REPORT_ONLY=(tabs file_browser logs duplicate_session dotfiles card_tap_reconnect
  port_forward_no_host terminal_selection)

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
STAND_IN=/home/$SSH_USER/.local/bin/claude

# The line every stand-in carries, so nothing else is ever written over or
# removed: not a symlink, which a write would follow into what it points at,
# and not a claude this script did not make.
STAND_IN_MARK='# the e2e stand-in for Claude Code, made by tools/e2e_android.sh'

ours() {
  if sudo test -L "$STAND_IN"; then return 1; fi
  if ! sudo test -e "$STAND_IN"; then return 0; fi
  sudo grep -qxF "$STAND_IN_MARK" "$STAND_IN"
}

# Puts a stand-in in place, its text on stdin, or removes it given "remove";
# refuses, ending the run, where the claude there is not one of ours.
put_stand_in() {
  if ! ours; then
    echo "::error::$STAND_IN is not this script's stand-in; leaving it alone" >&2
    exit 1
  fi
  if [ "${1:-}" = remove ]; then
    sudo rm -f "$STAND_IN"
    return 0
  fi
  sudo -u "$SSH_USER" mkdir -p "$(dirname "$STAND_IN")"
  { printf '#!/bin/sh\n%s\n' "$STAND_IN_MARK"; cat; } |
    sudo -u "$SSH_USER" tee "$STAND_IN" >/dev/null
  sudo chmod 755 "$STAND_IN"
}

stand_in() {
  if [ -z "${1:-}" ]; then
    put_stand_in remove
    return 0
  fi
  printf 'echo %s\n' "'$1'" | put_stand_in
}

# Chat mode's host: three finished Claude Code sessions with transcripts where
# the CLI keeps them, and a claude that lists them, answers a version chat
# takes, and, run as a resumed session, waits quietly on stdin as one with
# nothing new to say. The flows read what chat makes of the transcripts —
# where a conversation comes back to, and how a tool's row reads.
chat_stand_in() {
  local home=/home/$SSH_USER
  local projects=$home/.claude/projects/-home-$SSH_USER
  # Never beside sessions of someone's own: the transcripts go only where
  # there are none but these.
  if sudo find "$projects" -name '*.jsonl' ! -name 'e2e0000*' 2>/dev/null |
    grep -q .; then
    echo "::error::$projects holds sessions of its own; not writing there" >&2
    exit 1
  fi
  put_stand_in <<'SH'
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo -u "$SSH_USER" HOME="$home" python3 - <<'PY'
import json, os
home = os.environ['HOME']
projects = os.path.join(home, '.claude', 'projects', '-home-' + os.path.basename(home))
os.makedirs(projects, exist_ok=True)

def user(text):
    return {'type': 'user', 'message': {'role': 'user', 'content': text}}

def said(text):
    return {'type': 'assistant',
            'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}}

def tool(id, name, input, result):
    return [
        {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'tool_use', 'id': id, 'name': name, 'input': input}]}},
        {'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': id, 'content': result}]}},
    ]

# Short answers, one line each, so a small scroll moves several of them.
sessions = {
    'E2E long session': [e for n in range(1, 61)
                         for e in (user(f'Question {n}'), said(f'Answer {n} of the long session'))],
    'E2E short session': [user('Short question'), said('Short answer of the short session')],
    'E2E tool rows': [user('run it'),
                      *tool('toolu_e2e1', 'Bash',
                            {'command': 'ls -la /tmp/e2e-tool-rows',
                             'description': 'List the e2e folder'}, 'total 0'),
                      *tool('toolu_e2e2', 'Write',
                            {'file_path': '/tmp/e2e-tool-rows/notes.txt',
                             'content': 'first line\nsecond line'}, 'ok'),
                      said('Tools done')],
}
rows = []
for n, (name, events) in enumerate(sessions.items(), start=1):
    sid = f'e2e0000{n}-0000-4000-8000-00000000000{n}'
    with open(os.path.join(projects, sid + '.jsonl'), 'w') as f:
        f.write('\n'.join(json.dumps(e) for e in events) + '\n')
    rows.append({'id': f'e2e{n}', 'cwd': home, 'kind': 'background',
                 'startedAt': 1790000000000 + n, 'sessionId': sid,
                 'name': name, 'state': 'done'})
with open(os.path.join(home, '.e2e-agents.json'), 'w') as f:
    json.dump(rows, f)
PY
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

# "Never two live copies of Jeansh", checked with adb rather than Maestro: it
# is about Android tasks, which no screen shows. A plain `am start` of a running
# app only brings it forward and passes with or without the guard, so the
# second launch carries FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK,
# which asks for a fresh instance in a task of its own — what a floating
# window or a "new window" does. With the guard the copy hands over and
# finishes, and one MainActivity is left. An earlier try of this read one with
# the guard taken out too, so it says what it saw: am start's own answer and
# every task holding Jeansh. Report-only until it has been seen to fail.
single_instance() {
  local main=cloud.brata.terminal/dev.triasbrata.sshbox.MainActivity
  local records
  adb shell am start -W -n "$main" >/dev/null || return 1
  sleep 3
  # Home first. With Jeansh on top, Android hands a singleTop launch to the
  # running copy whatever the flags ask — "delivered to currently running
  # top-most instance" — and makes none, which is why the first try read one
  # copy with the guard taken out too. From Home it is a launch that misses
  # the running one, as a stale Recents card or a new window is.
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  echo "The second launch, as am start answers it:"
  adb shell am start -W -n "$main" -f 0x18000000 || return 1
  sleep 5
  echo "Tasks and activities holding Jeansh:"
  adb shell dumpsys activity activities |
    grep -E "\* Task\{|Hist #|ActivityRecord\{" | grep -E "brata|Task\{" | head -30
  records=$(adb shell dumpsys activity activities |
    grep -oE "ActivityRecord\{[0-9a-f]+ u0 $main" | sort -u | wc -l | tr -d ' ')
  echo "MainActivity records after a forced second launch: $records"
  [ "$records" -eq 1 ]
}
echo "::group::single_instance (report only)"
single_instance || echo "::warning::single_instance failed -- report only, not gating"
echo "::endgroup::"

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

# Chat mode against sessions the stand-in keeps (chat_stand_in): where a
# conversation comes back to, and how a tool's row reads. Report-only until
# they have earned the gate.
chat_stand_in
for name in chat_scroll chat_tool_rows; do
  echo "::group::$name (report only)"
  flow "$name" || echo "::warning::$name failed -- report only, not gating"
  # Their screenshots are evidence, wherever Maestro put them: see chat_version.
  # -maxdepth keeps the evidence folder itself, a level deeper, out of it.
  for shot in $( { find "$ROOT" -maxdepth 2 -name 'chat-tool-rows-*.png'
                   find "$HOME/.maestro" -name 'chat-tool-rows-*.png'; } 2>/dev/null); do
    mv -f "$shot" "$EVIDENCE/" && echo "evidence: $(basename "$shot")"
  done
  echo "::endgroup::"
done

# Chat typing into a running Claude Code session and showing what is typed at
# its terminal, both ways (UAT issue #15), against a stand-in interactive
# session in a tmux pane on the host: tools/e2e_live_claude.py, which keeps
# the state file, the ❯ input line and the transcript chat's host checks
# read. The phone's message must be typed into the pane and answered; then a
# line typed at the pane itself, once the phone's has landed, must show in
# the chat too.
LIVE_SID=e2e00004-0000-4000-8000-000000000004
live_session() {
  local home=/home/$SSH_USER as=(sudo -u "$SSH_USER" -H)
  # Only where nothing of anyone's is: no tmux session of this name, and no
  # session state file already there.
  if "${as[@]}" tmux has-session -t e2e-live 2>/dev/null ||
    sudo find "$home/.claude/sessions" -name '*.json' 2>/dev/null | grep -q .; then
    echo "::error::the host already has a live session; not starting another" >&2
    exit 1
  fi
  sudo install -o "$SSH_USER" -m 644 tools/e2e_live_claude.py "$home/.e2e-live-claude.py"
  # One turn already said, so the chat has a transcript to open.
  "${as[@]}" python3 - "$home" "$LIVE_SID" <<'PY'
import json, os, sys
home, sid = sys.argv[1], sys.argv[2]
d = os.path.join(home, '.claude', 'projects', home.replace('/', '-'))
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, sid + '.jsonl'), 'a') as f:
    for e in ({'type': 'user', 'message': {'role': 'user', 'content': 'Earlier question'}},
              {'type': 'assistant', 'message': {'role': 'assistant',
               'content': [{'type': 'text', 'text': 'Earlier answer'}]}}):
        f.write(json.dumps(e) + '\n')
PY
  "${as[@]}" sh -c 'cd && LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux new-session -d -s e2e-live \
    -x 120 -y 30 "env PYTHONIOENCODING=utf-8 python3 $HOME/.e2e-live-claude.py $1"' \
    sh "$LIVE_SID"
  sleep 1
  local pid
  pid=$("${as[@]}" tmux list-panes -t e2e-live -F '#{pane_pid}')
  # Listed as the CLI lists an interactive session: its pid, idle, no id.
  "${as[@]}" python3 - "$home" "$LIVE_SID" "$pid" <<'PY'
import json, os, sys
home, sid, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
path = os.path.join(home, '.e2e-agents.json')
rows = json.load(open(path))
rows.append({'kind': 'interactive', 'pid': pid, 'sessionId': sid,
             'name': 'E2E live session', 'cwd': home, 'status': 'idle',
             'startedAt': 1790000000100})
json.dump(rows, open(path, 'w'))
PY
  echo "live session in tmux pane of pid $pid"
}

echo "::group::chat_two_way (report only)"
live_session
# The terminal's side: once the phone's message is in the transcript, a line
# typed at the pane, as someone at that terminal would.
transcript=/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl
(
  for _ in $(seq 240); do
    sudo grep -qi 'hello from the phone' "$transcript" 2>/dev/null && break
    sleep 1
  done
  sleep 3
  sudo -u "$SSH_USER" -H tmux send-keys -t e2e-live -l 'typed at the terminal'
  sudo -u "$SSH_USER" -H tmux send-keys -t e2e-live Enter
) &
terminal_side=$!
flow chat_two_way || echo "::warning::chat_two_way failed -- report only, not gating"
kill "$terminal_side" 2>/dev/null
sudo -u "$SSH_USER" -H tmux kill-session -t e2e-live 2>/dev/null
echo "::endgroup::"
stand_in ''

# Every other flow's takeScreenshot, as evidence: Maestro keeps a bare-named
# one in its own results, under takeScreenshot/, which the upload does not
# reach. Its failure screenshots stay where they are, uploaded apart.
find "$HOME/.maestro/tests" -path '*/takeScreenshot/*.png' \
  -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::gating flows failed: ${failed[*]}"
  exit 1
fi
echo "Every gating flow passed: seed_host ${GATING[*]}"
