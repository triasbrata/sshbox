"""A stand-in for an interactive Claude Code session, run in a tmux pane.

It is what chat's typing into a running session checks for, and nothing
more: its state file in ~/.claude/sessions/<pid>.json naming its session,
idle and waiting for nothing; a ❯ input line with the cursor just after it;
and the pane's foreground. Each line typed at it — from the chat, which types
into the pane, or at the pane itself — goes into its transcript as the user's
turn, followed by an answer, which chat reads back as it follows the
transcript.

A line starting `slow:` plays a slow turn instead, shaped on one 2.1.286
wrote: the prompt with its time, a message calling Bash with its usage four
seconds later, the result four seconds after that, then a closing message of
two lines sharing one message id and the turn's duration. Meanwhile its row
in the stand-in listing, ~/.e2e-agents.json, says busy, as `claude agents`
says of a session mid-turn.

    python3 e2e_live_claude.py SESSION_ID

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import datetime
import json
import os
import sys
import time

session = sys.argv[1]
config = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.environ['HOME'], '.claude')
cwd = os.getcwd()
transcript = os.path.join(
    config, 'projects', cwd.replace('/', '-').replace('.', '-'), session + '.jsonl')
os.makedirs(os.path.dirname(transcript), exist_ok=True)
state = os.path.join(config, 'sessions', f'{os.getpid()}.json')
os.makedirs(os.path.dirname(state), exist_ok=True)
# Compact, as the CLI writes it: chat's host script greps "sessionId":"…".
with open(state, 'w') as f:
    json.dump({'pid': os.getpid(), 'sessionId': session, 'cwd': cwd,
               'kind': 'interactive', 'status': 'idle'}, f, separators=(',', ':'))


def record(event):
    with open(transcript, 'a') as f:
        f.write(json.dumps(event) + '\n')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='milliseconds').replace('+00:00', 'Z')


def listed_as(status):
    path = os.path.join(os.environ['HOME'], '.e2e-agents.json')
    try:
        rows = json.load(open(path))
    except (OSError, ValueError):
        return
    for row in rows:
        if row.get('sessionId') == session:
            row['status'] = status
    json.dump(rows, open(path, 'w'))


def slow_turn(text):
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    time.sleep(4)
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_1', 'role': 'assistant', 'stop_reason': 'tool_use',
        'usage': {'output_tokens': 87},
        'content': [{'type': 'tool_use', 'id': 'toolu_e2e_1', 'name': 'Bash',
                     'input': {'command': 'sleep 2; echo done'}}]}})
    time.sleep(4)
    record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_e2e_1', 'content': 'done'}]}})
    time.sleep(4)
    for block in ({'type': 'thinking', 'thinking': '', 'signature': 'e2e'},
                  {'type': 'text', 'text': 'Slow answer: done'}):
        record({'type': 'assistant', 'timestamp': now(), 'message': {
            'id': 'msg_e2e_2', 'role': 'assistant', 'stop_reason': 'end_turn',
            'usage': {'output_tokens': 1313}, 'content': [block]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 12000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Slow answer: done\n')


def prompt():
    sys.stdout.write('❯ ')
    sys.stdout.flush()


prompt()
while True:
    line = sys.stdin.readline()
    if not line:
        break
    text = line.rstrip('\n')
    if text.startswith('slow:'):
        slow_turn(text)
    elif text:
        record({'type': 'user', 'message': {'role': 'user', 'content': text}})
        answer = f'Echo: {text}'
        record({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        sys.stdout.write(answer + '\n')
    prompt()
