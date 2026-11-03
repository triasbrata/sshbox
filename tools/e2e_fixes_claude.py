"""A stand-in for chat's own Claude (`claude -p --resume SID`, stream-json), for
tools/e2e_android.sh's chat_fixes block.

It says its init, then reads the chat's lines. Every user message is logged to
~/.e2e-fixes.log as `received`, with its text and this process's pid. With
~/.e2e-fixes-drop present it goes no further, as a message whose bytes were
lost with a dropped connection; otherwise the turn is recorded in the session's
transcript, as the CLI records it, and answered `Echo: <text>`.
"""

import datetime
import json
import os
import sys
import time
import uuid

HOME = os.environ['HOME']
LOG = os.path.join(HOME, '.e2e-fixes.log')
DROP = os.path.join(HOME, '.e2e-fixes-drop')


def log(event, **fields):
    with open(LOG, 'a') as f:
        f.write(json.dumps({'t': round(time.time(), 3), 'ev': event,
                            'pid': os.getpid(), **fields}) + '\n')


def say(event):
    sys.stdout.write(json.dumps(event) + '\n')
    sys.stdout.flush()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='milliseconds').replace('+00:00', 'Z')


def record(sid, event):
    projects = os.path.join(HOME, '.claude', 'projects', HOME.replace('/', '-'))
    os.makedirs(projects, exist_ok=True)
    with open(os.path.join(projects, sid + '.jsonl'), 'a') as f:
        f.write(json.dumps({'uuid': str(uuid.uuid4()), 'timestamp': now(),
                            'sessionId': sid, **event}) + '\n')


def text_of(message):
    content = (message or {}).get('content')
    if isinstance(content, str):
        return content
    return ''.join(part.get('text', '') for part in content or []
                   if isinstance(part, dict) and part.get('type') == 'text')


def main(argv):
    sid = argv[argv.index('--resume') + 1] if '--resume' in argv else str(uuid.uuid4())
    log('start', sid=sid)
    say({'type': 'system', 'subtype': 'init', 'session_id': sid})
    for line in sys.stdin:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get('type') != 'user':
            continue
        text = text_of(event.get('message'))
        log('received', sid=sid, text=text)
        if os.path.exists(DROP):
            log('dropped', sid=sid, text=text)
            continue
        record(sid, {'type': 'user', 'message': {'role': 'user', 'content': text}})
        answer = 'Echo: ' + text
        record(sid, {'type': 'assistant', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        say({'type': 'assistant', 'session_id': sid, 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        say({'type': 'result', 'subtype': 'success', 'session_id': sid})
        log('answered', sid=sid, text=text)
    log('end', sid=sid)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
