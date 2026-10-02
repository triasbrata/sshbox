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
  # The SDK's `initialize` on stdin, as chat lists the slash commands with it:
  # answered with ~/.e2e-commands.json where a flow put one; the rest read
  # until stdin ends, as before.
  -p) while IFS= read -r line; do
      case $line in *'"initialize"'*) cat "$HOME/.e2e-commands.json" 2>/dev/null ;; esac
    done ;;
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
    # #131: a mermaid fence in a reply is drawn as a diagram, not its source.
    'E2E diagram': [user('draw it'),
                    said('Diagram below\n\n```mermaid\ngraph TD\n  E2EA --> E2EB\n```\n\nDiagram above')],
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

# chat_mermaid alone, for E2E_ONLY: the stand-in's sessions first.
chat_mermaid() {
  chat_stand_in
  flow chat_mermaid
}

# The code editor from the drawer: an edit saved through its own chrome. Its
# file goes in the login home, the root of the host's file tree, with the
# CRLF endings the flow is about, and is gone with the runner.
file_editor() {
  local file=/home/$SSH_USER/sshbox-maestro.yaml
  printf 'name: maestro\r\nitems:\r\n  - one\r\n' |
    sudo -u "$SSH_USER" tee "$file" >/dev/null
  flow file_editor || return 1
  # The edit arrived -- "maestro" typed once more than the one the file held
  # -- and every line still ends in CRLF.
  echo "The file on the host after the save:"
  sudo od -c "$file" | head -8
  [ "$(sudo grep -o maestro "$file" | wc -l)" -ge 2 ] &&
    [ "$(sudo grep -c $'\r$' "$file")" -eq "$(sudo wc -l <"$file")" ]
}

# #94: Gboard sends Backspace as a raw KEYCODE_DEL key event, from the
# virtual keyboard's device (-1) and flagged as soft, whenever it sees nothing
# before the caret. Jeansh took it for a hardware keyboard: the soft keyboard
# closed, and no tap on the terminal raised it again. adb's `input keyevent`
# injects from that same device -1, though without the soft flag, so it takes
# the path the fix changed -- Gboard's own key, flag and all, it does not
# send. Whether the keyboard is up is read off Android itself.
ime_shown() { adb shell dumpsys input_method | grep -q 'mInputShown=true'; }
soft_backspace() {
  local size w h
  flow soft_backspace_start || return 1
  sleep 1
  echo "Input method: $(adb shell settings get secure default_input_method)"
  adb shell dumpsys input_method | grep -E 'mInputShown|mShowRequested' | head -4
  ime_shown || { echo "the keyboard never came up"; return 1; }
  for _ in 1 2 3; do
    adb shell input keyevent KEYCODE_DEL
    sleep 0.3
  done
  sleep 1
  ime_shown || { echo "Backspace with nothing to delete closed the keyboard"; return 1; }
  # Away, as a user puts it away; the keyboard takes Back itself.
  adb shell input keyevent KEYCODE_BACK
  sleep 1
  if ime_shown; then echo "the keyboard did not go away"; return 1; fi
  size=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
  w=${size%x*}
  h=${size#*x}
  adb shell input tap $((w / 2)) $((h * 35 / 100))
  sleep 1.5
  ime_shown || { echo "a tap on the terminal did not bring the keyboard back"; return 1; }
  echo "the keyboard stayed up through Backspace, and a tap brought it back"
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

# Text shared into the running Jeansh from another app goes to its session,
# pasted and never run, and makes no second copy. Two UAT-passed features: a
# SEND with EXTRA_TEXT used to arrive as nothing, and a share used to start a
# second Jeansh. The paste is drawn, not text a flow can read, so the host
# reads it instead: the terminal runs cat into a file, the text is shared in
# with adb, and once Enter hands cat the line the file must hold it — with one
# MainActivity still.
share_text() {
  local text='shared from another app' out=/tmp/e2e-shared.txt got records
  local main=cloud.brata.terminal/dev.triasbrata.sshbox.MainActivity
  sudo rm -f "$out"
  flow share_text_start || return 1
  adb shell "am start -W -a android.intent.action.SEND -t text/plain \
    --es android.intent.extra.TEXT '$text' \
    -n cloud.brata.terminal/dev.triasbrata.sshbox.ShareActivity" >/dev/null || return 1
  sleep 3
  records=$(adb shell dumpsys activity activities |
    grep -oE "ActivityRecord\{[0-9a-f]+ u0 $main" | sort -u | wc -l | tr -d ' ')
  flow share_text_finish || return 1
  sleep 1
  got=$(cat "$out" 2>/dev/null)
  echo "the host's file after the share: '$got'; MainActivity records: $records"
  [ "$got" = "$text" ] && [ "$records" -eq 1 ]
}

# The chat button's Claude Code check, UAT issue #22: one flow, three hosts, the
# stand-in swapped between them. Report-only until it has earned the gate. Each
# expected toast is the app's own wording (ClaudeChat.versionRefusal).
chat_version_case() {
  local label=$1 answer=$2 expect=$3 shot=chat-version-$1 found status=0
  echo "::group::chat_version: $label (report only)"
  stand_in "$answer"
  # Said here, from the host, so a run that finds no toast shows whether the
  # stand-in was in place or the toast simply came and went unseen.
  echo "the host's claude --version now answers: $(sudo -u "$SSH_USER" sh -lc \
    'c=$HOME/.local/bin/claude; [ -x "$c" ] && "$c" --version || echo "(no claude)"')"
  # A bare name: Maestro 2.10 refuses a screenshot path that resolves outside its
  # own directory, and this one gets moved into the evidence folder after.
  flow chat_version -e "EXPECT=$expect" -e "SHOT=$shot" || {
    status=1
    echo "::warning::chat_version ($label) failed -- report only, not gating"
  }
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
  return "$status"
}

# Its own id, past the ones chat_stand_in numbers from 1: the fourth of those
# once took 4 too, and chat then picked the finished copy and not the pane.
LIVE_SID=e2e00009-0000-4000-8000-000000000009
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

# Its screenshots are evidence, wherever Maestro put them: see chat_version.
keep_shots() {
  for shot in $( { find "$ROOT" -maxdepth 2 -name "$1"
                   find "$HOME/.maestro" -name "$1"; } 2>/dev/null); do
    mv -f "$shot" "$EVIDENCE/" && echo "evidence: $(basename "$shot")"
  done
}

# Markdown typed into the chat and drawn as Markdown (#141), against the live
# session chat_two_way uses: a block of its own for E2E_ONLY, which sets the
# host up itself. The whole run calls the flow inside chat_two_way's group.
chat_markdown() {
  chat_stand_in
  live_session
  local status=0
  flow chat_markdown || status=1
  keep_shots 'chat-markdown-*.png'
  end_live_session
  stand_in ''
  return "$status"
}

# The stand-in's pane killed, and the state file it leaves when killed rather
# than ended: its own only, by its session id, so live_session can start again.
end_live_session() {
  sudo -u "$SSH_USER" -H tmux kill-session -t e2e-live 2>/dev/null
  sudo find "/home/$SSH_USER/.claude/sessions" -name '*.json' \
    -exec grep -l "\"sessionId\":\"$LIVE_SID\"" {} + 2>/dev/null | xargs -r sudo rm -f
}

# #143: the line chat shows while a watched turn runs -- Working… with its
# seconds, tokens and tool, gone at the turn's end; what a turn stopped at a
# permission prompt waits for; and a chat hidden while Claude writes coming
# back still following. Against the stand-in's slow:, wait: and long: turns.
chat_progress() {
  local status=0
  chat_stand_in
  end_live_session
  live_session
  flow chat_progress || status=1
  # Its screenshots, pass or fail, into the evidence folder (see chat_version_case).
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-progress-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_live_session
  stand_in ''
  return "$status"
}

# The three hosts, one after another: a block of its own for E2E_ONLY.
# Fails if any of them did, for a run asking for it alone.
chat_version() {
  local status=0
  chat_version_case too-old '2.1.100 (Claude Code)' \
    '(?s).*Claude Code 2\.1\.100 on this host is too old for chat.*2\.1\.259.*' || status=1
  chat_version_case not-a-version 'claude: something went wrong' \
    '(?s).*Could not tell which Claude Code this host has.*2\.1\.259.*' || status=1
  chat_version_case not-installed '' \
    '(?s).*Claude Code is not installed on this host.*' || status=1
  return "$status"
}

# Pictures in chat (#146), .maestro/chat_images.yaml a section at a time, what
# each sent to the host checked between them. Pictures go in by touch, the
# box's own Paste, and by +; a Ctrl+V, which Maestro cannot press, is tried
# once with adb and reported. The host's Claude is the stand-in in
# tools/e2e_image_claude.py, which logs what it is given to ~/.e2e-pics.log;
# what reached the host is read from there and from the transcripts.
# Ids no other block uses: chat_stand_in counts up from 1, STATUS_SID is 8,
# LIVE_SID 9, and the image stand-in's --bg and -p take a and b.
PICS_SIDS=(e2e0000c-0000-4000-8000-00000000000c e2e0000d-0000-4000-8000-00000000000d
  e2e0000e-0000-4000-8000-00000000000e)
pics_pids=()

# How many picture cards the screen shows, read off Android's own view tree.
pics_cards() {
  adb shell uiautomator dump /sdcard/e2e-ui.xml >/dev/null 2>&1
  adb shell cat /sdcard/e2e-ui.xml 2>/dev/null | grep -o 'View [^"]*' | wc -l | tr -d ' '
}

# A Ctrl+V on the emulator, into whatever has focus: the chat's box, which
# takes a picture on that chord. Said, with what the app's clipboard reader
# logged, whether it made one more card; with none, a chord held longer.
pics_paste() {
  local before after
  before=$(pics_cards)
  adb logcat -c 2>/dev/null
  for hold in '' '-t 300'; do
    # shellcheck disable=SC2086
    adb shell input keycombination $hold KEYCODE_CTRL_LEFT KEYCODE_V
    sleep 3
    after=$(pics_cards)
    echo "Ctrl+V${hold:+ held ($hold)}: cards $before -> $after"
    adb logcat -d -s JeanshPaste 2>/dev/null | tail -5
    [ "$after" -gt "$before" ] && return 0
  done
  echo "::warning::Ctrl+V made no card"
  return 1
}

# chat_images' sections, one by one: pics STEP [-e ...].
pics() {
  local step=$1
  shift
  echo "-- chat_images: $step"
  flow chat_images -e "STEP=$step" "$@" || {
    echo "::error::chat_images failed at its '$step' section"
    return 1
  }
}

pics_host() {
  local home=/home/$SSH_USER as=(sudo -u "$SSH_USER" -H) pid bg
  if "${as[@]}" tmux has-session -t e2e-pics 2>/dev/null; then
    echo "::error::the host already has a tmux session e2e-pics" >&2
    return 1
  fi
  put_stand_in <<'SH'
p=$HOME/.e2e-pics/e2e_live_claude.py
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  attach) exec env PYTHONIOENCODING=utf-8 python3 "$p" --tui --id "$2" ;;
  --bg) exec env PYTHONIOENCODING=utf-8 python3 "$p" --bg "$@" ;;
  -p) exec env PYTHONIOENCODING=utf-8 python3 "$p" --stream "$@" ;;
  *) exec cat >/dev/null ;;
esac
SH
  "${as[@]}" mkdir -p "$home/.e2e-pics"
  sudo install -o "$SSH_USER" -m 644 tools/e2e_live_claude.py tools/e2e_image_claude.py \
    "$home/.e2e-pics/"
  # A red PNG in the home, the file tree's root, and the sessions' transcripts.
  "${as[@]}" python3 - "$home" <<'PY' || return 1
import json, os, struct, sys, zlib
home = sys.argv[1]
def png(rgb, w=64, h=48):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    def chunk(n, b):
        return struct.pack('>I', len(b)) + n + b + struct.pack('>I', zlib.crc32(n + b) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
open(os.path.join(home, 'e2e-red.png'), 'wb').write(png((230, 20, 20)))
d = os.path.join(home, '.claude', 'projects', home.replace('/', '-'))
os.makedirs(d, exist_ok=True)
for n in 'cde':
    with open(os.path.join(d, f'e2e0000{n}-0000-4000-8000-00000000000{n}.jsonl'), 'w') as f:
        for e in ({'type': 'user', 'message': {'role': 'user', 'content': 'Earlier question'}},
                  {'type': 'assistant', 'message': {'role': 'assistant',
                   'content': [{'type': 'text', 'text': 'Earlier answer'}]}}):
            f.write(json.dumps(e) + '\n')
PY
  # On the phone, in Downloads for the + button: a blue PNG, and a BMP, a
  # picture to Android's picker and not one Claude reads.
  python3 - "$ROOT/build" <<'PY' || return 1
import struct, sys, zlib
out = sys.argv[1]
raw = b''.join(b'\x00' + bytes((20, 20, 230)) * 64 for _ in range(48))
def chunk(n, b):
    return struct.pack('>I', len(b)) + n + b + struct.pack('>I', zlib.crc32(n + b) & 0xffffffff)
open(out + '/e2e-blue.png', 'wb').write(
    b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 48, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
pixel = b'\x00\x00\xff\x00'
info = struct.pack('<IiiHHIIiiII', 40, 1, 1, 1, 24, 0, len(pixel), 2835, 2835, 0, 0)
head = struct.pack('<2sIHHI', b'BM', 14 + len(info) + len(pixel), 0, 0, 14 + len(info))
open(out + '/e2e-old.bmp', 'wb').write(head + info + pixel)
PY
  adb push "$ROOT/build/e2e-blue.png" /sdcard/Download/e2e-blue.png >/dev/null &&
    adb push "$ROOT/build/e2e-old.bmp" /sdcard/Download/e2e-old.bmp >/dev/null || return 1
  # The background session: a sleep for chat's follow to watch, as a live one.
  bg=$("${as[@]}" sh -c 'setsid sleep 3600 </dev/null >/dev/null 2>&1 & echo $!')
  pics_pids+=("$bg")
  # The interactive one, in a tmux pane of its own.
  "${as[@]}" sh -c 'cd && LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux new-session -d -s e2e-pics \
    -x 120 -y 30 "exec env PYTHONIOENCODING=utf-8 python3 $HOME/.e2e-pics/e2e_live_claude.py --tui --pane $1"' \
    sh "${PICS_SIDS[2]}" || return 1
  sleep 1
  pid=$("${as[@]}" tmux list-panes -t e2e-pics -F '#{pane_pid}')
  "${as[@]}" python3 - "$home" "$bg" "$pid" "${PICS_SIDS[@]}" <<'PY'
import json, os, sys
home, bg, pane, own, live, inpane = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), *sys.argv[4:]
path = os.path.join(home, '.e2e-agents.json')
try:
    rows = json.load(open(path))
except (OSError, ValueError):
    rows = []
rows = [r for r in rows if r.get('sessionId') not in (own, live, inpane)]
rows += [
    {'id': 'e2e0000c', 'sessionId': own, 'name': 'E2E pictures own', 'cwd': home,
     'kind': 'background', 'state': 'done', 'startedAt': 1790000000200},
    {'id': 'e2e0000d', 'sessionId': live, 'pid': bg, 'name': 'E2E pictures live',
     'cwd': home, 'kind': 'background', 'state': 'done', 'status': 'idle',
     'startedAt': 1790000000201},
    {'kind': 'interactive', 'pid': pane, 'sessionId': inpane, 'name': 'E2E pictures pane',
     'cwd': home, 'status': 'idle', 'startedAt': 1790000000202},
]
json.dump(rows, open(path, 'w'))
PY
  sudo rm -f "$home/.e2e-pics.log"
  echo "pictures' host: background sleep $bg, pane pid $pid"
}

# Step 2's order, from the stand-in's log: each picture's path, uploaded to
# the host's /tmp, pasted; its chip; and only then the text after it; and the
# message recorded as [Image #N] between [Image #N] after.
pics_order() {
  echo "the stand-in's log for $1:"
  sudo cat "/home/$SSH_USER/.e2e-pics.log"
  sudo python3 - "/home/$SSH_USER/.e2e-pics.log" <<'PY'
import json, re, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
problems = []
pasted = [e for e in events if e['ev'] == 'paste']
if len(pasted) != 2:
    problems.append(f'{len(pasted)} pictures pasted, not 2; pasted as text: '
                    f'{[e.get("v") for e in events if e["ev"] == "paste-text"]}')
for e in pasted:
    p = e['path']
    if not p.startswith('/tmp/') or open(p, 'rb').read(8) != b'\x89PNG\r\n\x1a\n':
        problems.append(f'{p} is not a PNG uploaded to /tmp')
waiting = 0
for e in events:
    if e['ev'] == 'paste':
        waiting += 1
    elif e['ev'] == 'chip':
        waiting -= 1
    elif e['ev'] in ('text', 'enter') and waiting:
        problems.append(f'{e["ev"]} {e.get("v", e.get("text"))!r} came before a chip')
enter = [e for e in events if e['ev'] == 'enter']
said = enter[-1]['text'] if enter else ''
if not re.fullmatch(r'\[Image #\d+\]\s+between\s+\[Image #\d+\]\s+after', said):
    problems.append(f'recorded as {said!r}')
for p in problems:
    print('::error::' + p)
sys.exit(1 if problems else 0)
PY
}

# One adb Ctrl+V, and what came of it: the box's text, as Android's view tree
# has it, and the clipboard reader's log, which says whether the app's own
# paste ran. Report only.
pics_probe() {
  adb logcat -c 2>/dev/null
  adb shell input keycombination KEYCODE_CTRL_LEFT KEYCODE_V
  sleep 3
  adb shell uiautomator dump /sdcard/e2e-ui.xml >/dev/null 2>&1
  echo "probe $1: fields now hold:"
  adb shell cat /sdcard/e2e-ui.xml 2>/dev/null | grep -o '<node [^>]*EditText[^>]*>' |
    grep -o ' text="[^"]*"'
  echo "probe $1: cards: $(adb shell cat /sdcard/e2e-ui.xml 2>/dev/null | grep -o 'View [^"]*' | wc -l)"
  echo "probe $1: JeanshPaste said:"
  adb logcat -d -s JeanshPaste 2>/dev/null | grep -v '^-' | tail -5
}

chat_images() {
  local status=0 log=/home/$SSH_USER/.e2e-pics.log session started pid
  pics_host || return 1
  # Steps 1, 5 and 4, in this chat's own claude -p. A Ctrl+V is tried once,
  # and said whether it made a card; the flow pastes by touch where not.
  { pics open -e "SESSION=E2E pictures own" && { pics_paste || true; } &&
    pics own && pics remove && pics send; } || status=1
  echo "what the stand-in's claude -p was sent:"
  sudo grep '"ev": "message"' "$log" ||
    { echo "::error::step 1: no message reached claude -p"; status=1; }
  sudo grep -q '"images": \["image/png"\]' "$log" ||
    { echo "::error::step 1: the message carried no PNG image block"; status=1; }
  # Step 2, into a background session through attach, then one in a pane.
  for session in live pane; do
    sudo truncate -s 0 "$log"
    pics watch -e "SESSION=E2E pictures $session" -e "SHOT=$session" || status=1
    pics_order "step 2, $session" || { echo "::error::step 2 ($session) failed"; status=1; }
  done
  # Step 3: a new chat with a picture starts claude --bg with no prompt, and
  # pastes the message in after.
  sudo truncate -s 0 "$log"
  pics new || status=1
  echo "the stand-in's log for step 3:"
  sudo cat "$log"
  sudo python3 - "$log" <<'PY' || { echo "::error::step 3 failed"; status=1; }
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
bg = [e for e in events if e['ev'] == 'bg']
enter = [e for e in events if e['ev'] == 'enter']
ok = bool(bg and '--' not in bg[0]['argv'] and enter and enter[-1]['images']
          and any(e['ev'] == 'paste' for e in events))
if not ok:
    print('::error::step 3: --bg', bg and bg[0]['argv'], 'then', enter)
sys.exit(0 if ok else 1)
PY
  # Step 6: + offers a file Claude cannot read, which is refused. With the
  # emulator's animations off a toast is gone at once, so they are on for
  # this one.
  adb shell settings put global animator_duration_scale 1
  pics refuse || status=1
  adb shell settings put global animator_duration_scale 0
  # Where a hardware Ctrl+V goes: into the box with a picture on the
  # clipboard, with text, and into the terminal. Report only.
  pics probe-picture && pics_probe picture
  pics probe-text && pics_probe text
  pics probe-terminal && pics_probe terminal
  pics done
  # Only what this started: the tmux session, the sleeps, the stand-in.
  sudo -u "$SSH_USER" -H tmux kill-session -t e2e-pics 2>/dev/null
  sudo find "/home/$SSH_USER/.claude/sessions" -name '*.json' \
    -exec grep -l '"sessionId":"e2e0000e-' {} + 2>/dev/null | xargs -r sudo rm -f
  started=$(sudo python3 -c 'import json, sys
print(" ".join(str(r["pid"]) for r in json.load(open(sys.argv[1]))
               if r.get("sessionId", "").startswith("e2e0000a") and r.get("pid")))' \
    "/home/$SSH_USER/.e2e-agents.json" 2>/dev/null)
  for pid in "${pics_pids[@]}" $started; do sudo kill "$pid" 2>/dev/null; done
  stand_in ''
  return "$status"
}

# #159: the live marks in chat's sessions sidebar. One pinned background
# session on the stand-in listing, its process a sleep of the host user's own,
# rewritten between three flows that keep the app as it is: working, then
# waiting for a permission prompt, then done -- marked "not opened since" until
# its row is opened. The sidebar asks for the listing every 5 s while shown.
STATUS_SID=e2e00008-0000-4000-8000-000000000008
status_row() { # status state [waitingFor]
  sudo -u "$SSH_USER" -H python3 - "$STATUS_SID" "$STATUS_PID" "$@" <<'PY'
import json, os, sys
sid, pid, status, state = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
row = {'id': 'e2es8', 'sessionId': sid, 'pid': pid, 'kind': 'background',
       'name': 'E2E status session', 'cwd': os.environ['HOME'],
       'startedAt': 1790000000200, 'status': status, 'state': state}
if len(sys.argv) > 5:
    row['waitingFor'] = sys.argv[5]
json.dump([row], open(os.path.join(os.environ['HOME'], '.e2e-agents.json'), 'w'))
PY
}
chat_session_status() {
  local status=0 home=/home/$SSH_USER as=(sudo -u "$SSH_USER" -H)
  chat_stand_in
  # Its process: something of the host user's own that lives through the run.
  STATUS_PID=$("${as[@]}" sh -c 'sleep 900 >/dev/null 2>&1 & echo $!')
  "${as[@]}" python3 - "$STATUS_SID" <<'PY'
import json, os, sys
home, sid = os.environ['HOME'], sys.argv[1]
projects = os.path.join(home, '.claude', 'projects', home.replace('/', '-'))
os.makedirs(projects, exist_ok=True)
with open(os.path.join(projects, sid + '.jsonl'), 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'Status question'}}) + '\n')
    f.write(json.dumps({'type': 'assistant', 'message': {'role': 'assistant',
            'content': [{'type': 'text', 'text': 'Status answer'}]}}) + '\n')
jobs = os.path.join(home, '.claude', 'jobs')
os.makedirs(jobs, exist_ok=True)
json.dump(['e2es8'], open(os.path.join(jobs, 'pins.json'), 'w'))
PY
  status_row busy working
  flow chat_status_working || status=1
  if [ "$status" -eq 0 ]; then
    status_row waiting blocked 'permission prompt'
    flow chat_status_waiting || status=1
  fi
  if [ "$status" -eq 0 ]; then
    status_row idle done
    flow chat_status_done || status=1
  fi
  keep_shots 'chat-status-*.png'
  "${as[@]}" kill "$STATUS_PID" 2>/dev/null
  sudo rm -f "$home/.claude/jobs/pins.json"
  stand_in ''
  return "$status"
}

# #145: chat's / list, read from the host's own answer to the SDK's
# `initialize`, and a command sent into a watched session drawn as one. The
# stand-in lists four built-ins chat treats two ways -- compact and context
# run, model and config open dialogs -- and one command of a skill's; the live
# session records a /context it is sent as Claude Code does, in local_command
# lines, so the chip and its output come back from history too.
end_slash_session() {
  sudo -u "$SSH_USER" -H tmux kill-session -t e2e-live 2>/dev/null
  sudo find "/home/$SSH_USER/.claude/sessions" -name '*.json' \
    -exec grep -l "\"sessionId\":\"$LIVE_SID\"" {} + 2>/dev/null | xargs -r sudo rm -f
}
chat_slash() {
  local status=0 commands=/home/$SSH_USER/.e2e-commands.json
  chat_stand_in
  end_slash_session
  live_session
  sudo -u "$SSH_USER" -H tee "$commands" >/dev/null <<'JSON'
{"type":"control_response","response":{"subtype":"success","request_id":"sshbox-commands","response":{"commands":[{"name":"compact","description":"Clear the conversation but keep a summary in context","argumentHint":"<optional instructions>","builtin":true,"aliases":[]},{"name":"context","description":"Show current context usage","argumentHint":"","builtin":true,"aliases":[]},{"name":"model","description":"Set the AI model for Claude Code","argumentHint":"","builtin":true,"aliases":[]},{"name":"config","description":"Open the settings panel","argumentHint":"","builtin":true,"aliases":["settings"]},{"name":"e2e-review","description":"A skill the e2e stand-in lists","argumentHint":"<file>","builtin":false,"aliases":[]}]}}}
JSON
  flow chat_slash || status=1
  # Refused means never typed: the session's own record holds no /model.
  if sudo grep -q 'command-name>/model\|"/model' \
    "/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl" 2>/dev/null; then
    echo "::error::/model reached the session"
    status=1
  fi
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-slash-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_slash_session
  sudo rm -f "$commands"
  stand_in ''
  return "$status"
}

# A hand run may ask for one block alone after seed_host (e2e.yml's `block`),
# which is minutes rather than the half hour of every flow. Here, after every
# block is defined (#109): a block is one of the functions above, and any
# other name is a flow of .maestro/ run as it is.
if [ -n "${E2E_ONLY:-}" ]; then
  echo "::group::$E2E_ONLY (asked for alone)"
  if declare -F "$E2E_ONLY" >/dev/null; then
    "$E2E_ONLY"
  else
    flow "$E2E_ONLY"
  fi
  status=$?
  echo "::endgroup::"
  [ "$status" -eq 0 ] || echo "::error::$E2E_ONLY failed"
  exit "$status"
fi

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

echo "::group::single_instance (report only)"
single_instance || echo "::warning::single_instance failed -- report only, not gating"
echo "::endgroup::"

echo "::group::share_text (report only)"
share_text || echo "::warning::share_text failed -- report only, not gating"
echo "::endgroup::"

chat_version || true

# Chat mode against sessions the stand-in keeps (chat_stand_in): where a
# conversation comes back to, and how a tool's row reads. Report-only until
# they have earned the gate.
chat_stand_in
for name in chat_scroll chat_tool_rows chat_mermaid; do
  echo "::group::$name (report only)"
  flow "$name" || echo "::warning::$name failed -- report only, not gating"
  # Their screenshots are evidence, wherever Maestro put them: see chat_version.
  # -maxdepth keeps the evidence folder itself, a level deeper, out of it.
  for shot in $( { find "$ROOT" -maxdepth 2 -name 'chat-tool-rows-*.png' -o -name 'chat-mermaid-*.png'
                   find "$HOME/.maestro" -name 'chat-tool-rows-*.png' -o -name 'chat-mermaid-*.png'; } 2>/dev/null); do
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
echo "::endgroup::"
echo "::group::chat_markdown (report only)"
flow chat_markdown || echo "::warning::chat_markdown failed -- report only, not gating"
keep_shots 'chat-markdown-*.png'
end_live_session
echo "::endgroup::"
stand_in ''

echo "::group::chat_session_status (report only)"
chat_session_status || echo "::warning::chat_session_status failed -- report only, not gating"
echo "::endgroup::"

echo "::group::chat_progress (report only)"
chat_progress || echo "::warning::chat_progress failed -- report only, not gating"
echo "::endgroup::"

echo "::group::chat_images (report only)"
chat_images || echo "::warning::chat_images failed -- report only, not gating"
echo "::endgroup::"

echo "::group::chat_slash (report only)"
chat_slash || echo "::warning::chat_slash failed -- report only, not gating"
echo "::endgroup::"

echo "::group::soft_backspace (report only)"
soft_backspace || echo "::warning::soft_backspace failed -- report only, not gating"
echo "::endgroup::"

# Last, since it leaves its session's tab open.
#
# Not swipe_cursor, which reads the shell's working directory off the tab's
# title: a saved host's tab now shows its label, so it never sees a `cd`
# land, on main or in the redesign. It wants its checks moved to this host.
echo "::group::file_editor (report only)"
file_editor || echo "::warning::file_editor failed -- report only, not gating"
echo "::endgroup::"

# The UI text size at its largest (issue #133). Last of all, as the size it
# sets is saved and every flow after it would meet the app at 160%.
echo "::group::text_size (report only)"
flow text_size || echo "::warning::text_size failed -- report only, not gating"
echo "::endgroup::"

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
