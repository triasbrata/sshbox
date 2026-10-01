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
says of a session mid-turn. A line starting `wait:` stops at a permission
prompt instead: its row says waiting, with waitingFor, for twenty seconds.
A line starting `long:` writes six long answers after five seconds, for a
chat put behind another tab meanwhile to come back following.

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


def listed_as(status, waiting_for=None):
    path = os.path.join(os.environ['HOME'], '.e2e-agents.json')
    try:
        rows = json.load(open(path))
    except (OSError, ValueError):
        return
    for row in rows:
        if row.get('sessionId') == session:
            row['status'] = status
            row.pop('waitingFor', None)
            if waiting_for:
                row['waitingFor'] = waiting_for
    json.dump(rows, open(path, 'w'))


def waiting_turn(text):
    """A turn stopped at a permission prompt: a Bash call that never gets a
    result while the listing says waiting, as `claude agents` says of a tool
    waiting to be approved; then, twenty seconds on, approved and done."""
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_w1', 'role': 'assistant', 'stop_reason': 'tool_use',
        'usage': {'output_tokens': 12},
        'content': [{'type': 'tool_use', 'id': 'toolu_e2e_w1', 'name': 'Bash',
                     'input': {'command': 'rm -rf /tmp/e2e-wait'}}]}})
    listed_as('waiting', 'permission prompt')
    time.sleep(20)
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_e2e_w1', 'content': ''}]}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_w2', 'role': 'assistant', 'stop_reason': 'end_turn',
        'usage': {'output_tokens': 5},
        'content': [{'type': 'text', 'text': 'Waited answer: done'}]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 20000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Waited answer: done\n')


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


def long_turn(text):
    """Five seconds' grace, for the chat to be put behind another tab, then
    six answers of twenty-five lines each, well over a screen, the last
    ending "Long answer 6 end"."""
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    time.sleep(5)
    for n in range(1, 7):
        lines = [f'Long answer {n}, line {k}' for k in range(1, 25)]
        record({'type': 'assistant', 'timestamp': now(), 'message': {
            'id': f'msg_e2e_l{n}', 'role': 'assistant',
            'stop_reason': 'end_turn' if n == 6 else None,
            'content': [{'type': 'text',
                         'text': '\n\n'.join(lines + [f'Long answer {n} end'])}]}})
        time.sleep(0.5)
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 8000,
            'timestamp': now()})
    sys.stdout.write('Long answer 6 end\n')


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
    elif text.startswith('wait:'):
        waiting_turn(text)
    elif text.startswith('long:'):
        long_turn(text)
    elif text:
        record({'type': 'user', 'message': {'role': 'user', 'content': text}})
        answer = f'Echo: {text}'
        record({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        sys.stdout.write(answer + '\n')
    prompt()
