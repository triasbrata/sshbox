"""The stand-in Claude Code's pictures (#146), as 2.1.286 takes them.

Run through e2e_live_claude.py, which hands these modes here:

    --stream [claude -p's own args]   `claude -p` in stream-json: an image
        block in a user message is read, and the answer names its colour
    --tui --id ID | --tui --pane SID  the session's input line in raw mode,
        through `claude attach ID` or in a tmux pane: a bracketed paste of an
        existing picture's path becomes `[Image #N]` at the caret about a
        second later, numbered through the session; Enter records the
        message as "[Image #1] …" plus its image blocks
    --bg [args]                        `claude --bg`: a background session
        listed in ~/.e2e-agents.json, waiting for its first message

Everything it is given and does goes to ~/.e2e-pics.log, one JSON line an
event, for tools/e2e_android.sh to check the order of: a paste, its chip,
then the text after it.

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import base64
import codecs
import glob
import json
import os
import select
import struct
import sys
import termios
import time
import tty
import zlib

HOME = os.environ['HOME']
CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(HOME, '.claude')
AGENTS = os.path.join(HOME, '.e2e-agents.json')
LOG = os.path.join(HOME, '.e2e-pics.log')
PICTURES = ('.png', '.jpg', '.jpeg', '.gif', '.webp')
# The CLI's own wait before a pasted path becomes its chip: it reads the
# file first, 2 s for 8 MB.
CHIP_DELAY = 1.0


def log(event, **fields):
    with open(LOG, 'a') as f:
        f.write(json.dumps({'t': round(time.time(), 3), 'ev': event, **fields}) + '\n')


def transcript_of(sid):
    found = glob.glob(os.path.join(CONFIG, 'projects', '*', sid + '.jsonl'))
    if found:
        return found[0]
    cwd = os.getcwd()
    path = os.path.join(CONFIG, 'projects', cwd.replace('/', '-').replace('.', '-'),
                        sid + '.jsonl')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def record(path, event):
    with open(path, 'a') as f:
        f.write(json.dumps(event) + '\n')


def rows():
    try:
        return json.load(open(AGENTS))
    except (OSError, ValueError):
        return []


def listed(sid, **fields):
    all_rows = rows()
    for row in all_rows:
        if row.get('sessionId') == sid:
            row.update(fields)
    json.dump(all_rows, open(AGENTS, 'w'))


def colour(data):
    """The colour of a PNG's first pixel, by name: the first pixel of the
    first row is its own bytes whatever the row's filter."""
    try:
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            return 'a picture'
        at, idat, kind = 8, b'', 2
        while at < len(data):
            length, name = struct.unpack('>I4s', data[at:at + 8])
            body = data[at + 8:at + 8 + length]
            if name == b'IHDR':
                kind = body[9]
            elif name == b'IDAT':
                idat += body
            at += 12 + length
        if kind not in (2, 6):
            return 'a picture'
        r, g, b = zlib.decompress(idat)[1:4]
    except (struct.error, zlib.error, ValueError, IndexError):
        return 'a picture'
    names = {'red': (255, 0, 0), 'green': (0, 160, 0), 'blue': (0, 0, 255),
             'yellow': (255, 255, 0), 'white': (255, 255, 255), 'black': (0, 0, 0)}
    return min(names, key=lambda n: sum((x - y) ** 2 for x, y in zip(names[n], (r, g, b))))


def answer(text, pictures):
    if not pictures:
        return f'Echo: {text}'
    if len(pictures) == 1:
        return f'The picture is {colour(pictures[0])}. Echo: {text}'
    return f'Seen {len(pictures)}: {", ".join(colour(p) for p in pictures)}. Echo: {text}'


def stream(args):
    """`claude -p`: stream-json in, stream-json out."""
    sid = args[args.index('--resume') + 1] if '--resume' in args else \
        'e2e0000b-0000-4000-8000-00000000000b'
    log('stream', argv=args)
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
        content = event.get('message', {}).get('content', [])
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        text = ' '.join(b.get('text', '') for b in content if b.get('type') == 'text')
        blocks = [b for b in content if b.get('type') == 'image']
        pictures = [base64.b64decode(b['source']['data']) for b in blocks]
        log('message', text=text, images=[b['source'].get('media_type') for b in blocks])
        said = answer(text, pictures)
        say({'type': 'assistant', 'session_id': sid,
             'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': said}]}})
        say({'type': 'result', 'subtype': 'success', 'session_id': sid})


def background(args):
    """`claude --bg`: a session listed as waiting for its first message, its
    process a sleep for chat's follow to watch."""
    log('bg', argv=args)
    sid = 'e2e0000a-0000-4000-8000-00000000000a'
    pid = os.fork()
    if pid == 0:
        os.setsid()
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        os.execvp('sleep', ['sleep', '3600'])
    all_rows = [r for r in rows() if r.get('sessionId') != sid]
    all_rows.append({'id': 'e2e0000a', 'sessionId': sid, 'pid': pid, 'name': 'E2E new picture chat',
                     'cwd': HOME, 'kind': 'background', 'state': 'blocked', 'status': 'idle',
                     'startedAt': int(time.time() * 1000)})
    json.dump(all_rows, open(AGENTS, 'w'))
    print('backgrounded · e2e0000a · e2e')


def tui(args):
    """The input line, in raw mode on the terminal it is given."""
    pane = args[0] == '--pane'
    if pane:
        sid = args[1]
    else:  # --id ID
        sid = next((r['sessionId'] for r in rows() if r.get('id') == args[1]), None)
        if sid is None:
            print(f'No session {args[1]}')
            return 1
    path = transcript_of(sid)
    state = None
    if pane:
        state = os.path.join(CONFIG, 'sessions', f'{os.getpid()}.json')
        os.makedirs(os.path.dirname(state), exist_ok=True)
        with open(state, 'w') as f:
            json.dump({'pid': os.getpid(), 'sessionId': sid, 'cwd': os.getcwd(),
                       'kind': 'interactive', 'status': 'idle'}, f, separators=(',', ':'))
    # Numbered through the session, from what its transcript gave out.
    count = 0
    if os.path.exists(path):
        for line in open(path):
            try:
                count = max([count, *json.loads(line).get('imagePasteIds', [])])
            except (ValueError, TypeError, AttributeError):
                pass
    log('tui', sid=sid, pane=pane, first=count + 1)

    def write(text):
        os.write(1, text.encode())

    buf = ''
    images = []  # (number, path), in the order their chips went in
    pending = []  # (due, path)

    def draw():
        write('\r\x1b[K❯ ' + buf)

    old = termios.tcgetattr(0)
    tty.setraw(0)
    decoder = codecs.getincrementaldecoder('utf-8')('replace')
    data = ''
    try:
        write('\x1b[?2004h')
        draw()
        while True:
            wait = max(0.0, min(d for d, _ in pending) - time.time()) if pending else None
            ready, _, _ = select.select([0], [], [], wait)
            for due, picture in list(pending):
                if due <= time.time():
                    pending.remove((due, picture))
                    count += 1
                    images.append((count, picture))
                    buf += f'[Image #{count}] '
                    log('chip', n=count, path=picture)
                    draw()
            if not ready:
                continue
            chunk = os.read(0, 4096)
            if not chunk:
                break
            data += decoder.decode(chunk)
            typed = ''
            while data:
                if data.startswith('\x1b[200~'):
                    end = data.find('\x1b[201~')
                    if end < 0:
                        break
                    pasted, data = data[6:end], data[end + 6:]
                    if typed:
                        log('text', v=typed)
                        typed = ''
                    if pasted.lower().endswith(PICTURES) and os.path.isfile(pasted):
                        log('paste', path=pasted)
                        pending.append((time.time() + CHIP_DELAY, pasted))
                    else:
                        log('paste-text', v=pasted)
                        buf += pasted
                    continue
                if data[0] == '\x1b' and '\x1b[200~'.startswith(data[:6]) and len(data) < 6:
                    break
                ch, data = data[0], data[1:]
                if ch == '\r':
                    if typed:
                        log('text', v=typed)
                        typed = ''
                    text = buf.strip()
                    log('enter', text=text, images=[n for n, _ in images])
                    blobs = [open(p, 'rb').read() for _, p in images]
                    record(path, {
                        'type': 'user', 'imagePasteIds': [n for n, _ in images],
                        'message': {'role': 'user', 'content': [
                            {'type': 'text', 'text': text},
                            *({'type': 'image', 'source': {
                                'type': 'base64', 'media_type': 'image/png',
                                'data': base64.b64encode(b).decode()}} for b in blobs)]}})
                    said = answer(text, blobs)
                    record(path, {'type': 'assistant', 'message': {
                        'role': 'assistant', 'content': [{'type': 'text', 'text': said}]}})
                    listed(sid, state='done')
                    write('\r\n' + said + '\r\n')
                    buf, images, pending = '', [], []
                elif ch in '\x7f\x08':
                    buf = buf[:-1]
                elif ch >= ' ':
                    buf += ch
                    typed += ch
            if typed:
                log('text', v=typed)
            draw()
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)
        if state:
            try:
                os.remove(state)
            except OSError:
                pass
    return 0


def main(argv):
    mode, rest = argv[0], argv[1:]
    if mode == '--stream':
        stream(rest)
    elif mode == '--bg':
        background(rest)
    elif mode == '--tui':
        return tui(rest)
    return 0
