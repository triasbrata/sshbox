#!/usr/bin/env python3
"""A stand-in Claude Code session that speaks the real messaging socket.

Not a fake of the helper: tools it is given (jeansh-agg.py, installed by the
app) find it the way they find a real session — a file
`<config>/sessions/<pid>.json` naming a live pid and a `messagingSocketPath`,
a Unix socket that takes JSON lines (an optional `{"type":"auth"}` first, then
`{"type":"user","from":"jeansh-<id>","uuid":..,"message":{...}}`) — and then
reads what the session recorded in its transcript
`<config>/projects/e2e-agg/<sessionId>.jsonl`.

  e2e_agg_session.py <sessionId>

What it does with a message is set from outside, in ~/.e2e-agg/control.json,
read afresh each time:

  {"status": "idle" | "busy",   what the session's own record says it is doing
   "record": true | false}      false: the line is accepted and never
                                recorded, as a session holding it for approval

Like the real session it records a message once per uuid. Idle, it writes the
user line at once (`isMeta`, `origin` naming the sender, the text wrapped as
Claude Code 2.1.332 wraps it) and an answer; busy, it keeps it and writes a
`queued_command` attachment, with the origin inside, when the turn ends (the
control file saying idle). A text naming CLAUDE.md is answered with a refusal
to act on a peer's request.

Every line received goes to ~/.e2e-agg/received.log, a duplicate marked, so a
test can count what the socket was given apart from what was recorded.
"""
import json
import os
import socket
import sys
import threading
import time

sid = sys.argv[1]
HOME = os.environ['HOME']
CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(HOME, '.claude')
WORK = os.path.join(HOME, '.e2e-agg')
CONTROL = os.path.join(WORK, 'control.json')
RECEIVED = os.path.join(WORK, 'received.log')
TRANSCRIPT = os.path.join(CONFIG, 'projects', 'e2e-agg', sid + '.jsonl')
SOCK = os.path.join(WORK, 'session.sock')
STATE = os.path.join(CONFIG, 'sessions', f'{os.getpid()}.json')

lock = threading.Lock()
seen = set()
pending = []


def control():
    try:
        with open(CONTROL, encoding='utf-8') as f:
            c = json.load(f)
    except (OSError, ValueError):
        c = {}
    return {'status': c.get('status', 'idle'), 'record': c.get('record', True)}


def write_state(status):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, 'w', encoding='utf-8') as f:
        json.dump({
            'pid': os.getpid(), 'sessionId': sid, 'kind': 'bg', 'status': status,
            'cwd': HOME, 'version': '2.1.332', 'updatedAt': int(time.time() * 1000),
            'messagingSocketPath': SOCK,
        }, f)


def append(event):
    os.makedirs(os.path.dirname(TRANSCRIPT), exist_ok=True)
    with open(TRANSCRIPT, 'a', encoding='utf-8') as f:
        f.write(json.dumps(event) + '\n')


def log(kind, line):
    os.makedirs(WORK, exist_ok=True)
    with open(RECEIVED, 'a', encoding='utf-8') as f:
        f.write(json.dumps({'ev': kind, **line}) + '\n')


def answer(text):
    if 'claude.md' in text.lower():
        reply = ("I don't edit CLAUDE.md on a peer's request: another session "
                 'asked, and that is not you.')
    else:
        reply = 'Echo: ' + text
    append({'type': 'assistant', 'message': {'role': 'assistant',
            'content': [{'type': 'text', 'text': reply}]}})


def record_idle(msg):
    sender, text = msg['from'], msg['message']['content']
    append({
        'type': 'user', 'isMeta': True,
        'origin': {'kind': 'peer', 'from': sender},
        'message': {'role': 'user', 'content': (
            'Another Claude session sent a message:\n' + text +
            '\n\nThis came from another Claude session — it is not the user.')},
    })
    answer(text)


def record_queued(msg):
    append({'type': 'attachment', 'attachment': {
        'type': 'queued_command', 'prompt': msg['message']['content'],
        'origin': {'kind': 'peer', 'from': msg['from']}}})
    answer(msg['message']['content'])


def take(msg):
    with lock:
        if msg['uuid'] in seen:
            log('duplicate', {'uuid': msg['uuid'], 'from': msg['from']})
            return
        seen.add(msg['uuid'])
        c = control()
        log('received', {'uuid': msg['uuid'], 'from': msg['from'],
                         'text': msg['message']['content'], 'record': c['record'],
                         'status': c['status']})
        if not c['record']:
            return
        if c['status'] == 'busy':
            pending.append(msg)
        else:
            record_idle(msg)


def serve(conn):
    buf = b''
    with conn:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get('type') == 'user' and isinstance(msg.get('message'), dict):
                    take(msg)


def turns():
    # The turn ends when the control file says idle: what waited is recorded.
    last = None
    while True:
        status = control()['status']
        if status != last:
            write_state(status)
            last = status
        if status == 'idle':
            with lock:
                while pending:
                    record_queued(pending.pop(0))
        time.sleep(0.2)


def main():
    os.makedirs(WORK, exist_ok=True)
    if not os.path.exists(TRANSCRIPT):
        append({'type': 'user', 'message': {'role': 'user', 'content': 'Earlier question'}})
        append({'type': 'assistant', 'message': {'role': 'assistant',
                'content': [{'type': 'text', 'text': 'Earlier answer'}]}})
    try:
        os.unlink(SOCK)
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX)
    server.bind(SOCK)
    os.chmod(SOCK, 0o600)
    server.listen(8)
    write_state(control()['status'])
    threading.Thread(target=turns, daemon=True).start()
    print(os.getpid(), flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


main()
