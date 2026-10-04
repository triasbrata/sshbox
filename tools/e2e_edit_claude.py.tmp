"""The stand-in `claude -p` for #226, chat's ↑ going back to the last message.

    e2e_edit_claude.py [claude -p's own args]

Stream-json in and out, like the CLI. Every start's arguments go to
~/.e2e-edit-cmds, one line each, for tools/e2e_android.sh to look for
`--resume-session-at ROW --fork-session` in. A message is answered "Echo: ..."
and recorded in the session's transcript as the CLI records it, a user row
with a uuid and a parentUuid, which is where a revision cuts; one starting
"slow:" is answered 20 s later, a turn long enough to press ↑ in.

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import glob
import json
import os
import sys
import time

HOME = os.environ['HOME']
CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(HOME, '.claude')
ROOT_ROW = 'e2e0000f-aaaa-4000-8000-000000000000'
FORK = 'e2e0000f-0000-4000-8000-00000000000f'


def main(args):
    with open(os.path.join(HOME, '.e2e-edit-cmds'), 'a') as f:
        f.write(' '.join(args) + '\n')
    sid = args[args.index('--resume') + 1] if '--resume' in args else FORK
    if '--fork-session' in args:
        sid = FORK
    found = glob.glob(os.path.join(CONFIG, 'projects', '*', sid + '.jsonl'))
    path = found[0] if found else None
    out = sys.stdout

    def say(event):
        out.write(json.dumps(event) + '\n')
        out.flush()

    def record(event):
        if path:
            with open(path, 'a') as f:
                f.write(json.dumps(event) + '\n')

    say({'type': 'system', 'subtype': 'init', 'session_id': sid})
    n = 0
    parent = ROOT_ROW
    for line in sys.stdin:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        content = event.get('message', {}).get('content', [])
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        text = ' '.join(b.get('text', '') for b in content if b.get('type') == 'text')
        if not text:
            continue
        n += 1
        user = f'e2e0000f-bbbb-4000-8000-{n:012d}'
        reply = f'e2e0000f-cccc-4000-8000-{n:012d}'
        record({'type': 'user', 'uuid': user, 'parentUuid': parent,
                'message': {'role': 'user', 'content': text}})
        if text.startswith('slow:'):
            time.sleep(20)
        said = f'Echo: {text}'
        record({'type': 'assistant', 'uuid': reply, 'parentUuid': user,
                'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': said}]}})
        parent = reply
        say({'type': 'assistant', 'session_id': sid,
             'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': said}]}})
        say({'type': 'result', 'subtype': 'success', 'session_id': sid})


main(sys.argv[1:])
