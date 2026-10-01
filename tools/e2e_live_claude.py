"""A stand-in for an interactive Claude Code session, run in a tmux pane.

It is what chat's typing into a running session checks for, and nothing
more: its state file in ~/.claude/sessions/<pid>.json naming its session,
idle and waiting for nothing; a ❯ input line with the cursor just after it;
and the pane's foreground. Each line typed at it — from the chat, which types
into the pane, or at the pane itself — goes into its transcript as the user's
turn, followed by an answer, which chat reads back as it follows the
transcript. A line starting with `/` is a command instead, recorded as 2.1.286
records one it runs itself: a `system` line of subtype `local_command` holding
its name, message and arguments in tags, then another with what it printed.

    python3 e2e_live_claude.py SESSION_ID

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import json
import os
import sys

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


def prompt():
    sys.stdout.write('❯ ')
    sys.stdout.flush()


prompt()
while True:
    line = sys.stdin.readline()
    if not line:
        break
    text = line.rstrip('\n')
    if text.startswith('/'):
        name, _, args = text[1:].partition(' ')
        record({'type': 'system', 'subtype': 'local_command', 'content':
                f'<command-name>/{name}</command-name>\n'
                f'<command-message>{name}</command-message>\n'
                f'<command-args>{args.strip()}</command-args>'})
        printed = f'Context Usage: 12k/200k tokens (6%) from /{name}'
        record({'type': 'system', 'subtype': 'local_command', 'content':
                f'<local-command-stdout>{printed}</local-command-stdout>'})
        sys.stdout.write(printed + '\n')
    elif text:
        record({'type': 'user', 'message': {'role': 'user', 'content': text}})
        answer = f'Echo: {text}'
        record({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        sys.stdout.write(answer + '\n')
    prompt()
