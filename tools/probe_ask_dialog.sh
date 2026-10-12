#!/bin/sh
# Measures the keys Claude Code's AskUserQuestion dialog takes in a terminal,
# for chat mode to answer a question a watched session asks (ClaudeChat
# .dialogKeys). Run by hand, by the user, never by an agent:
#
#   bash tools/probe_ask_dialog.sh
#
# What it does, and does not:
# - Each scenario starts a fresh interactive `claude --tools AskUserQuestion`
#   on a private tmux server (`tmux -L askprobe`) in a scratch directory, with
#   a fixed prompt that asks exactly one AskUserQuestion, on Haiku: five short
#   turns of quota in all.
# - CLAUDE_CONFIG_DIR is a scratch folder holding a 0600 copy of
#   ~/.claude/.credentials.json, so the trust prompt, the onboarding and the
#   transcripts never touch ~/.claude.json, ~/.claude/settings.json or
#   ~/.claude/projects. On EXIT, INT or TERM the tmux server is killed by
#   name and the scratch folder, the copy with it, is removed.
# - Every CLAUDE_CODE_* and CLAUDECODE variable is unset, so the probe cannot
#   reach the session it is run from.
# - It captures the dialog before any key and after each key, then prints
#   the answers the transcript recorded (toolUseResult.answers), all into one
#   results file. The credentials copy is never read or printed; e-mail
#   addresses on screen are masked.
set -eu

OUT_DIR=/workspace/sshbox-dev-center/assets/2026-10-12/ask-probe
SOCK=askprobe
STEP_WAIT=120 # seconds a dialog or an answer may take to come
KEY_GAP=1     # seconds between keys, for the dialog to redraw

HOME_CFG="$HOME/.claude"
[ -f "$HOME_CFG/.credentials.json" ] || {
  echo "no $HOME_CFG/.credentials.json to copy; nothing done" >&2
  exit 1
}

for name in $(env | sed -n 's/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$name"
done
unset CLAUDECODE TMUX TMUX_PANE 2>/dev/null || true

SCRATCH=$(mktemp -d)
cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$SCRATCH"
CFG="$SCRATCH/cfg"
WORK="$SCRATCH/work"
mkdir -m 700 "$CFG" "$WORK"
(umask 077 && cp "$HOME_CFG/.credentials.json" "$CFG/.credentials.json")
chmod 600 "$CFG/.credentials.json"
# Onboarding done and the scratch folder trusted, in the scratch config only.
printf '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"%s":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}\n' \
  "$WORK" >"$CFG/.claude.json"

mkdir -p "$OUT_DIR"
RESULTS="$OUT_DIR/results-$(date +%Y%m%d-%H%M%S).txt"
: >"$RESULTS"
say() { printf '%s\n' "$*" | tee -a "$RESULTS"; }

sums() {
  for file in "$HOME_CFG/settings.json" "$HOME/.claude.json"; do
    if [ -f "$file" ]; then sha256sum "$file"; else echo "absent $file"; fi
  done
}
say "== sha256 before"
sums | tee -a "$RESULTS"
say "claude: $(timeout 20 claude --version </dev/null 2>&1 | head -n 1)"
say "tmux: $(tmux -V)"

t() { tmux -L "$SOCK" "$@"; }

# The pane's screen, e-mail addresses masked, into the results.
screen() {
  say "---- screen: $1"
  t capture-pane -p -t probe 2>/dev/null |
    sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+/<email>/g' |
    tee -a "$RESULTS"
  say "---- end screen"
}

# One key, as tmux names it, then the screen.
key() {
  say ">> key: $1"
  t send-keys -t probe "$1" || say "!! send-keys failed"
  sleep "$KEY_GAP"
  screen "after $1"
}

# Text as chat mode sends an Other answer: one bracketed paste, through
# load-buffer and paste-buffer, never send-keys.
paste() {
  say ">> paste: $1"
  printf '\033[200~%s\033[201~' "$1" | t load-buffer -b askprobe - &&
    t paste-buffer -r -d -b askprobe -t probe || say "!! paste failed"
  sleep "$KEY_GAP"
  screen "after paste"
}

# Until the screen holds $1, or STEP_WAIT seconds.
wait_screen() {
  i=0
  while [ "$i" -lt "$STEP_WAIT" ]; do
    if t capture-pane -p -t probe 2>/dev/null | grep -qF "$1"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  say "!! timed out waiting for: $1"
  return 1
}

# The answers recorded for the question, or what the result was instead.
answers() {
  i=0
  while [ "$i" -lt "$STEP_WAIT" ]; do
    found=$(find "$CFG/projects" -name '*.jsonl' 2>/dev/null | head -n 1)
    if [ -n "$found" ] && grep -q '"toolUseResult"' "$found"; then
      say "== recorded result"
      # The answers when there are some; a decline is a string instead.
      grep -o '"answers":{[^}]*}' "$found" | tee -a "$RESULTS" || true
      grep -o '"toolUseResult":"[^"]*"' "$found" | tee -a "$RESULTS" || true
      grep -o '"is_error":true' "$found" | head -n 1 | tee -a "$RESULTS" ||
        true
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  say "!! no tool result recorded within ${STEP_WAIT}s"
  return 1
}

# scenario NAME PROMPT KEY...   (a key "paste:TEXT" pastes TEXT)
scenario() {
  name=$1 prompt=$2
  shift 2
  say ""
  say "=================== scenario: $name"
  say "keys planned: $*"
  rm -rf "$CFG/projects"
  t kill-session -t probe >/dev/null 2>&1 || true
  # Several arguments: tmux runs them as they are, no shell in between.
  t -f /dev/null new-session -d -s probe -x 120 -y 40 -c "$WORK" \
    env CLAUDE_CONFIG_DIR="$CFG" timeout 300 claude --model haiku \
    --tools AskUserQuestion --permission-mode default "$prompt"
  # The dialog's own footer: the question's text is in the prompt as well,
  # which is on screen before the dialog is.
  if ! wait_screen "to navigate"; then
    screen "no dialog"
    return 0
  fi
  sleep 2
  screen "dialog before any key"
  for k in "$@"; do
    case $k in
      paste:*) paste "${k#paste:}" ;;
      *) key "$k" ;;
    esac
  done
  answers || true
  screen "end"
  t kill-session -t probe >/dev/null 2>&1 || true
}

ask() {
  printf 'Call the AskUserQuestion tool exactly once, with exactly this input and nothing else: %s. After it returns, reply with only the word done. Do not call any other tool.' "$1"
}

ONE='{"questions":[{"question":"Probe single: which fruit?","header":"Fruit","multiSelect":false,"options":[{"label":"Apple","description":"red"},{"label":"Banana","description":"yellow"},{"label":"Cherry","description":"dark"}]}]}'
MULTI='{"questions":[{"question":"Probe multi: which colours?","header":"Colours","multiSelect":true,"options":[{"label":"Red","description":"warm"},{"label":"Green","description":"calm"},{"label":"Blue","description":"cool"}]}]}'
OTHER='{"questions":[{"question":"Probe other: which city?","header":"City","multiSelect":false,"options":[{"label":"Paris","description":"France"},{"label":"Rome","description":"Italy"}]}]}'
TWO='{"questions":[{"question":"Probe two A: which size?","header":"Size","multiSelect":false,"options":[{"label":"Small","description":"s"},{"label":"Large","description":"l"}]},{"question":"Probe two B: which shape?","header":"Shape","multiSelect":false,"options":[{"label":"Circle","description":"round"},{"label":"Square","description":"edges"}]}]}'
ESC='{"questions":[{"question":"Probe escape: which day?","header":"Day","multiSelect":false,"options":[{"label":"Monday","description":"m"},{"label":"Friday","description":"f"}]}]}'

# Candidate keys. Expected: Banana; Red, Blue; the typed text; Large and
# Circle; and what Esc records. The screens after each key say what really
# happened where they differ.
scenario single "$(ask "$ONE")" Down Enter Enter
scenario multi "$(ask "$MULTI")" Space Down Down Space Enter Tab Enter Enter
scenario other "$(ask "$OTHER")" Down Down "paste:Lisbon, not \$(touch x) or [201~ that" Enter Enter
scenario two "$(ask "$TWO")" Down Enter Enter Enter
scenario escape "$(ask "$ESC")" Escape

say ""
say "== sha256 after"
sums | tee -a "$RESULTS"
[ -e "$WORK/x" ] && say "!! the pasted \$(touch x) ran" || say "pasted \$(touch x) did not run"
echo
echo "results: $RESULTS"
