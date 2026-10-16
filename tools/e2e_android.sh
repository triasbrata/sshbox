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

# The units a whole run takes, in order: the flows and blocks at the end of
# this file, each a function u_<name> there. Those in GATING_UNITS gate;
# every other one only reports. E2E_UNITS=list prints them and runs nothing,
# for e2e.yml's plan and for a check that the shards' union is all of them.
UNITS=(smoke connect_and_keybar
  tabs file_browser logs duplicate_session dotfiles card_tap_reconnect
  port_forward_no_host terminal_selection
  single_instance jeansh_open2 jeansh_open share_text share_chat chat_continue_cwd
  chat_version chat_code_copy chat_scroll chat_tool_rows chat_mermaid chat_two_way
  html_tab html_site tab_close_narrow chat_session_status chat_progress
  chat_working_backstop
  chat_images chat_attach_deliver chat_subagents chat_usage chat_compact chat_model chat_cwd
  folder_zip chat_outbox chat_outbox_reconnect
  chat_edit_previous chat_ask_watched chat_slash chat_ask chat_follow_jump
  chat_tasks bug_button tmux_mouse_reattach text_size_home soft_backspace
  # Near the end, since they leave their session's tab open; text_size last.
  editor_save file_editor text_size)
if [ "${E2E_UNITS:-}" = list ]; then
  printf '%s\n' "${UNITS[@]}"
  exit 0
fi

# Which shard this run is (e2e.yml's matrix), I/N; unset, every unit. Worked
# out here, before the install, so a bad one costs nothing.
SHARD="${E2E_SHARD:-1/1}"
mine=$(python3 "$ROOT/tools/e2e_shards.py" --shard "$SHARD" "${UNITS[@]}") ||
  { echo "::error::could not work out shard $SHARD"; exit 1; }
mapfile -t MINE <<<"$mine"
[ -n "$mine" ] || { echo "::error::shard $SHARD has no units"; exit 1; }
echo "shard $SHARD runs ${#MINE[@]} of ${#UNITS[@]} units: ${MINE[*]}"

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
#
# Maestro now and then hangs in a call to its on-device driver and never
# comes back: in the gate of 2026-10-13, three flows sat at `Launch app` (and
# one earlier at `Stop`) until the unit's watchdog fired 10 to 16 minutes
# later, where a launch takes 1 to 4 s on every shard. Maestro prints a step
# when it ends, and no step waits longer than 120 s, so FLOW_SILENCE seconds
# with no output is such a hang: the run is killed, and if the flow had done
# nothing yet but stop and launch the app, it is run once more, since nothing
# it does has happened twice. A hang later in a flow fails it, saying where.
FLOW_SILENCE=${FLOW_SILENCE:-240}
flow() {
  local name=$1 out rc try
  shift
  out=$(mktemp)
  for try in 1 2; do
    maestro_watched "$out" "${maestro_env[@]}" "$@" ".maestro/$name.yaml"
    rc=$?
    [ "$rc" -eq 124 ] || break
    local at
    at=$(tr '\r' '\n' <"$out" | grep -v '^[[:space:]]*$' | tail -1)
    echo "::warning::$name: Maestro printed nothing for $FLOW_SILENCE s, at: $at"
    if [ "$try" = 2 ] || ! only_app_lifecycle "$out"; then
      rc=1
      break
    fi
    echo "$name: nothing past stopping and launching the app had run; once more"
  done
  rm -f "$out"
  return "$rc"
}

# Whether every step Maestro finished stops or launches the app.
only_app_lifecycle() {
  ! tr '\r' '\n' <"$1" | grep 'COMPLETED' |
    grep -vqE '^[[:space:]]*(Stop [^ ]+|Launch app "[^"]+")\.\.\. COMPLETED'
}

# maestro_watched LOG ARGS...: `maestro test ARGS`, its output to the job log
# as it comes and to LOG; 124, as timeout(1) says, when it fell silent for
# FLOW_SILENCE seconds and was killed.
maestro_watched() {
  local log=$1 pid tailer size last=-1 changed=$SECONDS
  shift
  : >"$log"
  maestro test "$@" >"$log" 2>&1 &
  pid=$!
  tail -f -n +1 "$log" &
  tailer=$!
  while kill -0 "$pid" 2>/dev/null; do
    size=$(stat -c %s "$log")
    if [ "$size" != "$last" ]; then
      last=$size
      changed=$SECONDS
    fi
    if [ $((SECONDS - changed)) -ge "$FLOW_SILENCE" ]; then
      # Maestro's launcher execs its JVM, so this is Maestro itself; what it
      # started goes with it.
      pkill -TERM -P "$pid" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      sleep 5
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      stop_tailer "$tailer"
      echo
      return 124
    fi
    sleep 1
  done
  wait "$pid"
  local rc=$?
  stop_tailer "$tailer"
  return "$rc"
}

# The tail -f copying a run's output to the job log: a moment for its last
# lines, then gone.
stop_tailer() {
  sleep 2
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
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

# The app as a block alone meets it after seed_host, whatever the blocks
# before it left: every flow launches with clearState false, so the open tabs
# came back restored (a chat tab on the strip, a crowded strip with no ✕), a
# message an earlier block's chat failed to send sat in the outbox at the top
# of the next new chat, and a new chat started in the folder an earlier block
# picked and then deleted. Those three are cleared here, the app stopped
# first so it neither holds nor rewrites them; the host, its key and every
# setting stay. Called at the start of a block, and at the end of one that
# leaves tabs open.
APP_PKG=cloud.brata.terminal
APP_FRESH_SH=/data/local/tmp/e2e-app-fresh.sh
app_fresh() {
  adb shell am force-stop "$APP_PKG" >/dev/null 2>&1
  printf '%s\n' \
    'chmod -R u+rwx files/chat_outbox 2>/dev/null' \
    'rm -rf files/chat_outbox' \
    'p=shared_prefs/FlutterSharedPreferences.xml' \
    '[ -f "$p" ] || exit 0' \
    'sed -i -e "/name=\"flutter\.sshbox\.tabs\.v1\"/d" -e "/name=\"flutter\.sshbox\.chat\.folder\./d" "$p"' \
    'echo "left: $(grep -cE "sshbox\.(tabs\.v1|chat\.folder\.)" "$p") saved tabs or folders, outbox $( [ -e files/chat_outbox ] && echo kept || echo gone)"' |
    adb shell "cat > $APP_FRESH_SH"
  echo "app_fresh: $(adb shell "run-as $APP_PKG sh $APP_FRESH_SH" 2>&1 | tr -d '\r')"
}

# Chat mode's host: three finished Claude Code sessions with transcripts where
# the CLI keeps them, and a claude that lists them, answers a version chat
# takes, and, run as a resumed session, waits quietly on stdin as one with
# nothing new to say. The flows read what chat makes of the transcripts —
# where a conversation comes back to, and how a tool's row reads. Every chat
# block starts here, so the app is made fresh here too (app_fresh).
chat_stand_in() {
  app_fresh
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
  # A listing that never answers, once, where the live stand-in's missed:
  # turn asked for one (chat_working_backstop): its pid kept for the runner.
  agents) if mv "$HOME/.e2e-agents-hang" "$HOME/.e2e-agents-hung" 2>/dev/null; then
      echo $$ >>"$HOME/.e2e-agents-hung"
      exec sleep 3600
    fi
    cat "$HOME/.e2e-agents.json" ;;
  # The SDK's `initialize` on stdin, as chat lists the slash commands with it:
  # answered with ~/.e2e-commands.json where a flow put one; the rest read
  # until stdin ends, as before.
  # `claude -p /usage`, which Claude Code answers itself with no model call:
  # what a flow put in ~/.e2e-usage.txt, or nothing.
  # `--bg`, a new chat's first message: its arguments kept for a flow to read
  # (the model chosen shows in them), and the line a real one prints, naming a
  # session the agents list holds.
  --bg) printf '%s\n' "$*" >"$HOME/.e2e-bg-args"
    echo 'backgrounded · e2e0newc · New chat' ;;
  # chat_ask's stand-in for a `-p` that asks and waits for the answer, where
  # a flow put one; it answers the `initialize` as well.
  -p) if [ -f "$HOME/.e2e-ask.py" ]; then exec python3 "$HOME/.e2e-ask.py"
    elif [ "$2" = /usage ]; then cat "$HOME/.e2e-usage.txt" 2>/dev/null; else
    # Chat's own claude, where a flow asked for a model (~/.e2e-model): the
    # init a real one writes, naming it; a set_model request is kept for the
    # flow to read and answered with success.
    case "$*" in *permission-prompt-tool*) [ -f "$HOME/.e2e-model" ] &&
      printf '%s\n' '{"type":"system","subtype":"init","session_id":"e2e00002-0000-4000-8000-000000000002","model":"claude-opus-5-5"}' ;; esac
    while IFS= read -r line; do
      case $line in
        *'"initialize"'*) cat "$HOME/.e2e-commands.json" 2>/dev/null ;;
        *'"set_model"'*) printf '%s\n' "$line" >>"$HOME/.e2e-model-requests"
          id=${line#*'"request_id":"'}; id=${id%%'"'*}
          printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$id" ;;
      esac
    done; fi ;;
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
                            {'command': 'echo hi',
                             'description': 'List the e2e folder'}, 'hi from e2e'),
                      *tool('toolu_e2e2', 'Write',
                            {'file_path': '/tmp/e2e-tool-rows/notes.txt',
                             'content': 'first line\nsecond line'}, 'ok'),
                      said('Tools done')],
    # #131: a mermaid fence in a reply is drawn as a diagram, not its source.
    'E2E diagram': [user('draw it'),
                    said('Diagram below\n\n```mermaid\ngraph TD\n  E2EA --> E2EB\n```\n\nDiagram above')],
    # #163: a reply's code block, its Copy code beside it, and a word of its
    # own a long press selects.
    'E2E code reply': [user('show code'),
                       said('e2eword\n\n```sh\nprintf e2e-reply\n```')],
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

# #163: each Copy code on an opened tool row copies its block exactly. The
# flow pastes what it copied into the chat's empty box, and the box is read
# here off Android's view tree, the row showing the same text. A toast with
# animations off is gone at once, so they are on meanwhile.
code_ui() {
  adb shell uiautomator dump /sdcard/e2e-ui.xml >/dev/null 2>&1
  adb shell cat /sdcard/e2e-ui.xml 2>/dev/null
}
# The centre of the first node whose attributes match $1, as "x y".
code_at() {
  code_ui | grep -o '<node [^>]*>' | grep -E "$1" | head -1 |
    grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' |
    sed -E 's/bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/' |
    awk '{ print int(($1 + $3) / 2), int(($2 + $4) / 2) }'
}
# What is on the clipboard, pasted into the chat's box: a tap to focus it,
# found again once the keyboard has moved it, a long press, and Paste.
code_paste() {
  local at try
  # Twice: a selection just copied out of the reply keeps its own toolbar
  # up, and the first tap on the box only takes it down.
  for try in 1 2; do
    at=$(code_at 'EditText')
    [ -n "$at" ] || { echo "no chat box on screen"; return 1; }
    adb shell input tap $at
    sleep 1.5
    at=$(code_at 'EditText')
    # shellcheck disable=SC2086
    adb shell input swipe $at $at 900
    sleep 1.5
    at=$(code_at 'text="Paste"|content-desc="Paste"')
    if [ -n "$at" ]; then
      adb shell input tap $at
      sleep 1.5
      return 0
    fi
  done
  echo "no Paste in the box's menu"
  return 1
}
# A long press on the reply's first word, e2eword, near the start of the
# node that holds it, and the toolbar's Copy.
code_select() {
  local box
  box=$(code_ui | grep -o '<node [^>]*>' | grep -E 'e2eword' | grep -v EditText | tail -1 |
    grep -oE 'bounds="\[[0-9]+,[0-9]+\]' | grep -oE '[0-9]+,[0-9]+' | tr , ' ')
  [ -n "$box" ] || { echo "no reply on screen"; return 1; }
  set -- $box
  adb shell input swipe $(($1 + 25)) $(($2 + 12)) $(($1 + 25)) $(($2 + 12)) 900
  sleep 1.5
  box=$(code_at 'text="Copy"|content-desc="Copy"')
  [ -n "$box" ] || { echo "no Copy in the selection's toolbar"; return 1; }
  adb shell input tap $box
  sleep 1
}
# The box's text, trimmed.
code_box() {
  code_ui | grep -o '<node [^>]*EditText[^>]*>' |
    grep -o ' text="[^"]*"' | head -1 | sed 's/^ text="//; s/"$//; s/^ *//; s/ *$//'
}
chat_code_copy() {
  local status=0 got
  adb shell settings put global animator_duration_scale 1
  # Android 13's clipboard preview, drawn over the bottom of the screen after
  # every copy, takes the taps meant for the chat's box: one opened Nearby
  # Share. Off for this block alone.
  adb shell device_config put systemui clipboard_overlay_enabled false
  flow chat_code_copy -e STEP=open || status=1
  code_paste
  got=$(code_box)
  echo "the command's Copy code pasted: '$got'"
  [ "$got" = 'echo hi' ] || { echo "::error::the command's block copied '$got'"; status=1; }
  flow chat_code_copy -e STEP=second || status=1
  code_paste
  got=$(code_box)
  echo "the result's Copy code pasted: '$got'"
  [ "$got" = 'hi from e2e' ] || { echo "::error::the result's block copied '$got'"; status=1; }
  flow chat_code_copy -e STEP=reply || status=1
  code_paste
  got=$(code_box)
  echo "the reply's Copy code pasted: '$got'"
  [ "$got" = 'printf e2e-reply' ] || { echo "::error::the reply's block copied '$got'"; status=1; }
  flow chat_code_copy -e STEP=select || status=1
  code_select
  code_paste
  got=$(code_box)
  echo "a long press and Copy pasted: '$got'"
  [ "$got" = e2eword ] || { echo "::error::a long press copied '$got'"; status=1; }
  flow chat_code_copy -e STEP=done || status=1
  adb shell device_config delete systemui clipboard_overlay_enabled
  adb shell settings put global animator_duration_scale 0
  return "$status"
}

# chat_code_copy alone, for E2E_ONLY: the stand-in's sessions first.
chat_code_copy_alone() {
  chat_stand_in
  chat_code_copy
}

# chat_scroll alone, for E2E_ONLY: the stand-in's sessions first.
chat_scroll_alone() {
  chat_stand_in
  flow chat_scroll
}

# For E2E_ONLY, one run: the model chip's picks, and every flow that opens the
# sessions drawer once a session is picked, now from the ⋮ menu.
chat_ui_cleanup() {
  local status=0 name
  for name in chat_model chat_code_copy_alone chat_scroll_alone \
    chat_session_status chat_images; do
    echo "--- $name"
    "$name" || { echo "::error::$name failed"; status=1; }
  done
  return "$status"
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

# The code editor's save shortcut on Android (.maestro/editor_save.yaml): what
# holds, read off the host and off MainActivity's SaveChord log (a debug
# build's, Ctrl and S keys alone). Ctrl+S is sent with `input keycombination`
# (API 33 and later; the emulator is 34). While an editor page holds the
# focus, MainActivity takes it before the IME and asks Dart to save; anywhere
# else it goes on as before. Asserted:
#   - Ctrl+S with nothing edited writes nothing and types no s;
#   - S alone after an edit types an s and writes nothing;
#   - Ctrl+S after an edit saves, and types no s;
#   - in a terminal, before any editor and after one closed, Ctrl+S reaches
#     the app and MainActivity takes none of it, and the shell reads the
#     same bytes both times: the claim is let go.
# Reported only: whether the emulator's own keyboard device (`adb emu event
# send`) reaches the app at all; in run 38498928025 it did not.
# The file's mtime is put back to 2020 first, so any write at all shows.
editor_save() {
  local status=0 file=/home/$SSH_USER/jeansh-e2e-save.txt old=1577836800
  local heard=/home/$SSH_USER/jeansh-e2e-ctrls.txt before after said
  local last_trail="" heard_bytes=""
  mtime() { sudo stat -c %Y "$file"; }
  # What MainActivity saw of Ctrl and S since the last trail, into
  # last_trail, and printed to stderr so a $( ) round it keeps only its own.
  trail() {
    last_trail=$(adb logcat -d -s SaveChord:I 2>/dev/null | grep -v '^-' | tail -20)
    adb logcat -c 2>/dev/null
    { echo "SaveChord trail ($1):"; echo "$last_trail"; } >&2
  }
  chord() {
    adb shell input keycombination KEYCODE_CTRL_LEFT KEYCODE_S
    sleep 1
    trail 'input keycombination'
  }
  # The chord reached the app (an S down with Ctrl in its meta), and was or
  # was not taken before the IME.
  reached() { grep -q 'pre-IME KEYCODE_S action=0 meta=0x3000' <<<"$last_trail"; }
  took() { grep -q 'pre-IME KEYCODE_S action=0 .*taken=true' <<<"$last_trail"; }
  passed_on() { reached && ! took; }
  # Nothing written in the 3 s after a key.
  unwritten() {
    sleep 3
    [ "$(mtime)" = "$old" ]
  }
  esses() { sudo tr -cd s <"$file" | wc -c | tr -d ' '; }
  # What the terminal's shell reads for one Ctrl+S, as od prints it: XON/XOFF
  # off so ^S is a byte like any other, one line read and the rest restored.
  # Into heard_bytes, and the chord's trail into last_trail, for the caller.
  term_heard() {
    sudo rm -f "$heard"
    adb shell "input text 'stty%s-ixon;head%s-n1%s>jeansh-e2e-ctrls.txt;stty%sixon'"
    adb shell input keyevent KEYCODE_ENTER
    sleep 2
    chord
    sleep 1
    adb shell input keyevent KEYCODE_ENTER
    sleep 2
    if sudo test -e "$heard"; then
      heard_bytes=$(sudo od -An -c "$heard" | tr -s " " | sed "s/^ //")
    else
      heard_bytes='(no file: the line never reached the shell)'
    fi
  }
  check() {
    local what=$1
    shift
    if "$@"; then echo "ok: $what"; else
      echo "::error::editor_save: $what"
      status=1
    fi
  }
  printf 'hello e2e\n' | sudo -u "$SSH_USER" tee "$file" >/dev/null
  sudo touch -d "@$old" "$file"

  # The terminal before any editor was opened: how it hears Ctrl+S today.
  flow editor_save -e STEP=terminal || return 1
  trail launch
  check 'the pre-IME frame is in' grep -q 'frame around' <<<"$last_trail"
  term_heard
  before=$heard_bytes
  echo "terminal heard, no editor yet: $before"
  check "the probe reached the terminal's shell" [ "${before#(no file}" = "$before" ]
  check 'a terminal Ctrl+S reaches the app, not taken (no editor)' passed_on

  flow editor_save -e STEP=open || return 1

  # Ctrl+S with nothing edited: taken, nothing written, no s typed.
  chord
  check 'Ctrl+S in the editor is taken before the IME' took
  check 'Ctrl+S unedited wrote nothing' unwritten
  check 'Ctrl+S unedited left the file as it was' \
    [ "$(sudo cat "$file")" = 'hello e2e' ]
  flow editor_save -e STEP=saved || {
    echo "::error::editor_save: Ctrl+S unedited typed something"
    status=1
  }

  # S alone after an edit: an s typed, nothing written.
  flow editor_save -e STEP=edit || status=1
  adb shell input keyevent KEYCODE_S
  sleep 1
  trail 'S alone'
  check 'S alone wrote nothing' unwritten
  check 'S alone left the file as it was' \
    [ "$(sudo cat "$file")" = 'hello e2e' ]
  flow editor_save -e STEP=dirty || status=1

  # Ctrl+S after the edit: saved, with the one s S typed and no other.
  chord
  sleep 3
  check 'Ctrl+S after an edit wrote the file' [ "$(mtime)" != "$old" ]
  echo "the file now holds:"
  sudo od -c "$file" | head -4
  check 'the save holds the edit' sudo grep -q edit "$file"
  check 'Ctrl+S typed no s (one s, from S alone)' [ "$(esses)" = 1 ]
  flow editor_save -e STEP=saved || status=1

  # Report only: does the emulator's own keyboard device reach the app?
  said=$(adb emu event send EV_KEY:KEY_LEFTCTRL:1 EV_SYN:0:0 \
    EV_KEY:KEY_S:1 EV_SYN:0:0 EV_KEY:KEY_S:0 EV_SYN:0:0 \
    EV_KEY:KEY_LEFTCTRL:0 EV_SYN:0:0 2>&1)
  sleep 1
  trail "adb emu event send: ${said:-(nothing)}"
  if grep -q KEYCODE_S <<<"$last_trail"; then
    echo "report: the emulator's keyboard device reaches the app"
  else
    echo "report: the emulator's keyboard device does not reach the app"
  fi

  # The editor gone, with no relaunch, so a claim never let go would still
  # be held: the terminal hears Ctrl+S as before, and nothing is taken.
  flow editor_save -e STEP=close || status=1
  term_heard
  after=$heard_bytes
  echo "terminal heard, editor closed: $after"
  check 'a terminal Ctrl+S reaches the app, not taken (editor closed)' passed_on
  check 'the terminal hears Ctrl+S as before the editor' [ "$after" = "$before" ]
  sudo rm -f "$heard"
  return "$status"
}

# #253: an .html file opens rendered in a web tab, and a .txt file still opens
# in the editor. Both files go in the login home, the root of the host's file
# tree, and are gone with the runner.
html_tab() {
  app_fresh
  local home=/home/$SSH_USER
  # A title of its own: the tab is named after it, and untitled it was named
  # after the loopback address, a chip wider than the 320 dp emulator's strip
  # that had its ✕ behind the + button.
  printf '<title>E2E page</title>\n<h1>Jeansh e2e heading</h1>\n' |
    sudo -u "$SSH_USER" tee "$home/jeansh-e2e-page.html" >/dev/null
  printf 'Jeansh e2e plain note\n' |
    sudo -u "$SSH_USER" tee "$home/jeansh-e2e-notes.txt" >/dev/null
  flow html_tab || return 1
  flow html_tab_text
}

# A selected tab's ✕ stays in view on a phone-width strip
# (.maestro/tab_close_narrow.yaml): a page whose <title> is over 80
# characters, one whose title is short, and one a script renames from short to
# long after it has loaded. Each is opened from a fresh app and its ✕ tapped
# with no scroll of the strip first.
#
# A ✕ half under + still takes Maestro's tap on its visible half, so the tap
# alone passes with the cap taken out. What the user sees is measured instead,
# off the view tree (uiautomator's, and Maestro's own): the ✕ "Close TITLE"
# ends at or before + ("New tab") begins, starts at or after Home ends, and is
# as wide as the short step's whole ✕ -- a node the strip clips is reported
# clipped, so a ✕ cut at the strip's edge comes out narrower.
narrow_close_in_view() {
  local title=$1 step=$2 xml json out rc
  xml=$(mktemp)
  json=$(mktemp)
  code_ui >"$xml"
  maestro hierarchy >"$json" 2>/dev/null
  out=$(TITLE="$title" STEP="$step" WHOLE="$NARROW_WHOLE" \
    DENSITY="$(adb shell wm density | grep -oE '[0-9]+' | tail -1)" \
    XML="$xml" JSON="$json" python3 - <<'PY'
import json, os, re, sys

title = 'Close ' + os.environ['TITLE']
nodes = []  # (source, label, left, top, right, bottom)

def bounds(text):
    m = re.fullmatch(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', text or '')
    return tuple(int(v) for v in m.groups()) if m else None

for tag in re.findall(r'<node [^>]*>', open(os.environ['XML'], errors='replace').read()):
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', tag))
    b = bounds(attrs.get('bounds'))
    if b:
        for k, v in attrs.items():
            if k != 'bounds' and v:
                nodes.append(('ui', v) + b)

raw = open(os.environ['JSON'], errors='replace').read()
try:
    tree = json.loads(raw[raw.index('{'):])
except ValueError:
    tree = None

def walk(node):
    if isinstance(node, dict):
        attrs = node.get('attributes')
        if isinstance(attrs, dict):
            b = bounds(attrs.get('bounds'))
            if b:
                for k, v in attrs.items():
                    if k != 'bounds' and isinstance(v, str) and v:
                        nodes.append(('maestro', v) + b)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(tree)

def find(label):
    found = sorted({n for n in nodes if n[1] == label}, key=lambda n: (n[0] != 'ui', n[2:]))
    for n in found:
        print('%s %r: [%d,%d][%d,%d] width %d' % ((n[0], n[1]) + n[2:] + (n[4] - n[2],)))
    return found[0] if found else None

close, plus, home = find(title), find('New tab'), find('Home')
if not close or not plus:
    print('FAIL: no %s' % ('✕ ' + repr(title) if not close else '+ (New tab)'))
    sys.exit(1)
width = close[4] - close[2]
whole = int(os.environ['WHOLE'] or 0)
if not whole:
    # No short step to go by: a whole 28 dp button, less a little.
    whole = int(26 * int(os.environ.get('DENSITY') or 160) / 160)
fails = []
if close[4] > plus[2] + 1:
    fails.append('the ✕ ends at %d, past + at %d' % (close[4], plus[2]))
if home and close[2] < home[4] - 1:
    fails.append('the ✕ starts at %d, before Home ends at %d' % (close[2], home[4]))
if width < whole - 2:
    fails.append('the ✕ is %d px wide where a whole one is %d: cut' % (width, whole))
for f in fails:
    print('FAIL: ' + f)
if not fails:
    print('the ✕ is wholly in view, %d px wide, left of + at %d' % (width, plus[2]))
    print('WIDTH %d' % width)
sys.exit(1 if fails else 0)
PY
  )
  rc=$?
  echo "$out" | grep -v '^WIDTH '
  if [ "$rc" = 0 ] && [ "$step" = short ]; then
    NARROW_WHOLE=$(echo "$out" | sed -n 's/^WIDTH //p')
  fi
  rm -f "$xml" "$json"
  return "$rc"
}

tab_close_narrow() {
  local status=0 home=/home/$SSH_USER step title
  local long='Jeansh narrow strip e2e page with a title far too long for a phone strip to show whole'
  printf '<title>%s</title>\n<h1>Jeansh narrow heading</h1>\n' "$long" |
    sudo -u "$SSH_USER" tee "$home/jeansh-e2e-narrow-long.html" >/dev/null
  printf '<title>E2E short</title>\n<h1>Jeansh narrow heading</h1>\n' |
    sudo -u "$SSH_USER" tee "$home/jeansh-e2e-narrow-short.html" >/dev/null
  # history.pushState, so the web view says the page moved and its new title
  # is read: a title set alone is never heard.
  printf '<title>E2E rename</title>\n<h1>Jeansh narrow heading</h1>\n<script>setTimeout(function(){document.title="%s";history.pushState(null,"","#renamed")},3000)</script>\n' \
    "$long" | sudo -u "$SSH_USER" tee "$home/jeansh-e2e-narrow-rename.html" >/dev/null
  # short first: its ✕ is whole in either build, so its width is what a whole
  # ✕ measures, for the long ones to be held to.
  NARROW_WHOLE=
  for step in short long rename; do
    case $step in
      short) title='E2E short' ;;
      *) title=$long ;;
    esac
    echo "::group::tab_close_narrow: $step"
    app_fresh
    if ! flow tab_close_narrow -e "STEP=$step" -e "FILE=jeansh-e2e-narrow-$step" \
      -e "TITLE=$title"; then
      status=1
      echo "::error::tab_close_narrow $step failed before the ✕ was measured"
    elif ! narrow_close_in_view "$title" "$step"; then
      status=1
      echo "::error::tab_close_narrow $step: the ✕ is not wholly in view"
    elif ! flow tab_close_narrow_close -e "TITLE=$title"; then
      status=1
      echo "::error::tab_close_narrow $step: a tap on the ✕ did not close the tab"
    fi
    echo "::endgroup::"
  done
  keep_shots 'tab-close-narrow-*.png'
  sudo -u "$SSH_USER" rm -f "$home/jeansh-e2e-narrow-long.html" \
    "$home/jeansh-e2e-narrow-short.html" "$home/jeansh-e2e-narrow-rename.html"
  return "$status"
}

# #272: an HTML file opens with the files beside it, and only those
# (.maestro/html_site.yaml). The site is in the login home, jeansh-e2e-site/,
# with a secret file BESIDE the folder that no page of it may reach, a 6 MB
# script, and a link to /etc/hostname. A page that is not allowed something is
# said so in the tab, and what it would have got is not on screen.
html_site() {
  local status=0 leak
  sudo -u "$SSH_USER" -H sh -s <<'EOS'
cd "$HOME" || exit 1
rm -rf jeansh-e2e-site jeansh-e2e-secret.txt
mkdir jeansh-e2e-site
printf 'SECRET-TOKEN' >jeansh-e2e-secret.txt
cd jeansh-e2e-site || exit 1
printf '%s' '<!doctype html><meta charset=utf-8><link rel=stylesheet href=style.css><h1 id=t>plain</h1><img alt="PIC" src=pic.png><script src=app.js></script>' >page.html
printf '#t{color:red}' >style.css
printf "document.getElementById('t').textContent='Jeansh e2e js ran'" >app.js
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d >pic.png
printf '%s' '<!doctype html><meta charset=utf-8><p id=x>evil</p><script src="../jeansh-e2e-secret.txt"></script><script>fetch("../jeansh-e2e-secret.txt").then(function(r){return r.ok?r.text():""}).then(function(t){document.getElementById("x").textContent+=" "+t}).catch(function(){})</script>' >evil.html
printf '%s' '<!doctype html><meta charset=utf-8><p>big</p><script src=big.js></script>' >big.html
dd if=/dev/zero of=big.js bs=1048576 count=6 2>/dev/null
ln -s /etc/hostname leak.png
printf '%s' '<!doctype html><meta charset=utf-8><p id=x>link</p><img src=leak.png><script>fetch("leak.png").then(function(r){return r.ok?r.text():""}).then(function(t){document.getElementById("x").textContent+=" "+t}).catch(function(){})</script>' >link.html
printf 'plain text\n' >plain.txt
printf '%s' '<!doctype html><meta charset=utf-8><meta http-equiv=refresh content="0;url=mailto:a@b.c"><p>gate page</p>' >gate.html
EOS
  leak=$(tr -d '\n' </etc/hostname)
  [ -n "$leak" ] || leak=hostname-unknown-e2e
  echo "the link's target holds: $leak"
  local step
  for step in page plaintext evil big link gate; do
    echo "::group::html_site: $step"
    flow html_site -e "STEP=$step" -e "LEAK=$leak" || {
      status=1
      echo "::error::html_site $step failed"
    }
    if [ "$step" = gate ]; then
      # No page navigation reached another app: Jeansh is still the one in front.
      local front
      front=$(adb shell dumpsys activity activities | grep -m1 -E 'mResumedActivity|ResumedActivity')
      echo "in front: $front"
      case $front in
        *cloud.brata.terminal*) ;;
        *) echo "::error::html_site gate: another app is in front"; status=1 ;;
      esac
    fi
    echo "::endgroup::"
  done
  keep_shots 'html-site-*.png'
  sudo -u "$SSH_USER" -H sh -c 'cd "$HOME" && rm -rf jeansh-e2e-site jeansh-e2e-secret.txt'
  return "$status"
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

# A finished session picked in chat's sidebar is continued in the directory it
# ran in (.maestro/chat_continue_cwd.yaml), and a tool the CLI asks to use is
# said once to have been refused. The stand-in (tools/e2e_cwd_claude.py) logs
# where each `claude -p` and `--bg` ran, which is read here: the continuation
# ran in the picked session's folder with --resume and not in the chat's root,
# the new chat's first message ran in the folder chosen for it with no
# --resume, and the refusal notice is one node on screen after two requests.
chat_continue_cwd() {
  local status=0 home=/home/$SSH_USER calls=/home/$SSH_USER/.e2e-cwd-calls
  local app=$home/e2e-cont/app-x other=$home/e2e-cont/other
  local sid=e2e00010-0000-4000-8000-000000000010 first n
  chat_stand_in
  end_live_session
  sudo -u "$SSH_USER" mkdir -p "$app" "$other"
  sudo install -o "$SSH_USER" -m 644 tools/e2e_cwd_claude.py "$home/.e2e-cwd-claude.py"
  sudo -u "$SSH_USER" HOME="$home" APP="$app" SID="$sid" python3 - <<'PY'
import json, os
home, app, sid = os.environ['HOME'], os.environ['APP'], os.environ['SID']
path = os.path.join(home, '.e2e-agents.json')
rows = json.load(open(path))
rows.append({'id': 'e2e0cont', 'sessionId': sid, 'cwd': app, 'kind': 'background',
             'name': 'E2E cont cwd', 'state': 'done', 'startedAt': 1790000000300})
json.dump(rows, open(path, 'w'))
d = os.path.join(home, '.claude', 'projects', app.replace('/', '-'))
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, sid + '.jsonl'), 'w') as f:
    for e in ({'type': 'user', 'message': {'role': 'user', 'content': 'Earlier cont question'}},
              {'type': 'assistant', 'message': {'role': 'assistant',
               'content': [{'type': 'text', 'text': 'Earlier cont answer'}]}}):
        f.write(json.dumps(e) + '\n')
PY
  put_stand_in <<'SH'
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  -p|--bg) exec python3 "$HOME/.e2e-cwd-claude.py" "$@" ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo rm -f "$calls"
  flow chat_continue_cwd -e STEP=plain || status=1
  first=$(sudo head -n1 "$calls" 2>/dev/null)
  echo "the continuation's start: $first"
  case $first in
    *"\"pwd\": \"$app\""*"--resume $sid"*) ;;
    *) echo "::error::the picked session was not resumed in $app: $first"; status=1 ;;
  esac
  flow chat_continue_cwd -e STEP=tool || status=1
  n=$(code_ui | grep -o '<node [^>]*Bash was refused[^>]*>' | wc -l | tr -d ' ')
  echo "refusal notices on screen: $n"
  [ "$n" = 1 ] || { echo "::error::$n refusal notices, not 1"; status=1; }
  sudo rm -f "$calls"
  flow chat_continue_cwd -e STEP=new -e "OTHER=$other" || status=1
  first=$(sudo grep '"mode": "bg"' "$calls" 2>/dev/null | head -n1)
  echo "the new chat's start: $first"
  case $first in
    *"\"pwd\": \"$other\""*) ;;
    *) echo "::error::the new chat did not start in $other: $first"; status=1 ;;
  esac
  case $first in
    *--resume*|*"$app"*) echo "::error::the new chat's start carried the picked session"; status=1 ;;
  esac
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-continue-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -rf "$calls" "$home/e2e-cont" "$home/.e2e-cwd-claude.py" "$home/.claude/projects/-home-$SSH_USER-e2e-cont-app-x"
  # Its flow leaves a shell and a chat tab open and the folder chip on
  # e2e-cont/other, just deleted: the next chat_version found the chat tab
  # restored, and every new chat after it was "Not started" there.
  app_fresh
  stand_in ''
  return "$status"
}

# #251: a share into Jeansh while a chat tab is showing goes into that chat's
# box, and nothing is sent. The stand-in keeps every `--bg` and `-p` it is run
# with, so a message or session started by the share would show in its count;
# `cat` on the shell tab shows the terminal got nothing. Three cases, each with
# its own text: the chat showing (the box holds it, the file stays empty), the
# shell showing (the text reaches the file, as share_text has it, and a chat
# opened after has an empty box) and a picture (an [Image #1] card). The
# picture is put where the app's own provider serves it, since a shell-owned
# path is not readable by the app.
share_chat() {
  local status=0 out=/tmp/e2e-shared.txt calls=/home/$SSH_USER/.e2e-share-calls
  local main=cloud.brata.terminal/dev.triasbrata.sshbox.MainActivity
  local share="am start -W -a android.intent.action.SEND -n cloud.brata.terminal/dev.triasbrata.sshbox.ShareActivity"
  local text got records before after png=$ROOT/build/e2e-share.png
  chat_stand_in
  end_live_session
  put_stand_in <<'SH'
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  --bg) printf '%s\n' "$*" >>"$HOME/.e2e-share-calls"; exec cat >/dev/null ;;
  -p) printf '%s\n' "$*" >>"$HOME/.e2e-share-calls"
    while IFS= read -r line; do :; done ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo rm -f "$calls" "$out"

  # Positive: the chat showing.
  text="shared into the chat $(date +%s%N)"
  flow share_chat_open || return 1
  before=$(sudo cat "$calls" 2>/dev/null | wc -l | tr -d ' ')
  adb shell "$share -t text/plain --es android.intent.extra.TEXT '$text'" >/dev/null || return 1
  sleep 3
  records=$(adb shell dumpsys activity activities |
    grep -oE "ActivityRecord\{[0-9a-f]+ u0 $main" | sort -u | wc -l | tr -d ' ')
  flow share_chat_text_finish -e "TEXT=$text" || status=1
  sleep 1
  after=$(sudo cat "$calls" 2>/dev/null | wc -l | tr -d ' ')
  got=$(sudo cat "$out" 2>/dev/null)
  echo "chat showing: the file holds '$got'; MainActivity records: $records; stand-in calls $before -> $after"
  [ -z "$got" ] || { echo "::error::the terminal got '$got' of a share meant for the chat"; status=1; }
  [ "$records" -eq 1 ] || { echo "::error::$records MainActivity records"; status=1; }
  [ "$before" = "$after" ] || { echo "::error::the share sent something to claude"; status=1; }

  # Negative: the shell showing.
  sudo rm -f "$out"
  text="shared into the shell $(date +%s%N)"
  flow share_text_start || return 1
  adb shell "$share -t text/plain --es android.intent.extra.TEXT '$text'" >/dev/null || return 1
  sleep 3
  flow share_chat_shell_finish -e "TEXT=$text" || status=1
  sleep 1
  got=$(sudo cat "$out" 2>/dev/null)
  echo "shell showing: the file holds '$got'"
  [ "$got" = "$text" ] || { echo "::error::the shell's share did not reach the file"; status=1; }

  # A picture, with the chat showing.
  python3 - "$png" <<'PY' || return 1
import struct, sys, zlib
def chunk(k, d):
    c = struct.pack('>I', len(d)) + k + d
    return c + struct.pack('>I', zlib.crc32(k + d))
raw = b'\x00' + bytes((230, 20, 20)) * 8
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 1, 8, 2, 0, 0, 0)) \
    + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
  adb push "$png" /data/local/tmp/e2e-share.png >/dev/null || return 1
  adb shell "run-as cloud.brata.terminal sh -c 'mkdir -p cache/clip && cp /data/local/tmp/e2e-share.png cache/clip/e2e-share.png'" || return 1
  flow share_chat_open || return 1
  adb shell "$share -t image/png --eu android.intent.extra.STREAM content://cloud.brata.terminal.files/clip/e2e-share.png" >/dev/null || return 1
  sleep 3
  flow share_chat_pic_finish || status=1

  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-share-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -f "$calls" "$out"
  adb shell rm -f /data/local/tmp/e2e-share.png
  adb shell run-as cloud.brata.terminal rm -f cache/clip/e2e-share.png
  stand_in ''
  return "$status"
}

# The chat button's Claude Code check, UAT issue #22: one flow, three hosts, the
# stand-in swapped between them. It gates the release (GATING_UNITS). Each
# expected toast is the app's own wording (ClaudeChat.versionRefusal).
chat_version_case() {
  local label=$1 answer=$2 expect=$3 shot=chat-version-$1 found status=0
  echo "::group::chat_version: $label (gating)"
  app_fresh
  stand_in "$answer"
  # Said here, from the host, so a run that finds no toast shows whether the
  # stand-in was in place or the toast simply came and went unseen.
  echo "the host's claude --version now answers: $(sudo -u "$SSH_USER" sh -lc \
    'c=$HOME/.local/bin/claude; [ -x "$c" ] && "$c" --version || echo "(no claude)"')"
  # A bare name: Maestro 2.10 refuses a screenshot path that resolves outside its
  # own directory, and this one gets moved into the evidence folder after.
  flow chat_version -e "EXPECT=$expect" -e "SHOT=$shot" || {
    status=1
    echo "::error::chat_version ($label) failed -- gating"
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
  # Its task store, if tasks: wrote one: this session's folder alone.
  [ -n "$LIVE_SID" ] && sudo rm -rf "/home/$SSH_USER/.claude/tasks/$LIVE_SID"
  # Its sub-agents, if agents: wrote any: this session's folder alone.
  [ -n "$LIVE_SID" ] && sudo rm -rf "/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID"
  # And its transcript, which live_session appends to: kept, every block's
  # turns were still there for the next, a usage chip reading an earlier
  # block's last request among them.
  [ -n "$LIVE_SID" ] && sudo rm -f "/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl"
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

# The working line's backstop with a hung listing (fix/chat-listing-timeout):
# a watched turn whose end is never written ends only when two looks at
# `claude agents` find the session idle, and a listing that never answers
# must not hold those looks for good. One case a fresh live session, with a
# fresh listing so no row of the last case is read first, and a session id of
# its own: under one id, a case opened the last case's transcript, its turn
# still open, and a message the chat still held for that session reached this
# one's pane. The cases are in .maestro/chat_working_backstop.yaml.
backstop_case() { # CASE WORD SID
  local status=0 home=/home/$SSH_USER
  # live_session and end_live_session read LIVE_SID: this case's, for both.
  local LIVE_SID=$3
  chat_stand_in
  end_live_session
  sudo rm -f "$home/.e2e-agents-hang" "$home/.e2e-agents-hung" "$home/.e2e-pane-lines.log"
  live_session
  flow chat_working_backstop -e "CASE=$1" -e "WORD=$2" || status=1
  echo "lines that reached the pane in $1 (meant: '$2: go'), $(sudo cat \
    "$home/.e2e-pane-lines.log" 2>/dev/null | wc -l) of them:"
  sudo cat "$home/.e2e-pane-lines.log" 2>/dev/null | sed 's/^/  > /'
  # The case's own word, and no other case's, or it tested something else.
  if ! sudo grep -qix "$2: go" "$home/.e2e-pane-lines.log" 2>/dev/null; then
    echo "::error::$1: '$2: go' never reached the pane"
    status=1
  elif sudo grep -vix "$2: go" "$home/.e2e-pane-lines.log" 2>/dev/null | grep -qi '^missed'; then
    echo "::error::$1: another case's word reached the pane"
    status=1
  fi
  # Whether a listing hung, as the case asked: else it proved nothing.
  if [ "$1" = plain ]; then
    if sudo test -e "$home/.e2e-agents-hung"; then
      echo "::error::$1: a listing hung where none was asked for"
      status=1
    fi
  elif ! sudo test -e "$home/.e2e-agents-hung"; then
    echo "::error::$1: no listing hung, so the case proved nothing"
    status=1
  fi
  # The hung listing's sleep, by the pid it kept: nothing else.
  for pid in $(sudo cat "$home/.e2e-agents-hung" 2>/dev/null | grep -E '^[0-9]+$'); do
    sudo kill "$pid" 2>/dev/null
  done
  sudo rm -f "$home/.e2e-agents-hang" "$home/.e2e-agents-hung"
  # This case's pane and its transcript, so nothing of it is left to the next.
  end_live_session
  sudo rm -f "$home/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl"
  echo "chat_working_backstop $1: $([ "$status" -eq 0 ] && echo passed || echo FAILED)"
  return "$status"
}
chat_working_backstop() {
  local status=0
  backstop_case hang missed e2e00006-0000-4000-8000-0000000000b1 || status=1
  backstop_case busy missedbusy e2e00006-0000-4000-8000-0000000000b2 || status=1
  backstop_case plain missedplain e2e00006-0000-4000-8000-0000000000b3 || status=1
  keep_shots 'chat-backstop-*.png'
  stand_in ''
  return "$status"
}

# A sub-agent's work opened from its Agent row, read-only and live, and the
# one it started in turn, against the stand-in's agents: turn, which writes
# the files 2.1.300 writes under <session>/subagents.
chat_subagents() {
  local status=0
  chat_stand_in
  end_live_session
  live_session
  flow chat_subagents || status=1
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-subagents-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_live_session
  stand_in ''
  return "$status"
}

# The usage chip over chat's box and its popup: the context of the last request
# the session made, and the plan's usage as the host's `claude -p /usage`
# prints it, against the stand-in's usage: turn and a ~/.e2e-usage.txt.
chat_usage() {
  local status=0 home=/home/$SSH_USER
  chat_stand_in
  end_live_session
  live_session
  sudo -u "$SSH_USER" tee "$home/.e2e-usage.txt" >/dev/null <<'TXT'
You are currently using your subscription to power your Claude Code usage

Current session: 65% used · resets Oct 2, 3:59pm (Asia/Example)
Current week (all models): 28% used · resets Oct 9, 2:59am (Asia/Example)
Current week (Fable): 0% used · resets Oct 9, 3am (Asia/Example)
TXT
  flow chat_usage || status=1
  # On a failure the popup is still up, as Maestro left it: what Android's
  # accessibility tree, which Maestro reads, holds of it (#303's run showed
  # the row on screen and Maestro not finding it).
  if [ "$status" != 0 ]; then
    # A screenshot at the same moment, to say whether the popup is still up.
    adb exec-out screencap -p >"$EVIDENCE/chat-usage-at-dump.png" 2>/dev/null &&
      echo "evidence: chat-usage-at-dump.png"
    code_ui | grep -o '<node [^>]*>' |
      grep -E 'Context|Usage|claude-opus|as of' | sed 's/^/ui: /'
    # And what Maestro itself reads, which may differ from uiautomator's.
    maestro hierarchy 2>/dev/null | grep -E 'Context|Usage|claude-opus|as of' |
      sed 's/^/maestro: /' | cut -c1-300
  fi
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-usage-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -f "$home/.e2e-usage.txt"
  end_live_session
  stand_in ''
  return "$status"
}

# After /compact: a marker whose tap shows and hides the summary, never a
# bubble of the user's, and the ring reading "Context compacted…" until the
# next reply, against the stand-in's usage:, compact: and recount: turns.
chat_compact() {
  local status=0
  chat_stand_in
  end_live_session
  live_session
  flow chat_compact || status=1
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-compact-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_live_session
  stand_in ''
  return "$status"
}

# #214: the model chip over chat's box. A new chat started on Sonnet runs
# `claude --bg --model sonnet`; chat's own claude, continuing a finished
# session, is sent set_model and its chip follows the answer; a session
# watched live in a tmux pane is typed /model haiku; one at a terminal outside
# tmux, read-only, only says how to change its model. Against the stand-in's
# --bg and -p, which keep what they were sent in ~/.e2e-bg-args and
# ~/.e2e-model-requests, the live pane's ~/.e2e-pane-lines.log, and a
# read-only session that is a bare process with no terminal.
RO_SID=e2e0000a-bbbb-4000-8000-00000000b001
chat_model() {
  local status=0 home=/home/$SSH_USER ro_pid lines
  local projects=/home/$SSH_USER/.claude/projects/-home-$SSH_USER
  chat_stand_in
  end_live_session
  live_session
  sudo rm -f "$home/.e2e-bg-args" "$home/.e2e-model-requests" "$home/.e2e-pane-lines.log"
  sudo -u "$SSH_USER" touch "$home/.e2e-model"
  # Interactive, outside tmux: a process of the user's with no terminal, so
  # chat finds no pane for it and watches it read-only.
  ro_pid=$(sudo -u "$SSH_USER" sh -c 'setsid sleep 900 </dev/null >/dev/null 2>&1 & echo $!')
  # The session `--bg` names, which the agents list must hold (an id of 8
  # characters or more): a finished one, so chat continues it as its own.
  sudo -u "$SSH_USER" HOME="$home" python3 - "$RO_SID" "$ro_pid" <<'PY'
import json, os, sys
home, sid, pid = os.environ['HOME'], sys.argv[1], int(sys.argv[2])
path = os.path.join(home, '.e2e-agents.json')
rows = json.load(open(path))
rows.append({'id': 'e2e0newc', 'cwd': home, 'kind': 'background',
             'startedAt': 1790000000100, 'sessionId': 'e2e00002-0000-4000-8000-000000000002',
             'name': 'New chat', 'state': 'done'})
rows.append({'kind': 'interactive', 'pid': pid, 'sessionId': sid,
             'name': 'E2E terminal session', 'cwd': home, 'status': 'idle',
             'startedAt': 1790000000200})
json.dump(rows, open(path, 'w'))
d = os.path.join(home, '.claude', 'projects', home.replace('/', '-'))
with open(os.path.join(d, sid + '.jsonl'), 'w') as f:
    for e in ({'type': 'user', 'message': {'role': 'user', 'content': 'At the desk'}},
              {'type': 'assistant', 'message': {'role': 'assistant',
               'content': [{'type': 'text', 'text': 'Answered at the desk'}]}}):
        f.write(json.dumps(e) + '\n')
PY
  # With the emulator's animations off a toast is gone at once.
  adb shell settings put global animator_duration_scale 1
  flow chat_model || status=1
  adb shell settings put global animator_duration_scale 0
  if ! sudo grep -q -- '--model sonnet' "$home/.e2e-bg-args" 2>/dev/null; then
    echo "::error::the new chat's claude --bg was not given --model sonnet:" \
      "$(sudo cat "$home/.e2e-bg-args" 2>/dev/null)" >&2
    status=1
  fi
  if ! sudo grep -q '"subtype":"set_model","model":"haiku"' \
    "$home/.e2e-model-requests" 2>/dev/null; then
    echo "::error::chat's claude was never sent set_model haiku" >&2
    status=1
  fi
  echo "set_model requests: $(sudo cat "$home/.e2e-model-requests" 2>/dev/null)"
  # The live pane got exactly one line, /model haiku, and its record has it.
  lines=$(sudo cat "$home/.e2e-pane-lines.log" 2>/dev/null)
  echo "lines typed into the live pane: ${lines:-none}"
  if [ "$lines" != '/model haiku' ]; then
    echo "::error::the live pane was not typed exactly /model haiku" >&2
    status=1
  fi
  if ! sudo grep -q 'command-name>/model<' "$projects/$LIVE_SID.jsonl" 2>/dev/null; then
    echo "::error::the live session's record holds no /model" >&2
    status=1
  fi
  # The read-only session: its record as it was written, nothing added.
  if sudo grep -q 'model' "$projects/$RO_SID.jsonl" 2>/dev/null ||
    [ "$(sudo wc -l <"$projects/$RO_SID.jsonl")" != 2 ]; then
    echo "::error::something reached the read-only session" >&2
    status=1
  fi
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-model-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  [ -n "$ro_pid" ] && sudo kill "$ro_pid" 2>/dev/null
  sudo rm -f "$home/.e2e-bg-args" "$home/.e2e-model-requests" "$home/.e2e-model" \
    "$home/.e2e-pane-lines.log" "$projects/$RO_SID.jsonl"
  end_live_session
  stand_in ''
  return "$status"
}

# For E2E_ONLY: chat_version right after chat_continue_cwd, as the full run
# has them, which is where the chat tab and the folder chip left behind used
# to make it fail. Fails if chat_version does.
chat_version_after_cwd() {
  chat_continue_cwd || echo "::warning::chat_continue_cwd failed (not what this block checks)"
  chat_version
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
  app_fresh
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

# Typing into a running `claude --bg` session through `claude attach`
# (.maestro/chat_attach_deliver.yaml), against chat_images' host and its
# "E2E pictures live" session, whose attach is the stand-in's raw input line.
# Measured on 2.1.287: a turn over while a shell it started in the background
# runs is listed busy and done, and takes a message typed then; the input line
# is one for every attach, so a draft at a terminal is in it.
#   1. busy, done:    typed at once, not Queued          (positive, (a))
#   2. busy, working: Queued, nothing typed; then done,  (negative, (a))
#                     typed, the shell still running
#   3. a draft there: refused, nothing typed, no Enter   (negative, (b))
# 1 is also (b)'s positive: an empty line is typed into.
attach_row() { # status state
  sudo -u "$SSH_USER" -H python3 - "${PICS_SIDS[1]}" "$@" <<'PY'
import json, os, sys
sid, status, state = sys.argv[1:4]
path = os.path.join(os.environ['HOME'], '.e2e-agents.json')
rows = json.load(open(path))
for row in rows:
    if row.get('sessionId') == sid:
        row.update(status=status, state=state)
json.dump(rows, open(path, 'w'))
PY
}

# The events the stand-in's input line logged for MSG: text typed, or an Enter.
attach_got() { # ev MSG
  sudo python3 - "/home/$SSH_USER/.e2e-pics.log" "$@" <<'PY'
import json, sys
log, ev, msg = sys.argv[1:4]
n = 0
for line in open(log):
    e = json.loads(line) if line.strip() else {}
    if e.get("ev") == ev and msg.lower() in (e.get("v") or e.get("text") or "").lower():
        n += 1
print(n)
PY
}

chat_attach_deliver() {
  app_fresh
  local status=0 log=/home/$SSH_USER/.e2e-pics.log s=(-e "SESSION=E2E pictures live")
  attach_check() { # what count want
    if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "::error::❌ $1: $2, not $3"; status=1; fi
  }
  pics_host || return 1
  sudo rm -f "/home/$SSH_USER/.e2e-attach-draft"
  flow chat_attach_deliver -e STEP=open "${s[@]}" || status=1

  echo "::group::chat_attach_deliver 1: busy and done, a shell still running"
  sudo truncate -s 0 "$log"
  attach_row busy done
  flow chat_attach_deliver -e STEP=send "${s[@]}" -e "MSG=shell still runs" \
    -e "SEE=(?i)Echo: shell still runs" -e SHOT=shell || status=1
  attach_check "1: typed into the session once" "$(attach_got enter 'shell still runs')" 1
  echo "::endgroup::"

  echo "::group::chat_attach_deliver 2: busy and working, mid-turn"
  sudo truncate -s 0 "$log"
  attach_row busy working
  flow chat_attach_deliver -e STEP=send "${s[@]}" -e "MSG=wait for the turn" \
    -e "SEE=Queued: it runs after" -e SHOT=queued || status=1
  sleep 8
  attach_check "2: nothing typed mid-turn" "$(attach_got text 'wait for the turn')" 0
  attach_row busy done
  flow chat_attach_deliver -e STEP=see "${s[@]}" -e "SEE=(?i)Echo: wait for the turn" \
    -e SHOT=released || status=1
  attach_check "2: typed once the turn ended, the shell still running" \
    "$(attach_got enter 'wait for the turn')" 1
  echo "::endgroup::"

  echo "::group::chat_attach_deliver 3: a draft at the terminal"
  sudo truncate -s 0 "$log"
  attach_row idle done
  printf 'half typed' | sudo -u "$SSH_USER" -H tee "/home/$SSH_USER/.e2e-attach-draft" >/dev/null
  flow chat_attach_deliver -e STEP=send "${s[@]}" -e "MSG=not with the draft" \
    -e "SEE=Something is typed into" -e SHOT=draft || status=1
  sleep 3
  echo "the stand-in's log:"; sudo cat "$log"
  attach_check "3: the attach saw the draft" "$(attach_got draft 'half typed')" 1
  attach_check "3: nothing typed after it" "$(attach_got text 'not with the draft')" 0
  attach_check "3: no Enter" "$(attach_got enter '')" 0
  sudo rm -f "/home/$SSH_USER/.e2e-attach-draft"
  echo "::endgroup::"

  keep_shots 'chat-attach-*.png'
  sudo -u "$SSH_USER" -H tmux kill-session -t e2e-pics 2>/dev/null
  for pid in "${pics_pids[@]}"; do sudo kill "$pid" 2>/dev/null; done
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

# Chat answers a question a WATCHED session asks (.maestro/chat_ask_watched.yaml):
# a claude --bg session through `claude attach`, and Claude in a tmux pane, the
# picks typed into the session's own dialog. The stand-in is
# tools/e2e_ask_watched.py, whose dialog takes the keys a real 2.1.287 was
# measured to take and logs every one to ~/.e2e-ask.log. The flow can see only
# the card; what reached the dialog is read from that log after each run: the
# keys, how many attaches were opened, whether the session still waits, and
# that no shell syntax typed as an answer was run.
ask_pids=()
ask_check() { # KIND
  sudo python3 - "/home/$SSH_USER" "$1" <<'PY'
import json, os, sys
home, kind = sys.argv[1:3]
events = [json.loads(l) for l in open(os.path.join(home, '.e2e-ask.log')) if l.strip()]
n = {'single': 1, 'multi': 2, 'two': 3, 'other': 4, 'perm': 5, 'pane': 6}[kind]
sid = 'e2e00000-0000-4000-8000-00000000a%03d' % n
keys = []
for e in events:
    if e['ev'] != 'key' or e['sid'] != sid:
        continue
    if e['k'] in ('char', 'space'):
        if keys and keys[-1].startswith('text:'):
            keys[-1] += e['c']
        else:
            keys.append('text:' + e['c'])
    else:
        keys.append(e['k'])
# A lone space byte is the Space key (a real dialog reads it so); only a run
# with other characters in it is text.
keys = ['space' if k == 'text: ' else k for k in keys]
attaches = [e for e in events if e['ev'] == 'attach-id' and e['id'] == 'e2eask%02d' % n]
answered = [e['answers'] for e in events if e['ev'] == 'answered' and e['sid'] == sid]
rows = json.load(open(os.path.join(home, '.e2e-agents.json')))
waiting = next(r.get('waitingFor') for r in rows if r['sessionId'] == sid)
# Measured on 2.1.287: Down and Enter for a choice, Space, Down and Tab for
# several (Enter submits the review), the words typed on "Type something."
want = {
    'single': (['down', 'enter'], 1, [{'Which fruit?': 'Banana'}], None),
    'multi': (['space', 'down', 'down', 'space', 'tab', 'enter'], 1,
              [{'Which colours?': 'Red, Blue'}], None),
    'two': (['down', 'enter', 'enter', 'enter'], 1,
            [{'Which size?': 'Large', 'Which shape?': 'Circle'}], None),
    'other': (['down', 'down', 'text:Lisbon $(touch x)', 'enter'], 1,
              [{'Which city?': 'Lisbon $(touch x)'}], None),
    # Nothing typed, no attach opened, still waiting for the permission.
    'perm': ([], 0, [], 'permission prompt'),
    # The pane is not an attach: its keys came through tmux.
    'pane': (['down', 'enter'], 0, [{'Which drink?': 'Coffee'}], None),
}[kind]
problems = []
if keys != want[0]:
    problems.append(f'the dialog got keys {keys}, not {want[0]}')
if len(attaches) != want[1]:
    problems.append(f'{len(attaches)} attaches opened, not {want[1]}')
if answered != want[2]:
    problems.append(f'the transcript recorded {answered}, not {want[2]}')
if waiting != want[3]:
    problems.append(f'the session is listed waitingFor {waiting!r}, not {want[3]!r}')
if kind == 'other':
    for path in ('x', '/x', '/tmp/x'):
        full = path if path.startswith('/') else os.path.join(home, path)
        if os.path.exists(full):
            problems.append(f'{full} exists: the typed $(touch x) ran')
for p in problems:
    print('::error::chat_ask_watched ' + kind + ': ' + p)
print(f'{kind}: keys {keys}, attaches {len(attaches)}, recorded {answered}, waitingFor {waiting!r}')
sys.exit(1 if problems else 0)
PY
}

chat_ask_watched() {
  local status=0 home=/home/$SSH_USER as=(sudo -u "$SSH_USER" -H) log=/home/$SSH_USER/.e2e-ask.log
  local kind pid pids='' pane
  chat_stand_in
  end_live_session
  if "${as[@]}" tmux has-session -t e2e-ask 2>/dev/null ||
    sudo find "$home/.claude/sessions" -name '*.json' 2>/dev/null | grep -q .; then
    echo "::error::the host already has a live session; not starting another" >&2
    return 1
  fi
  sudo install -o "$SSH_USER" -m 644 tools/e2e_ask_watched.py "$home/.e2e-ask-watched.py"
  put_stand_in <<'SH'
p=$HOME/.e2e-ask-watched.py
case "$1" in
  --version) echo '2.1.287 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  attach) exec env PYTHONIOENCODING=utf-8 python3 "$p" --attach "$2" ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo rm -f "$log"
  "${as[@]}" python3 "$home/.e2e-ask-watched.py" --seed-transcripts || return 1
  # The background sessions' processes: a sleep each, as live ones.
  ask_pids=()
  for kind in single multi two other perm; do
    pid=$("${as[@]}" sh -c 'setsid sleep 3600 </dev/null >/dev/null 2>&1 & echo $!')
    ask_pids+=("$pid")
    pids="$pids\"$kind\": $pid, "
  done
  # The interactive one, in a tmux pane of its own.
  "${as[@]}" sh -c 'cd && LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux new-session -d -s e2e-ask \
    -x 120 -y 30 "exec env PYTHONIOENCODING=utf-8 python3 $HOME/.e2e-ask-watched.py --pane $1"' \
    sh e2e00000-0000-4000-8000-00000000a006 || return 1
  sleep 1
  pane=$("${as[@]}" tmux list-panes -t e2e-ask -F '#{pane_pid}')
  "${as[@]}" python3 "$home/.e2e-ask-watched.py" --seed-rows "{${pids}\"pane\": $pane}" || return 1
  echo "ask host: sleeps ${ask_pids[*]}, pane pid $pane"
  for kind in single multi two other perm pane; do
    echo "-- chat_ask_watched: $kind"
    sudo truncate -s 0 "$log" 2>/dev/null
    # Whatever a failed run left on top (a system picker) is sent away first,
    # so one failure cannot take the runs after it down.
    adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1
    adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    flow chat_ask_watched -e "KIND=$kind" -e "SESSION=E2E ask $kind" ||
      { echo "::error::chat_ask_watched failed at its '$kind' run"; status=1; }
    echo "the stand-in's log for $kind:"
    sudo cat "$log" 2>/dev/null
    ask_check "$kind" || status=1
    keep_shots 'chat-ask-watched-*.png'
  done
  # Only what this started: the tmux session, the sleeps, the stand-in, and
  # these sessions' transcripts and state file.
  "${as[@]}" tmux kill-session -t e2e-ask 2>/dev/null
  for pid in "${ask_pids[@]}"; do sudo kill "$pid" 2>/dev/null; done
  sudo find "$home/.claude/projects" -name 'e2e00000-0000-4000-8000-00000000a0*.jsonl' -delete 2>/dev/null
  sudo find "$home/.claude/sessions" -name '*.json' \
    -exec grep -l '"sessionId":"e2e00000-' {} + 2>/dev/null | xargs -r sudo rm -f
  sudo rm -f "$home/.e2e-ask-watched.py"
  stand_in ''
  return "$status"
}

# #226: ↑ goes back to the last message (.maestro/chat_edit_previous.yaml),
# against tools/e2e_edit_claude.py as chat's own `claude -p`. What it was
# started with is read after the flow: exactly one start with
# --resume-session-at and --fork-session, never an attach or a --bg, and no
# more than the two starts the flow makes, so neither the draft nor the busy
# turn restarted anything.
chat_edit_previous() {
  local status=0 home=/home/$SSH_USER cmds=/home/$SSH_USER/.e2e-edit-cmds
  chat_stand_in
  end_live_session
  sudo install -o "$SSH_USER" -m 644 tools/e2e_edit_claude.py "$home/.e2e-edit-claude.py"
  put_stand_in <<'SH'
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  -p) exec python3 "$HOME/.e2e-edit-claude.py" "$@" ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo rm -f "$cmds"
  flow chat_edit_previous || status=1
  local forks starts
  forks=$(sudo grep -c -- '--resume-session-at [0-9a-f-]* --fork-session' "$cmds" 2>/dev/null)
  starts=$(sudo grep -c . "$cmds" 2>/dev/null)
  [ "${forks:-0}" = 1 ] ||
    { echo "::error::$forks starts went back and forked, not 1: $(sudo cat "$cmds" 2>/dev/null)"; status=1; }
  [ "${starts:-0}" -le 2 ] ||
    { echo "::error::$starts starts of claude -p, more than the flow's 2"; status=1; }
  if sudo grep -q -- '--bg\|attach' "$cmds" 2>/dev/null; then
    echo "::error::a --bg or attach was run"; status=1
  fi
  echo "claude -p starts: $(sudo cat "$cmds" 2>/dev/null)"
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-edit-previous-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -f "$cmds" "$home/.e2e-edit-claude.py"
  stand_in ''
  return "$status"
}

# #230: the folder a new chat starts in (.maestro/chat_cwd.yaml). The stand-in's
# `--bg` keeps the folder it ran in, since chat `cd`s there first, refuses a
# folder called untrusted as Claude Code does an untrusted workspace, and
# fails in one called broken for another reason. Read afterwards: the first
# start ran in proj, not the root; each refused folder was tried; and the
# host's ~/.claude.json, where trust is kept, was not written.
chat_cwd() {
  local status=0 home=/home/$SSH_USER runs=/home/$SSH_USER/.e2e-bg-runs
  local before after
  chat_stand_in
  end_live_session
  sudo -u "$SSH_USER" mkdir -p "$home/e2e-cwd/proj" "$home/e2e-cwd/untrusted" "$home/e2e-cwd/broken"
  sudo -u "$SSH_USER" HOME="$home" python3 - <<'PY'
import json, os
path = os.path.join(os.environ['HOME'], '.e2e-agents.json')
rows = json.load(open(path))
rows.append({'id': 'e2e0newd', 'cwd': os.environ['HOME'] + '/e2e-cwd/proj', 'kind': 'background',
             'startedAt': 1790000000100, 'sessionId': 'e2e00003-0000-4000-8000-000000000003',
             'name': 'New chat', 'state': 'done'})
json.dump(rows, open(path, 'w'))
PY
  put_stand_in <<'SH'
case "$1" in
  --version) echo '2.1.300 (Claude Code)' ;;
  agents) cat "$HOME/.e2e-agents.json" ;;
  --bg) printf '%s\n' "$PWD" >>"$HOME/.e2e-bg-runs"
    case "$PWD" in
      */untrusted) echo "Workspace not trusted: $PWD"; exit 1 ;;
      */broken) echo "boom: could not start"; exit 1 ;;
    esac
    echo 'backgrounded · e2e0newd · New chat' ;;
  -p) while IFS= read -r line; do :; done ;;
  *) exec cat >/dev/null ;;
esac
SH
  sudo rm -f "$runs"
  before=$(sudo sha256sum "$home/.claude.json" 2>/dev/null | cut -d' ' -f1)
  flow chat_cwd -e "PROJ=$home/e2e-cwd/proj" -e "BAD=$home/e2e-cwd/untrusted" \
    -e "BROKEN=$home/e2e-cwd/broken" || status=1
  after=$(sudo sha256sum "$home/.claude.json" 2>/dev/null | cut -d' ' -f1)
  [ "$before" = "$after" ] ||
    { echo "::error::~/.claude.json on the host changed"; status=1; }
  echo "--bg ran in: $(sudo cat "$runs" 2>/dev/null | tr '\n' ' ')"
  [ "$(sudo head -n1 "$runs" 2>/dev/null)" = "$home/e2e-cwd/proj" ] ||
    { echo "::error::the first --bg did not run in the chosen folder"; status=1; }
  sudo grep -qx "$home/e2e-cwd/untrusted" "$runs" 2>/dev/null ||
    { echo "::error::the untrusted folder was never tried"; status=1; }
  [ "$(sudo tail -n1 "$runs" 2>/dev/null)" = "$home/e2e-cwd/proj" ] ||
    { echo "::error::the retry did not run in the chosen folder"; status=1; }
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-cwd-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -rf "$runs" "$home/e2e-cwd"
  stand_in ''
  return "$status"
}

# #218: `jeansh <file>` (.maestro/jeansh_open.yaml). The runner makes the file
# to open and a forged request, an OSC 7733 line with the right shape and
# time and a wrong secret, for a `cat` to print; afterwards it reads the
# command's mode and marker, which the host editor's switch had the app write.
jeansh_open() {
  local status=0 home=/home/$SSH_USER bin=/home/$SSH_USER/.local/bin/jeansh
  local b64
  sudo -u "$SSH_USER" rm -f "$bin" "$home/jeansh-forged.done" "$home/jeansh-missing.rc"
  printf 'jeansh e2e target\n' | sudo -u "$SSH_USER" tee "$home/jeansh-target.txt" >/dev/null
  b64=$(printf %s "$home/jeansh-target.txt" | base64 | tr -d '\n')
  printf '\033]7733;open;wrong-secret;%s;%s;%s\007' "$(date +%s)" \
    "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" "$b64" |
    sudo -u "$SSH_USER" tee "$home/jeansh-forged.txt" >/dev/null
  flow jeansh_open || status=1
  sudo test -f "$home/jeansh-forged.done" ||
    { echo "::error::the forged request's cat never ran"; status=1; }
  [ "$(sudo cat "$home/jeansh-missing.rc" 2>/dev/null)" = 1 ] ||
    { echo "::error::jeansh missing-e2e-file did not exit 1"; status=1; }
  [ "$(sudo stat -c %a "$bin" 2>/dev/null)" = 755 ] ||
    { echo "::error::$bin is not mode 755"; status=1; }
  sudo grep -qxF '# jeansh-open: installed by Jeansh' "$bin" 2>/dev/null ||
    { echo "::error::$bin lacks the marker line"; status=1; }
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'jeansh-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -f "$bin" "$home/jeansh-target.txt" "$home/jeansh-forged.txt" \
    "$home/jeansh-forged.done" "$home/jeansh-missing.rc"
  return "$status"
}

# jeansh open: secret file, file limit, onward ssh, install result (#218,
# .maestro/jeansh_open2.yaml), against this runner's sshd with the host's
# install switch on. Terminal text cannot be read from a flow, so the flow
# leaves what each command printed and exited with in files in the login home,
# and the runner reads them, and the host's files, after each STEP. A second
# account, jeansh2e, is what the onward ssh goes to.
JO2_STATUS=0
jo2_host() { sudo -u "$SSH_USER" -H "$@"; }
jo2_fail() { echo "::error::$1"; JO2_STATUS=1; }
jo2_expect() { # label got want
  if [ "$2" = "$3" ]; then echo "ok: $1"; else jo2_fail "$1: got [$2], expected [$3]"; fi
}
jo2_cat() { sudo cat "/home/$SSH_USER/$1" 2>/dev/null; }

jeansh_open2() {
  local home=/home/$SSH_USER bin=/home/$SSH_USER/.local/bin/jeansh
  local f before after rc out
  JO2_STATUS=0
  sudo rm -rf "$bin" "$home/.config/jeansh" "$home/jeansh-e2e-open" "$home"/jo[0-9]*.*
  jo2_host sh -s <<'EOS'
mkdir -p "$HOME/jeansh-e2e-open" && cd "$HOME/jeansh-e2e-open" || exit 1
for n in a.md f1 f2 f3 f4 f5 f6 f7 g1 g2 g3 g4 g5; do printf 'jeansh e2e %s\n' "$n" >"$n"; done
EOS
  # The second account and the key that reaches it.
  id jeansh2e >/dev/null 2>&1 || sudo useradd -m -s /bin/bash jeansh2e
  sudo usermod -p '*' jeansh2e
  sudo rm -f "$home/.e2e-onward-key" "$home/.e2e-onward-key.pub"
  jo2_host ssh-keygen -q -t ed25519 -N '' -f "$home/.e2e-onward-key"
  sudo chown "$SSH_USER" "$home/.e2e-onward-key" "$home/.e2e-onward-key.pub"
  sudo chmod 600 "$home/.e2e-onward-key"
  sudo install -d -m 700 -o jeansh2e -g jeansh2e /home/jeansh2e/.ssh
  sudo cat "$home/.e2e-onward-key.pub" | sudo tee /home/jeansh2e/.ssh/authorized_keys >/dev/null
  sudo chown jeansh2e:jeansh2e /home/jeansh2e/.ssh/authorized_keys
  sudo chmod 600 /home/jeansh2e/.ssh/authorized_keys

  echo "::group::jeansh_open2: the switch on"
  flow jeansh_open2 -e STEP=on || jo2_fail "the switch flow failed"
  echo "::endgroup::"

  # 4. A file of somebody else's where the command goes: said, and untouched.
  echo "::group::jeansh_open2: install result, a file that is not the app's"
  jo2_host sh -c 'mkdir -p "$HOME/.local/bin" && printf "#!/bin/sh\necho foreign\n" >"$HOME/.local/bin/jeansh" && chmod 755 "$HOME/.local/bin/jeansh"'
  before=$(sudo sha256sum "$bin" | cut -d' ' -f1)
  # The notice is on screen for about a second, so the flow may look away at
  # the wrong moment: it is tried up to three times, each from a stopped app and
  # the same untouched file, and one sighting is the proof.
  local seen=0 attempt
  for attempt in 1 2 3; do
    if flow jeansh_open2 -e STEP=foreign; then seen=1; break; fi
    echo "the notice was not seen on attempt $attempt"
    # A trust prompt that came first is answered here, then it is tried again.
    flow jeansh_open2 -e STEP=trust || true
    adb shell am force-stop cloud.brata.terminal >/dev/null 2>&1
  done
  [ "$seen" = 1 ] || jo2_fail "4: the notice that the file was left alone was not seen in three tries"
  after=$(sudo sha256sum "$bin" 2>/dev/null | cut -d' ' -f1)
  jo2_expect "4: the file there is byte for byte as it was" "$after" "$before"
  jo2_expect "4: and nothing else was left beside it" \
    "$(jo2_host sh -c 'ls -A "$HOME/.local/bin" | wc -l' | tr -d ' ')" 1
  echo "::endgroup::"

  # A clean host, then the command itself.
  echo "::group::jeansh_open2: a clean host, the command"
  sudo rm -rf "$bin" "$home/.config/jeansh"
  flow jeansh_open2 -e STEP=clean || jo2_fail "the clean-host flow failed"
  sleep 3
  jo2_expect "4: a clean host got the command, mode 755" "$(sudo stat -c %a "$bin" 2>/dev/null)" 755
  sudo grep -qxF '# jeansh-open: installed by Jeansh' "$bin" 2>/dev/null ||
    jo2_fail "4: the command lacks its marker line"
  jo2_expect "4: and its key file is private" \
    "$(sudo stat -c %a "$home/.config/jeansh/open-secret" 2>/dev/null)" 600

  jo2_expect "1: the command ran and exited 0" "$(jo2_cat jo1.rc)" 0
  jo2_expect "1: and printed nothing" "$(jo2_cat jo1.err)" ""
  jo2_expect "1: without its key file it exited 1" "$(jo2_cat jo1n.rc)" 1
  case $(jo2_cat jo1n.err) in
    *"not running in a Jeansh terminal"*) echo "ok: 1: and said it is not in a Jeansh terminal" ;;
    *) jo2_fail "1: without its key file it did not say it is not in a Jeansh terminal: [$(jo2_cat jo1n.err)]" ;;
  esac
  jo2_expect "2: seven files exit 1" "$(jo2_cat jo2.rc)" 1
  case $(jo2_cat jo2.err) in
    *"2 of 7 not opened"*) echo "ok: 2: and say 2 of 7 were not opened" ;;
    *) jo2_fail "2: seven files did not say 2 of 7 not opened: [$(jo2_cat jo2.err)]" ;;
  esac
  jo2_expect "2: five files exit 0" "$(jo2_cat jo2b.rc)" 0
  jo2_expect "2: and print nothing" "$(jo2_cat jo2b.err)" ""

  # 3. Onward ssh: only worth reading when the control shows the account can
  # be reached and a LC_ variable does get through to it.
  rc=$(jo2_cat jo3.rc)
  out=$(jo2_cat jo3.out | tail -n 3 | tr "\n" " ")
  # The push key is a file, never a variable: none of it in this tab's own
  # shell either. Only a real relay key makes the file, and the emulator has no
  # FCM to get one with, so that check is made when there is a file and said to
  # be skipped when there is none.
  jo2_expect "3: no push key or host id in the tab's own environment" \
    "$(jo2_cat jo3.own | tr -d '\n ')" 0
  if sudo test -f "$home/.config/jeansh/notify-key"; then
    jo2_expect "3: the push key file is private" \
      "$(sudo stat -c %a "$home/.config/jeansh/notify-key")" 600
  else
    echo "::notice::jeansh_open2 3: this host got no relay key (no FCM on this runner), so the notify-key file check is skipped"
  fi
  echo "onward ssh: exit [$rc], saw [$out], control [$(jo2_cat jo3.control | tr '\n' ' ')]"
  if [ "$rc" != 0 ]; then
    echo "::warning::jeansh_open2 3: the onward ssh did not connect, so nothing was learned: $out"
    JO2_STATUS=1
  else
    jo2_expect "3: onward, no push key or host id in the environment, no open secret, and no key file" "$out" "0 0 0 "
    if [ "$(jo2_cat jo3.control | tr -d '\n ')" != 1 ]; then
      echo "::notice::jeansh_open2 3: this sshd does not take LC_ variables, so the 0 above is not a proof; it is a check that nothing was left behind"
    fi
  fi
  echo "::endgroup::"

  echo "::group::jeansh_open2: the switch off"
  flow jeansh_open2 -e STEP=off || jo2_fail "the switch-off flow failed"
  echo "::endgroup::"
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'jeansh-open2-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -rf "$bin" "$home/.config/jeansh" "$home/jeansh-e2e-open" "$home"/jo[0-9]*.* \
    "$home/.e2e-onward-key" "$home/.e2e-onward-key.pub"
  sudo userdel -r jeansh2e >/dev/null 2>&1
  return "$JO2_STATUS"
}

# #261: a tmux tab keeps its program's mouse modes across a reattach. The host
# runs its tabs in tmux for this block (the flows switch it on and off); a
# stand-in program (tools/e2e_mouse_tui.py) logs what it is typed, which is
# read here, since terminal text is not readable from a flow. A swipe is a
# mouse wheel to a program that asked for the mouse, before and after the app
# is killed and the tab rebuilt from tmux's capture; and nothing to one that did
# not ask (the scrollback it moves is the live tmux test's to prove).
tmux_mouse_reattach() {
  local status=0 home=/home/$SSH_USER mode
  local log=$home/.e2e-mouse.log
  sudo install -o "$SSH_USER" -m 644 tools/e2e_mouse_tui.py "$home/.e2e-mouse-tui.py"
  for mode in mouse plain; do
    sudo rm -f "$log"
    flow tmux_mouse_before -e "MODE=$mode" || status=1
    echo "tmux_mouse_reattach $mode, before the kill: $(sudo cat "$log" 2>/dev/null | head -c 300 | tr '\n' ' ')"
    tmux_mouse_expect "$mode" "before the kill" || status=1
    sudo sh -c ": > '$log'"
    flow tmux_mouse_after -e "MODE=$mode" || status=1
    echo "tmux_mouse_reattach $mode, after the relaunch: $(sudo cat "$log" 2>/dev/null | head -c 300 | tr '\n' ' ')"
    tmux_mouse_expect "$mode" "after the relaunch" || status=1
    # Whatever tab the flow left, and what it ran: this user's sshbox- sessions.
    sudo -u "$SSH_USER" -H tmux list-sessions -F '#{session_name}' 2>/dev/null |
      grep '^sshbox-' |
      xargs -r -n1 sudo -u "$SSH_USER" -H tmux kill-session -t
  done
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'tmux-mouse-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  sudo rm -f "$log" "$home/.e2e-mouse-tui.py"
  return "$status"
}

# What the stand-in was typed: a wheel event for "mouse", nothing for "plain".
tmux_mouse_expect() {
  local log=/home/$SSH_USER/.e2e-mouse.log
  if [ "$1" = mouse ]; then
    sudo grep -qF '\x1b[<6' "$log" 2>/dev/null ||
      { echo "::error::mouse program got no wheel event $2"; return 1; }
  else
    ! sudo grep -q . "$log" 2>/dev/null ||
      { echo "::error::plain program was typed something $2"; return 1; }
  fi
}

# #216: Home's Text size control and Settings' slider (.maestro/text_size_home).
text_size_home() {
  local status=0
  flow text_size_home || status=1
  keep_shots 'text-size-*.png'
  return "$status"
}

# Download as zip on the files drawer (feature issue #271,
# .maestro/folder_zip.yaml). The folders are the host user's own, in its home,
# which is the file tree's root. Between the flow's STEPs the runner arranges
# what the host has: a zip that takes 15 s, so the Transfers row can be read
# while it compresses; then no zip tools at all; then only tar and gzip. A
# tool is hidden by renaming it, and put back after each step and on exit: the
# app looks for them on the PATH sshd gives it plus the usual places, so
# nothing short of the file's absence takes one off the host.
FZ_LIST=$(mktemp)
FZ_STATUS=0
FZ_PKG=cloud.brata.terminal

fz_host() { sudo -u "$SSH_USER" -H "$@"; }

fz_fail() { echo "::error::$1"; FZ_STATUS=1; }
fz_expect() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    fz_fail "$1: got [$2], expected [$3]"
  fi
}

# Tools put out of reach: every path `which -a` knows for each name.
fz_hide() {
  local t p
  for t in "$@"; do
    for p in $(which -a "$t" 2>/dev/null | sort -u); do
      [ -e "$p" ] || continue
      sudo mv "$p" "$p.e2e-hidden" </dev/null && echo "$p" >>"$FZ_LIST"
    done
  done
}
fz_restore() {
  local p
  [ -s "$FZ_LIST" ] || return 0
  while read -r p; do
    [ -e "$p.e2e-hidden" ] && sudo mv "$p.e2e-hidden" "$p" </dev/null
  done <"$FZ_LIST"
  : >"$FZ_LIST"
}

# The zip made slow, in its own place, so no PATH order can skip it.
fz_slow_zip() {
  local p
  p=$(command -v zip) || return 1
  sudo mv "$p" "$p.e2e-real" || return 1
  printf '#!/bin/sh\nsleep 15\nexec "%s.e2e-real" "$@"\n' "$p" | sudo tee "$p" >/dev/null
  sudo chmod 755 "$p"
  echo "$p" >"$FZ_LIST.slow"
}
fz_fast_zip() {
  local p
  [ -s "$FZ_LIST.slow" ] || return 0
  p=$(cat "$FZ_LIST.slow")
  sudo rm -f "$p"
  sudo mv "$p.e2e-real" "$p"
  rm -f "$FZ_LIST.slow"
}

# What is on the host user's side: the tools the app's probe would find, and
# the archive folders it makes in /tmp.
fz_tools() {
  fz_host sh -c 'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:$HOME/.local/bin"
    for t in zip 7zz 7z 7za bsdtar tar gzip; do p=$(command -v "$t") && echo "$t=$p"; done; true' | tr '\n' ' '
}
fz_left() { fz_host sh -c 'ls -d /tmp/jeansh-zip.* 2>/dev/null | wc -l' | tr -d ' '; }

# Files saved on the phone, anywhere in its shared storage: /sdcard is a link, which find does not follow without a trailing slash.
fz_saved() { adb shell "find /storage/emulated/0/ -name '$1' 2>/dev/null" | tr -d '\r' | head -1; }
fz_clear_saved() {
  local pattern
  for pattern in 'dev*.zip' 'dev*.tar.gz' '*odd*dir*.zip' '*big*.zip'; do
    adb shell "find /storage/emulated/0/ -name '$pattern' -exec rm -f {} +" >/dev/null 2>&1
  done
}
# The files an archive lists, no folders, sorted.
fz_list() { # kind(zip|tgz) device-path
  local tmp
  tmp=$(mktemp -d)
  if adb pull "$2" "$tmp/a" >/dev/null 2>&1; then
    if [ "$1" = zip ]; then unzip -Z1 "$tmp/a"; else tar tzf "$tmp/a"; fi 2>/dev/null |
      grep -v '/$' | sed 's|^\./||' | LC_ALL=C sort
  fi
  rm -rf "$tmp"
}
fz_member() { # device-path member -> its text (zip only)
  local tmp
  tmp=$(mktemp -d)
  adb pull "$1" "$tmp/a" >/dev/null 2>&1 && unzip -p "$tmp/a" "$2" 2>/dev/null
  rm -rf "$tmp"
}

fz_step() { # name
  echo "::group::folder_zip: $1"
  adb shell am force-stop "$FZ_PKG" >/dev/null 2>&1
  fz_clear_saved
  # What an earlier step's aborted run left, so each step is read alone.
  sleep 2
  fz_host sh -c 'rm -rf /tmp/jeansh-zip.*'
}
# What the phone's Downloads holds and what its media store says, said in the
# log so a missing file can be told from a lookup that cannot see it.
fz_where() {
  echo "Downloads on the phone:"
  adb shell 'ls -la /storage/emulated/0/Download/' 2>&1 | tr -d '\r' | head -20
  echo "media store:"
  adb shell 'content query --uri content://media/external/downloads --projection _display_name:_size' 2>&1 |
    tr -d '\r' | head -20
}

folder_zip() {
  FZ_STATUS=0
  : >"$FZ_LIST"
  [ -z "$(trap -p EXIT)" ] && trap 'fz_restore; fz_fast_zip' EXIT
  command -v unzip >/dev/null || sudo apt-get install -y -qq unzip >/dev/null
  command -v zip >/dev/null || sudo apt-get install -y -qq zip >/dev/null
  # The host's folders, in the home the file tree opens at. One has a quote
  # and a space in a file's name; the other starts with a dash, as an option
  # does, and holds a quote and a space too.
  fz_host sh -s <<'EOS'
cd "$HOME" || exit 1
rm -rf dev ./-odd*
mkdir dev
printf one >dev/plain.txt
printf two >"dev/it's a \"q\".txt"
mkdir -- "-odd's dir"
printf three >"./-odd's dir/inner.txt"
EOS

  # 1. A host with zip, made to take 15 s.
  fz_step "1, a host with zip"
  fz_slow_zip || fz_fail "1: no zip on this runner"
  echo "tools the app finds: $(fz_tools)"
  flow folder_zip -e STEP=zip || fz_fail "1: the zip flow failed"
  fz_where
  sleep 3
  local saved
  saved=$(fz_saved dev.zip)
  [ -n "$saved" ] || fz_fail "1: no dev.zip was saved on the phone"
  fz_expect "1: the zip lists both files" "$(fz_list zip "$saved")" \
    "$(printf '%s\n' "dev/it's a \"q\".txt" dev/plain.txt)"
  fz_expect "1: and holds what they hold" \
    "$(fz_member "$saved" dev/plain.txt)/$(fz_member "$saved" "dev/it's a \"q\".txt")" one/two
  fz_expect "1: the host keeps no jeansh-zip.*" "$(fz_left)" 0
  flow folder_zip -e STEP=zip_dash || fz_fail "1: the zip_dash flow failed"
  fz_where
  sleep 3
  saved=$(fz_saved "*odd*dir*.zip")
  [ -n "$saved" ] || fz_fail "1: no zip of the dash folder was saved on the phone"
  fz_expect "1: the dash folder's zip lists its file under its own name" \
    "$(fz_list zip "$saved")" "-odd's dir/inner.txt"
  fz_expect "1: the host keeps no jeansh-zip.* after it either" "$(fz_left)" 0
  fz_fast_zip
  echo "::endgroup::"

  # 2. No zip, 7z, 7za, 7zz or bsdtar, and no gzip for tar to be a fallback.
  fz_step "2, a host with no zip tool"
  fz_hide zip 7zz 7z 7za bsdtar gzip
  echo "tools the app finds: $(fz_tools)"
  flow folder_zip -e STEP=nozip || fz_fail "2: the nozip flow failed"
  fz_where
  sleep 3
  fz_restore
  fz_expect "2: nothing was saved on the phone" \
    "$(fz_saved 'dev*.zip')$(fz_saved 'dev*.tar.gz')" ""
  fz_expect "2: the host has no jeansh-zip.*" "$(fz_left)" 0
  echo "::endgroup::"

  # 3. tar and gzip only.
  fz_step "3, only tar and gzip"
  fz_hide zip 7zz 7z 7za bsdtar
  echo "tools the app finds: $(fz_tools)"
  flow folder_zip -e STEP=targz || fz_fail "3: the targz flow failed"
  fz_where
  sleep 3
  fz_restore
  saved=$(fz_saved dev.tar.gz)
  [ -n "$saved" ] || fz_fail "3: no dev.tar.gz was saved on the phone"
  fz_expect "3: the archive lists both files" "$(fz_list tgz "$saved")" \
    "$(printf '%s\n' "dev/it's a \"q\".txt" dev/plain.txt)"
  fz_expect "3: and no .zip was saved" "$(fz_saved 'dev*.zip')" ""
  fz_expect "3: the host keeps no jeansh-zip.*" "$(fz_left)" 0
  echo "::endgroup::"

  # 4. Cancel while it compresses: a big folder, zip made slow so there is time
  # to open Transfers and press Cancel. The row says it was cancelled, no save
  # dialog comes, and within 10 s the host has no zip running and no archive.
  fz_step "4, cancel while compressing"
  fz_host sh -c 'cd "$HOME" && rm -rf jeansh-e2e-big && mkdir jeansh-e2e-big && for n in 1 2 3; do dd if=/dev/urandom of=jeansh-e2e-big/f$n bs=1048576 count=100 2>/dev/null; done'
  fz_slow_zip || fz_fail "4: no zip on this runner"
  flow folder_zip -e STEP=cancel || fz_fail "4: the cancel flow failed"
  fz_where
  local waited=0 procs left
  while [ "$waited" -lt 10 ]; do
    procs=$(fz_host sh -c 'pgrep -u "$(id -u)" -x zip | wc -l' | tr -d ' ')
    left=$(fz_left)
    [ "$procs" = 0 ] && [ "$left" = 0 ] && break
    sleep 1
    waited=$((waited + 1))
  done
  fz_expect "4: within 10 s no zip is running on the host" "$procs" 0
  fz_expect "4: and the host keeps no jeansh-zip.*" "$left" 0
  fz_expect "4: and nothing was saved on the phone" "$(fz_saved '*big*.zip')" ""
  fz_fast_zip
  fz_host sh -c 'cd "$HOME" && rm -rf jeansh-e2e-big'
  echo "::endgroup::"

  fz_restore
  fz_fast_zip
  fz_host sh -c 'cd "$HOME" && rm -rf dev ./-odd*'
  fz_clear_saved
  keep_shots 'folder-zip-*.png'
  adb shell am force-stop "$FZ_PKG" >/dev/null 2>&1
  return "$FZ_STATUS"
}

# Chat following the latest reply only at the bottom, and its Latest button,
# against the stand-in's long:, long2:, long3: and late: turns.
chat_follow_jump() {
  local status=0
  chat_stand_in
  end_live_session
  live_session
  flow chat_follow_jump || status=1
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-follow-jump-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_live_session
  stand_in ''
  return "$status"
}

# #169: the task checklist under chat's working line, against the stand-in's
# tasks: turn -- three TaskCreate calls, the first moved to in progress and then
# completed, the turn ended with two tasks still open.
chat_tasks() {
  local status=0
  chat_stand_in
  end_live_session
  live_session
  flow chat_tasks || status=1
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-tasks-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  end_live_session
  stand_in ''
  return "$status"
}

# #187: the bug button after +, and the report it opens (.maestro/bug_button).
# Its screenshots, pass or fail, are evidence.
bug_button() {
  local status=0
  flow bug_button || status=1
  keep_shots 'bug-button-*.png'
  return "$status"
}

# Claude's questions in chat: the AskUserQuestion tool, answered from the chat
# tab. The finished "E2E short session" continued in place runs the stand-in
# tools/e2e_ask_claude.py as its `claude -p`, which asks which colour for one
# message and which size for the next, waits for the app's control_response,
# and says what it was told. The flow reads that off the screen; this reads
# what the app really sent, which the stand-in kept: an allow whose
# updatedInput is the call's own input plus the answers and nothing else, and
# a deny for the question dismissed.
chat_ask() {
  local status=0 home=/home/$SSH_USER replies=/home/$SSH_USER/.e2e-ask-replies.jsonl
  chat_stand_in
  sudo -u "$SSH_USER" -H tee "$home/.e2e-ask.py" >/dev/null < tools/e2e_ask_claude.py
  sudo rm -f "$replies"
  flow chat_ask || status=1
  find "$ROOT" "$HOME/.maestro" -maxdepth 6 -name 'chat-ask-*.png' \
    -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null
  if [ "$status" -eq 0 ]; then
    sudo cat "$replies" 2>/dev/null | python3 -c '
import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
def fail(why):
    print("::error::chat_ask: " + why); sys.exit(1)
if len(lines) != 2:
    fail("the app sent %d control_response lines, not 2" % len(lines))
first = lines[0]["response"]
decision = first["response"]
if first["request_id"] != "req-ask-1" or decision.get("behavior") != "allow":
    fail("the first answer was not an allow for req-ask-1: %r" % (first,))
updated = decision["updatedInput"]
if set(updated) != {"questions", "answers"}:
    fail("updatedInput holds %r, not the questions and answers alone" % sorted(updated))
if updated["answers"] != {"Which colour?": "Blue"}:
    fail("the answers were %r" % (updated["answers"],))
second = lines[1]["response"]
if second["request_id"] != "req-ask-2" or second["response"].get("behavior") != "deny":
    fail("the dismissed question was not denied: %r" % (second,))
print("chat_ask: allow with the answers, deny for the dismissal")
' || status=1
  fi
  sudo rm -f "$home/.e2e-ask.py" "$replies"
  stand_in ''
  return "$status"
}

# The chat outbox (branch chat-outbox, .maestro/chat_outbox.yaml): a message
# sent in chat is kept in a file on the device until the session's own
# transcript records it. Against the stand-in session of live_session, in its
# tmux pane, which the runner works at its own terminal between the flow's
# STEPs: a turn held busy, a draft typed and not sent, a permission prompt left
# up. Each step reads three things afterwards and asserts both ways: the
# transcript's user turns with the message's text (how many times the session
# recorded it), the lines the pane read (how many times anything was typed
# into it, tools/e2e_live_claude.py logs every one), and the outbox file on the
# device. The flow asserts what the user sees.
OB_PANE_LOG=/home/$SSH_USER/.e2e-pane-lines.log
OB_RELEASE=/home/$SSH_USER/.e2e-release
OB_STAMPED=/home/$SSH_USER/.e2e-stamped
OB_PKG=cloud.brata.terminal
OB_STATUS=0
OB_FROM=0

ob_host() { sudo -u "$SSH_USER" -H "$@"; }
ob_fail() { echo "::error::$1"; OB_STATUS=1; }
# Typed at the pane as someone at that terminal would.
ob_type() { ob_host tmux send-keys -t e2e-live -l "$1"; }
ob_line() { ob_type "$1"; ob_host tmux send-keys -t e2e-live Enter; }

# ob_expect LABEL GOT WANT
ob_expect() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1: $2"
  else
    ob_fail "$1: got $2, expected $3"
  fi
}

# How many user turns the session's transcript holds with exactly this text.
ob_turns() {
  ob_host python3 - "/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl" "$1" <<'PY'
import json, sys
n = 0
try:
    for line in open(sys.argv[1]):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        m = e.get('message')
        if e.get('type') == 'user' and isinstance(m, dict) and m.get('content') == sys.argv[2]:
            n += 1
except OSError:
    pass
print(n)
PY
}

# The lines the pane has read since ob_mark.
ob_lines() { ob_host tail -n +"$((OB_FROM + 1))" "$OB_PANE_LOG" 2>/dev/null; }
ob_mark() {
  OB_FROM=$(ob_host sh -c 'cat "$1" 2>/dev/null | wc -l' sh "$OB_PANE_LOG" | tr -d ' ')
  OB_FROM=${OB_FROM:-0}
}
# How many times the pane read exactly this line since ob_mark.
ob_sent() { ob_lines | grep -cxF -- "$1"; }

# What the listing says of the stand-in session: idle, busy or waiting.
ob_listed() {
  ob_host python3 - "/home/$SSH_USER/.e2e-agents.json" "$LIVE_SID" <<'PY'
import json, sys
try:
    for row in json.load(open(sys.argv[1])):
        if row.get('sessionId') == sys.argv[2]:
            print(row.get('status', ''))
except (OSError, ValueError):
    pass
PY
}

# ob_wait_listed STATUS SECONDS
ob_wait_listed() {
  local i
  for i in $(seq "$2"); do
    [ "$(ob_listed)" = "$1" ] && return 0
    sleep 1
  done
  ob_fail "the stand-in session was not $1 after $2 s (it is '$(ob_listed)')"
  return 1
}

# ob_wait_turns TEXT WANT SECONDS
ob_wait_turns() {
  local i
  for i in $(seq "$3"); do
    [ "$(ob_turns "$1")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}

# What the app keeps on the device, and nothing of the picture or the rest:
# the files of the outbox folder, the app's support folder, read as the app.
ob_device() {
  adb shell "run-as $OB_PKG sh -c 'cat files/chat_outbox/*.json 2>/dev/null'" 2>/dev/null | tr -d '\r'
}
ob_device_clear() {
  adb shell "run-as $OB_PKG sh -c 'chmod 700 files/chat_outbox 2>/dev/null; rm -f files/chat_outbox/*'" >/dev/null 2>&1
}
# How many lines of the outbox files mention this text.
ob_kept() { ob_device | grep -c -- "$1"; }

# A draft at the terminal taken back, with the cursor on the prompt again.
ob_clear_draft() {
  ob_host tmux send-keys -t e2e-live C-u
  sleep 1
  if [ "$(ob_host tmux display -p -t e2e-live '#{cursor_x}')" != 2 ]; then
    ob_host tmux send-keys -t e2e-live Enter
    sleep 2
  fi
}

# Every step starts from the same place: the app stopped, nothing held, asked
# or half typed at the pane, nothing kept on the device.
ob_reset() {
  adb shell am force-stop "$OB_PKG" >/dev/null 2>&1
  if [ "$(ob_listed)" = busy ]; then
    ob_host touch "$OB_RELEASE"
    ob_wait_listed idle 20
  fi
  if [ "$(ob_listed)" = waiting ]; then
    ob_line cleanup
    ob_wait_listed idle 20
  fi
  sudo rm -f "$OB_RELEASE"
  ob_clear_draft
  ob_device_clear
  ob_mark
}

# 1. Positive, kill and restart: queued mid-turn, force-stopped, relaunched,
# typed once when the turn ends.
ob_step1() {
  echo "::group::chat_outbox 1: queued mid-turn, killed, relaunched"
  ob_reset
  ob_line 'hold: first turn'
  ob_wait_listed busy 20
  flow chat_outbox -e STEP=queue || ob_fail "1: the queue flow failed"
  # Where the app keeps it, said once, so a wrong guess at the folder is easy
  # to see in the log rather than only as a failed count.
  echo "outbox files on the device: $(adb shell "run-as $OB_PKG sh -c 'find . -path \"*chat_outbox*\" 2>/dev/null'" | tr -d '\r' | tr '\n' ' ')"
  ob_expect "1: written to the device before it was ever typed" "$(ob_kept 'outbox one')" 1
  ob_expect "1: mid-turn, nothing typed into the pane" "$(ob_sent 'outbox one')" 0
  ob_expect "1: mid-turn, the transcript holds none" "$(ob_turns 'outbox one')" 0
  flow chat_outbox -e STEP=relaunch || ob_fail "1: the relaunch flow failed"
  sleep 8
  ob_expect "1: after the restart, still mid-turn, still not typed" "$(ob_sent 'outbox one')" 0
  ob_host touch "$OB_RELEASE"
  flow chat_outbox -e STEP=typed1 || ob_fail "1: the typed1 flow failed"
  # A second send, if one were coming, would have been typed by now.
  sleep 6
  ob_expect "1: the transcript holds it exactly once" "$(ob_turns 'outbox one')" 1
  ob_expect "1: the pane read it exactly once" "$(ob_sent 'outbox one')" 1
  ob_expect "1: the session recorded it, so the device keeps nothing" "$(ob_kept 'outbox one')" 0
  echo "::endgroup::"
}

# 2. Negative: a failure that is the session's own never sends by itself.
ob_step2() {
  echo "::group::chat_outbox 2: a draft at the terminal fails it, nothing sends it but Retry"
  ob_reset
  ob_type 'half typed'
  sleep 1
  flow chat_outbox -e STEP=draft || ob_fail "2: the draft flow failed"
  ob_expect "2: nothing typed while the draft was there" "$(ob_sent 'outbox two')" 0
  ob_expect "2: kept on the device as failed" "$(ob_device | grep -c '"failed":true')" 1
  flow chat_outbox -e STEP=draft_relaunch || ob_fail "2: the draft_relaunch flow failed"
  # A restart that sent failed messages by itself would have by now.
  sleep 10
  ob_expect "2: after the restart nothing was typed" "$(ob_sent 'outbox two')" 0
  ob_expect "2: after the restart the transcript holds none" "$(ob_turns 'outbox two')" 0
  ob_clear_draft
  flow chat_outbox -e STEP=retry || ob_fail "2: the retry flow failed"
  sleep 5
  ob_expect "2: Retry typed it once" "$(ob_sent 'outbox two')" 1
  ob_expect "2: the transcript holds it exactly once" "$(ob_turns 'outbox two')" 1
  ob_expect "2: delivered, so the device keeps nothing" "$(ob_kept 'outbox two')" 0
  echo "::endgroup::"
}

# 3. No double send: typed, recorded after the chat gave up on it. Retry looks
# in the transcript first and only marks it delivered.
ob_step3() {
  echo "::group::chat_outbox 3: recorded late, Retry sends nothing"
  ob_reset
  flow chat_outbox -e STEP=late || ob_fail "3: the late flow failed"
  # A second typing would have been read by now, and recorded at once.
  sleep 10
  ob_expect "3: the pane read it exactly once" "$(ob_sent 'tardy: outbox three')" 1
  ob_expect "3: the transcript holds it exactly once" "$(ob_turns 'tardy: outbox three')" 1
  ob_expect "3: marked delivered, so the device keeps nothing" "$(ob_kept 'outbox three')" 0
  echo "::endgroup::"
}

# 4. A prompt: queued, nothing typed (no digit either), typed once after the
# prompt is answered at the terminal.
ob_step4() {
  echo "::group::chat_outbox 4: a permission prompt queues it"
  ob_reset
  ob_line 'ask: delete it'
  ob_wait_listed waiting 20
  flow chat_outbox -e STEP=prompt || ob_fail "4: the prompt flow failed"
  # Several of the chat's looks at the session pass.
  sleep 8
  ob_expect "4: nothing typed at the prompt" "$(ob_sent 'outbox four')" 0
  # What the pane read besides the line that began the turn would be the
  # message, or a digit: the answer to the prompt.
  ob_expect "4: the pane read nothing but the line that began the turn" \
    "$(ob_lines | grep -cvx 'ask: delete it')" 0
  ob_expect "4: the transcript holds none" "$(ob_turns 'outbox four')" 0
  ob_line 1
  flow chat_outbox -e STEP=prompt_done || ob_fail "4: the prompt_done flow failed"
  sleep 6
  ob_expect "4: typed once after the answer" "$(ob_sent 'outbox four')" 1
  ob_expect "4: the transcript holds it exactly once" "$(ob_turns 'outbox four')" 1
  ob_expect "4: the only digit the pane read is the user's own" \
    "$(ob_lines | grep -cx '[0-9][0-9]*')" 1
  echo "::endgroup::"
}

# 5. Identical texts: two sent, two recorded; two failed, both recorded at the
# terminal, and Retry on both sends nothing.
ob_step5() {
  echo "::group::chat_outbox 5: identical texts"
  ob_reset
  flow chat_outbox -e STEP=same || ob_fail "5: the same flow failed"
  ob_wait_turns ok 2 30
  ob_expect "5: ok sent twice is two turns" "$(ob_turns ok)" 2
  ob_expect "5: and two lines read by the pane" "$(ob_sent ok)" 2
  ob_type 'half typed'
  sleep 1
  flow chat_outbox -e STEP=same_failed || ob_fail "5: the same_failed flow failed"
  ob_expect "5: with a draft at the terminal, none typed" "$(ob_sent okay)" 0
  ob_clear_draft
  # The session has both, as if they had gone in after all.
  ob_line okay
  sleep 2
  ob_line okay
  ob_wait_turns okay 2 30
  ob_expect "5: the session records both" "$(ob_turns okay)" 2
  flow chat_outbox -e STEP=same_retry || ob_fail "5: the same_retry flow failed"
  sleep 8
  ob_expect "5: after Retry on both, still two turns" "$(ob_turns okay)" 2
  ob_expect "5: and nothing typed by the app: only the user's two lines" "$(ob_sent okay)" 2
  ob_expect "5: delivered, so the device keeps nothing" "$(ob_kept okay)" 0
  echo "::endgroup::"
}

# 6. Disk: the outbox folder made read-only for the app, where the emulator
# lets run-as do that; the message fails, with why, and nothing is typed.
ob_step6() {
  echo "::group::chat_outbox 6: a store that cannot be written"
  ob_reset
  local mode
  mode=$(adb shell "run-as $OB_PKG sh -c 'mkdir -p files/chat_outbox && chmod 500 files/chat_outbox && ls -ld files/chat_outbox'" 2>/dev/null | tr -d '\r')
  echo "outbox folder now: $mode"
  case $mode in
    dr-x*)
      flow chat_outbox -e STEP=disk || ob_fail "6: the disk flow failed"
      ob_expect "6: nothing typed" "$(ob_sent 'outbox six')" 0
      ob_expect "6: the transcript holds none" "$(ob_turns 'outbox six')" 0
      ob_expect "6: and nothing was written" "$(ob_kept 'outbox six')" 0
      ;;
    *)
      echo "::notice::chat_outbox 6 skipped: this emulator cannot make the app's outbox folder read-only"
      ;;
  esac
  ob_device_clear
  echo "::endgroup::"
}

# The connection to the host cut, as a network blip does: the listener stopped
# so nothing can reconnect, and the connections it had made killed, which the
# app sees as the session ending. Only sshd's own processes of the test user;
# the stand-in's tmux server is not among them.
ob_drop_ssh() {
  sudo systemctl stop ssh
  sudo pkill -f "sshd: $SSH_USER" || true
  echo "sshd stopped; connections of $SSH_USER left: $(pgrep -fc "sshd: $SSH_USER" || true)"
}
# The host back, answering.
ob_restore_ssh() {
  sudo systemctl start ssh
  local i
  for i in $(seq 20); do
    (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && return 0
    sleep 1
  done
  ob_fail "sshd did not come back"
}

# How many entries of the outbox are marked as waiting for something that may
# pass: failed, and transient. A message waiting for the connection is one.
ob_waiting() { ob_device | grep -c '"transient":true'; }

# 7. Positive: a message sent while the connection is down is kept, says it
# waits for the connection, and is delivered once, with no Retry, when the
# connection is back.
ob_step7() {
  local msg='outbox reconnect seven'
  echo "::group::chat_outbox 7: the connection drops, the message waits, delivered once on reconnect"
  ob_reset
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_open || ob_fail "7: the rc_open flow failed"
  ob_drop_ssh
  # The app has seen the session end by now.
  sleep 12
  flow chat_outbox -e STEP=rc_send -e "MSG=$msg" || ob_fail "7: the rc_send flow failed"
  sleep 10
  ob_expect "7: nothing typed while the connection was down" "$(ob_sent "$msg")" 0
  ob_expect "7: the transcript holds none" "$(ob_turns "$msg")" 0
  ob_expect "7: kept on the device, waiting" "$(ob_kept "$msg")" 1
  ob_expect "7: marked as waiting for something that may pass" "$(ob_waiting)" 1
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_back -e "MSG=$msg" || ob_fail "7: the rc_back flow failed"
  # A second send, if one were coming, would have been typed by now.
  sleep 10
  ob_expect "7: the transcript holds it exactly once" "$(ob_turns "$msg")" 1
  ob_expect "7: the pane read it exactly once" "$(ob_sent "$msg")" 1
  ob_expect "7: delivered, so the device keeps nothing" "$(ob_kept "$msg")" 0
  echo "::endgroup::"
}

# 8. Negative: a connection down for longer than every retry step together
# (2 + 5 + 15 + 45 + 120 = 187 s) leaves the message waiting, not failed: the
# wait for the connection uses none of the steps. Then it goes, once.
ob_step8() {
  local msg='outbox reconnect eight'
  echo "::group::chat_outbox 8: down for longer than the retry steps, still waiting, then delivered once"
  ob_reset
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_open || ob_fail "8: the rc_open flow failed"
  ob_drop_ssh
  sleep 12
  flow chat_outbox -e STEP=rc_send -e "MSG=$msg" || ob_fail "8: the rc_send flow failed"
  sleep 205
  flow chat_outbox -e STEP=rc_wait -e "MSG=$msg" || ob_fail "8: the rc_wait flow failed"
  ob_expect "8: still nothing typed" "$(ob_sent "$msg")" 0
  ob_expect "8: still kept on the device" "$(ob_kept "$msg")" 1
  ob_expect "8: still waiting, not given up on" "$(ob_waiting)" 1
  ob_expect "8: not failed for good" "$(ob_device | grep -c '"transient":true')" 1
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_back -e "MSG=$msg" || ob_fail "8: the rc_back flow failed"
  sleep 10
  ob_expect "8: the transcript holds it exactly once" "$(ob_turns "$msg")" 1
  ob_expect "8: the pane read it exactly once" "$(ob_sent "$msg")" 1
  ob_expect "8: delivered, so the device keeps nothing" "$(ob_kept "$msg")" 0
  echo "::endgroup::"
}

# The stand-in session gone, as after a host restart: its tmux session killed,
# its row taken out of what `claude agents` lists, its state file removed. Its
# transcript stays, as a restarted host keeps it.
ob_end_session() {
  ob_host tmux kill-session -t e2e-live 2>/dev/null
  ob_host python3 - "/home/$SSH_USER/.e2e-agents.json" "$LIVE_SID" <<'PY'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
rows = [r for r in json.load(open(path)) if r.get('sessionId') != sid]
json.dump(rows, open(path, 'w'))
PY
  sudo find "/home/$SSH_USER/.claude/sessions" -name '*.json' \
    -exec grep -l "\"sessionId\":\"$LIVE_SID\"" {} + 2>/dev/null | xargs -r sudo rm -f
}

# 9. Positive: the host restarted while a message waited, and what the chat
# followed is gone when the connection is back. The message is kept, failed,
# with a plain reason, Retry and Remove; nothing is typed anywhere.
ob_step9() {
  local msg='outbox reconnect nine'
  echo "::group::chat_outbox 9: the session is gone when the connection is back"
  ob_reset
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_open || ob_fail "9: the rc_open flow failed"
  ob_drop_ssh
  sleep 12
  flow chat_outbox -e STEP=rc_send -e "MSG=$msg" || ob_fail "9: the rc_send flow failed"
  ob_end_session
  ob_restore_ssh
  flow chat_outbox -e STEP=rc_gone -e "MSG=$msg" || ob_fail "9: the rc_gone flow failed"
  sleep 8
  ob_expect "9: nothing typed anywhere" "$(ob_sent "$msg")" 0
  ob_expect "9: the transcript holds none" "$(ob_turns "$msg")" 0
  ob_expect "9: still kept on the device" "$(ob_kept "$msg")" 1
  ob_expect "9: kept as failed, with the reason" \
    "$(ob_device | grep -c 'The session ended before this was sent')" 1
  ob_expect "9: and no longer waiting for anything to pass" "$(ob_waiting)" 0
  echo "::endgroup::"
}

# Steps 7 to 9 alone, which is minutes rather than the whole outbox
# block: the connection dropping under a waiting message.
chat_outbox_reconnect() {
  OB_STATUS=0
  chat_stand_in
  end_live_session
  live_session
  sudo rm -f "$OB_PANE_LOG" "$OB_RELEASE"
  ob_host touch "$OB_STAMPED"
  ob_step7
  ob_step8
  ob_step9
  ob_restore_ssh
  keep_shots 'chat-outbox-*.png'
  adb shell am force-stop "$OB_PKG" >/dev/null 2>&1
  sudo rm -f "$OB_STAMPED" "$OB_RELEASE" "$OB_PANE_LOG"
  end_live_session
  stand_in ''
  return "$OB_STATUS"
}

chat_outbox() {
  OB_STATUS=0
  chat_stand_in
  end_live_session
  live_session
  sudo rm -f "$OB_PANE_LOG" "$OB_RELEASE"
  # Turns the stand-in echoes carry a uuid and a time, as the CLI's do.
  ob_host touch "$OB_STAMPED"
  ob_step1
  ob_step2
  ob_step3
  ob_step4
  ob_step5
  ob_step6
  keep_shots 'chat-outbox-*.png'
  adb shell am force-stop "$OB_PKG" >/dev/null 2>&1
  sudo rm -f "$OB_STAMPED" "$OB_RELEASE" "$OB_PANE_LOG"
  end_live_session
  stand_in ''
  return "$OB_STATUS"
}

# A hand run may ask for one block alone after seed_host (e2e.yml's `block`),
# which is minutes rather than the half hour of every flow. Here, after every
# block is defined (#109): a block is one of the functions above, and any
# other name is a flow of .maestro/ run as it is.
if [ -n "${E2E_ONLY:-}" ]; then
  echo "::group::$E2E_ONLY (asked for alone)"
  # A block that needs the stand-in first has an `_alone` twin that makes it.
  if declare -F "${E2E_ONLY}_alone" >/dev/null; then
    "${E2E_ONLY}_alone"
  elif declare -F "$E2E_ONLY" >/dev/null; then
    "$E2E_ONLY"
  else
    flow "$E2E_ONLY"
  fi
  status=$?
  echo "::endgroup::"
  [ "$status" -eq 0 ] || echo "::error::$E2E_ONLY failed"
  exit "$status"
fi


# Every flow below is a unit: a function u_<name> that runs it, warns for a
# report-only one and records a gating one's failure. UNITS lists them in the
# order a whole run takes them. e2e.yml runs them as shards at once, each on an
# emulator and a host of its own: E2E_SHARD=I/N runs only shard I's units,
# still in that order, chosen by tools/e2e_shards.py from the seconds in
# e2e/android_durations.tsv. Unset, it is 1/1, every unit. A unit's setup is
# its own (chat_stand_in, live_session), since the one before it in a whole
# run may be in another shard.

# report NAME CMD...: CMD in a group of its own, a failure only warned about.
report() {
  local name=$1
  shift
  echo "::group::$name (report only)"
  "$@" || echo "::warning::$name failed -- report only, not gating"
  echo "::endgroup::"
}

# report_bare NAME CMD...: the same, for a block whose steps are groups of
# their own in the job log.
report_bare() {
  local name=$1
  shift
  "$@" || echo "::warning::$name failed -- report only, not gating"
}

# Into a file, not the array: a unit runs in a subshell of its own (run_unit).
gating() {
  echo "::group::$1 (gating)"
  flow "$1" || echo "$1" >>"$FAILED"
  echo "::endgroup::"
}
# gate NAME CMD...: a block that gates, in a group of its own: its failure is
# recorded, and fails the shard and the release, as a gating flow's does.
gate() {
  local name=$1
  shift
  echo "::group::$name (gating)"
  "$@" || { echo "$name" >>"$FAILED"; echo "::error::$name failed -- gating"; }
  echo "::endgroup::"
}

# gate_bare NAME CMD...: the same, for a block whose steps are groups of their
# own in the job log.
gate_bare() {
  local name=$1
  shift
  "$@" || { echo "$name" >>"$FAILED"; echo "::error::$name failed -- gating"; }
}

# What gates a release. smoke and connect_and_keybar from the start; then, in
# October 2026, the blocks that were green in two whole sharded runs once
# every unit started from a fresh app (#305): chat_version's three hosts,
# html_tab and chat_edit_previous; and chat_images, chat_follow_jump and
# chat_usage, green in the two runs that proved those.
GATING_UNITS=(smoke connect_and_keybar chat_version html_tab chat_edit_previous
  chat_images chat_follow_jump chat_usage)

# Their screenshots are evidence, wherever Maestro put them: see chat_version.
# -maxdepth keeps the evidence folder itself, a level deeper, out of it.
keep_chat_shots() {
  for shot in $( { find "$ROOT" -maxdepth 2 -name 'chat-tool-rows-*.png' -o -name 'chat-mermaid-*.png'
                   find "$HOME/.maestro" -name 'chat-tool-rows-*.png' -o -name 'chat-mermaid-*.png'; } 2>/dev/null); do
    mv -f "$shot" "$EVIDENCE/" && echo "evidence: $(basename "$shot")"
  done
}

# Chat mode against sessions the stand-in keeps (chat_stand_in): where a
# conversation comes back to, and how a tool's row reads.
stand_in_flow() {
  chat_stand_in
  flow "$1"
  local status=$?
  keep_chat_shots
  return "$status"
}

u_smoke() { gating smoke; }
u_connect_and_keybar() { gating connect_and_keybar; }
for name in tabs file_browser logs duplicate_session dotfiles card_tap_reconnect \
  port_forward_no_host terminal_selection; do
  eval "u_$name() { report $name flow $name; }"
done
u_single_instance() { report single_instance single_instance; }
u_jeansh_open2() { report_bare jeansh_open2 jeansh_open2; }
u_jeansh_open() { report jeansh_open jeansh_open; }
u_share_text() { report share_text share_text; }
u_share_chat() { report share_chat share_chat; }
u_chat_continue_cwd() { report chat_continue_cwd chat_continue_cwd; }
u_chat_version() { gate_bare chat_version chat_version; }
u_chat_code_copy() { report chat_code_copy chat_code_copy_alone; }
u_chat_scroll() { report chat_scroll stand_in_flow chat_scroll; }
u_chat_tool_rows() { report chat_tool_rows stand_in_flow chat_tool_rows; }
u_chat_mermaid() { report chat_mermaid stand_in_flow chat_mermaid; }

# Chat typing into a running Claude Code session and showing what is typed at
# its terminal, both ways (UAT issue #15), against a stand-in interactive
# session in a tmux pane on the host: tools/e2e_live_claude.py, which keeps
# the state file, the ❯ input line and the transcript chat's host checks
# read. The phone's message must be typed into the pane and answered; then a
# line typed at the pane itself, once the phone's has landed, must show in
# the chat too. chat_markdown shares its session.
u_chat_two_way() {
  chat_stand_in
  echo "::group::chat_two_way (report only)"
  live_session
  # The terminal's side: once the phone's message is in the transcript, a line
  # typed at the pane, as someone at that terminal would.
  local transcript=/home/$SSH_USER/.claude/projects/-home-$SSH_USER/$LIVE_SID.jsonl
  (
    for _ in $(seq 240); do
      sudo grep -qi 'hello from the phone' "$transcript" 2>/dev/null && break
      sleep 1
    done
    sleep 3
    sudo -u "$SSH_USER" -H tmux send-keys -t e2e-live -l 'typed at the terminal'
    sudo -u "$SSH_USER" -H tmux send-keys -t e2e-live Enter
  ) &
  local terminal_side=$!
  flow chat_two_way || echo "::warning::chat_two_way failed -- report only, not gating"
  kill "$terminal_side" 2>/dev/null
  echo "::endgroup::"
  echo "::group::chat_markdown (report only)"
  flow chat_markdown || echo "::warning::chat_markdown failed -- report only, not gating"
  keep_shots 'chat-markdown-*.png'
  end_live_session
  echo "::endgroup::"
  stand_in ''
}

u_html_tab() { gate html_tab html_tab; }
u_html_site() { report_bare html_site html_site; }
u_tab_close_narrow() { report_bare tab_close_narrow tab_close_narrow; }
u_chat_images() { gate chat_images chat_images; }
u_chat_attach_deliver() { report_bare chat_attach_deliver chat_attach_deliver; }
u_chat_usage() { gate chat_usage chat_usage; }
for name in chat_session_status chat_progress chat_working_backstop \
  chat_subagents chat_compact chat_model chat_cwd; do
  eval "u_$name() { report $name $name; }"
done
u_folder_zip() { report_bare folder_zip folder_zip; }
u_chat_outbox() { report_bare chat_outbox chat_outbox; }
u_chat_outbox_reconnect() { report_bare chat_outbox_reconnect chat_outbox_reconnect; }
u_chat_edit_previous() { gate chat_edit_previous chat_edit_previous; }
u_chat_follow_jump() { gate chat_follow_jump chat_follow_jump; }
for name in chat_ask_watched chat_slash chat_ask \
  chat_tasks bug_button tmux_mouse_reattach text_size_home soft_backspace; do
  eval "u_$name() { report $name $name; }"
done
# Not swipe_cursor, which reads the shell's working directory off the tab's
# title: a saved host's tab now shows its label, so it never sees a `cd`
# land, on main or in the redesign. It wants its checks moved to this host.
u_editor_save() { report editor_save editor_save; }
u_file_editor() { report file_editor file_editor; }
# The UI text size at its largest (issue #133), as the size it sets is saved
# and every flow after it would meet the app at 160%.
u_text_size() { report text_size flow text_size; }

for unit in "${UNITS[@]}"; do
  declare -F "u_$unit" >/dev/null || { echo "::error::no u_$unit for unit $unit"; exit 1; }
done

# What each unit took, for e2e/android_durations.tsv: e2e.yml uploads it.
DURATIONS="$ROOT/build/e2e-durations/shard-${SHARD%%/*}.tsv"
mkdir -p "$(dirname "$DURATIONS")"
: >"$DURATIONS"
FAILED=$(mktemp)
TIMED_OUT=$(mktemp -u)

# A unit's limit: three times what it takes, and never under ten minutes, so
# a hang costs minutes rather than the shard (v1.0.113's chat_cwd stalled 20
# minutes in one Maestro step). E2E_UNIT_LIMIT overrides it, for a test of
# the timeout itself.
unit_limit() {
  local took
  took=$(awk -v u="$1" '$1 == u { print $2 }' "$ROOT/e2e/android_durations.tsv")
  took=$((3 * ${took:-120}))
  echo "${E2E_UNIT_LIMIT:-$((took > 600 ? took : 600))}"
}

# run_unit UNIT LIMIT: the unit in a process group of its own, which a
# watchdog kills, with whatever the unit started (Maestro, a tail), once it
# runs past LIMIT seconds; TIMED_OUT then exists.
run_unit() {
  local pid wd rc
  rm -f "$TIMED_OUT"
  set -m
  "u_$1" &
  pid=$!
  (
    sleep "$2"
    touch "$TIMED_OUT"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 15
    kill -KILL -- "-$pid" 2>/dev/null
  ) &
  wd=$!
  set +m
  wait "$pid"
  rc=$?
  kill -- "-$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return "$rc"
}

for unit in "${MINE[@]}"; do
  started=$SECONDS
  limit=$(unit_limit "$unit")
  # Whatever unit ran before it in this shard, each meets the app as it would
  # alone after seed_host: no restored tabs, no outbox, no remembered folder.
  app_fresh
  run_unit "$unit" "$limit"
  if [ -e "$TIMED_OUT" ]; then
    echo "::endgroup::"
    # A gating unit that hangs fails the gate; a report-only one warns.
    if [[ " ${GATING_UNITS[*]} " == *" $unit "* ]]; then
      echo "$unit" >>"$FAILED"
      echo "::error::$unit timed out after $limit s -- gating"
    else
      echo "::warning::$unit timed out after $limit s -- report only, not gating"
    fi
    # Whatever it left on screen is not the next unit's to meet.
    adb shell am force-stop cloud.brata.terminal >/dev/null 2>&1
  fi
  printf '%s\t%s\n' "$unit" "$((SECONDS - started))" >>"$DURATIONS"
done
mapfile -t failed <"$FAILED"
rm -f "$FAILED" "$TIMED_OUT"
echo "::group::What each unit took"
cat "$DURATIONS"
echo "::endgroup::"

# Every other flow's takeScreenshot, as evidence: Maestro keeps a bare-named
# one in its own results, under takeScreenshot/, which the upload does not
# reach. Its failure screenshots stay where they are, uploaded apart.
find "$HOME/.maestro/tests" -path '*/takeScreenshot/*.png' \
  -exec mv -f {} "$EVIDENCE/" \; 2>/dev/null

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::gating flows failed in shard $SHARD: ${failed[*]}"
  exit 1
fi
echo "Every gating flow in shard $SHARD passed (seed_host first)"
