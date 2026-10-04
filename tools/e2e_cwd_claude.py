"""The stand-in `claude` for chat_continue_cwd, which says where it ran.

    e2e_cwd_claude.py -p [claude's own args]   chat's own stream-json process
    e2e_cwd_claude.py --bg [claude's own args] a new chat's first message

Every start appends a line to ~/.e2e-cwd-calls: the directory it ran in and
its arguments, which tools/e2e_android.sh reads for `--resume` and for where
it ran. A message is answered "Echo: ..."; one starting "tool:" first asks to
use Bash, twice, as a CLI with a tool refused in the same turn does, and waits
for the answers. A `--bg` lists a finished session in ~/.e2e-agents.json under
the directory it ran in, which chat then continues.

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import json
import os
import sys

HOME = os.environ['HOME']
CALLS = os.path.join(HOME, '.e2e-cwd-calls')
AGENTS = os.path.join(HOME, '.e2e-agents.json')


def log(mode, args):
    with open(CALLS, 'a') as f:
        f.write(json.dumps({'mode': mode, 'pwd': os.getcwd(), 'args': ' '.join(args)}) + '\n')


def background(args):
    log('bg', args)
    sid = 'e2e0000e-0000-4000-8000-00000000000e'
    try:
        rows = json.load(open(AGENTS))
    except (OSError, ValueError):
        rows = []
    rows = [r for r in rows if r.get('sessionId') != sid]
    rows.append({'id': 'e2e0newe', 'sessionId': sid, 'cwd': os.getcwd(), 'kind': 'background',
                 'name': 'E2E new chat', 'state': 'done', 'startedAt': 1790000000200})
    json.dump(rows, open(AGENTS, 'w'))
    print('backgrounded · e2e0newe · E2E new chat')


def stream(args):
    log('p', args)
    sid = args[args.index('--resume') + 1] if '--resume' in args else \
        'e2e0000e-0000-4000-8000-00000000000e'
    out = sys.stdout

    def say(event):
        out.write(json.dumps(event) + '\n')
        out.flush()

    say({'type': 'system', 'subtype': 'init', 'session_id': sid})
    for line in sys.stdin:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('type') != 'user':
            continue
        content = event.get('message', {}).get('content', [])
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        text = ' '.join(b.get('text', '') for b in content if b.get('type') == 'text')
        if text.startswith('tool:'):
            for n in (1, 2):
                say({'type': 'control_request', 'request_id': f'e2e-tool-{n}',
                     'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash',
                                 'input': {'command': 'ls'}, 'tool_use_id': f'e2e-t{n}'}})
            # Both answers, as a CLI waits for each.
            for _ in range(2):
                sys.stdin.readline()
        say({'type': 'assistant', 'session_id': sid,
             'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': f'Echo: {text}'}]}})
        say({'type': 'result', 'subtype': 'success', 'session_id': sid})


def main(argv):
    if argv and argv[0] == '--bg':
        background(argv)
    else:
        stream(argv)


main(sys.argv[1:])
