"""The stand-in Claude Code's question dialog (AskUserQuestion), as the real
2.1.287 was measured to behave in a terminal (tools/probe_ask_dialog.sh), for
.maestro/chat_ask_watched.yaml: chat answers a WATCHED session's question by
typing into the session's own dialog.

    python3 e2e_ask_watched.py --seed-transcripts
    python3 e2e_ask_watched.py --seed-rows '{"single": PID, ...}'
    python3 e2e_ask_watched.py --attach ID     `claude attach ID`, a background session
    python3 e2e_ask_watched.py --pane SID      an interactive session, in a tmux pane

The dialog's keys are the measured ones, nothing chat-shaped:
  * a single choice: Down moves, Enter picks the row; with one question that
    answers it at once, with several it moves on to the next;
  * several choices: Space ticks, Enter ticks as well (it toggles), Tab goes
    on, to the review "1. Submit answers", and Enter there submits;
  * "Type something.": typed text, then Enter; with several questions Enter
    moves on and the review comes last; Esc declines the whole question.
  * no bracketed paste: a marker would show in the text literally.
The footer reads "Enter to select"; what is answered goes into the
transcript as the tool's result with `toolUseResult.answers`, the session's
listing loses its `waitingFor`, and the session goes on.

Everything it is given goes to ~/.e2e-ask.log, a JSON line each: every attach
and every key, for tools/e2e_android.sh to check what reached the dialog.

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import codecs
import datetime
import glob
import json
import os
import select
import signal
import sys
import termios
import time
import tty

HOME = os.environ['HOME']
CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(HOME, '.claude')
AGENTS = os.path.join(HOME, '.e2e-agents.json')
LOG = os.path.join(HOME, '.e2e-ask.log')


def ask(question, header, multi, options):
    return {'question': question, 'header': header, 'multiSelect': multi,
            'options': [{'label': l, 'description': d} for l, d in options]}


# n makes the ids: session e2e00000-0000-4000-8000-00000000a0NN, short id
# e2easkNN. The names are what chat's sidebar shows.
SESSIONS = {
    'single': dict(n=1, kind='background', waiting='input needed', questions=[
        ask('Which fruit?', 'Fruit', False,
            [('Apple', 'red'), ('Banana', 'yellow'), ('Cherry', 'dark')])]),
    'multi': dict(n=2, kind='background', waiting='input needed', questions=[
        ask('Which colours?', 'Colours', True,
            [('Red', 'warm'), ('Green', 'calm'), ('Blue', 'cool')])]),
    'two': dict(n=3, kind='background', waiting='input needed', questions=[
        ask('Which size?', 'Size', False, [('Small', 'tiny'), ('Large', 'big')]),
        ask('Which shape?', 'Shape', False, [('Circle', 'round'), ('Square', 'edges')])]),
    'other': dict(n=4, kind='background', waiting='input needed', questions=[
        ask('Which city?', 'City', False, [('Paris', 'France'), ('Rome', 'Italy')])]),
    # Held at a permission prompt, with the question open in its transcript.
    'perm': dict(n=5, kind='background', waiting='permission prompt', questions=[
        ask('Which day?', 'Day', False, [('Monday', 'first'), ('Friday', 'last')])]),
    'pane': dict(n=6, kind='interactive', waiting='input needed', questions=[
        ask('Which drink?', 'Drink', False,
            [('Tea', 'hot'), ('Coffee', 'dark'), ('Water', 'plain')])]),
}


def sid_of(key):
    return 'e2e00000-0000-4000-8000-00000000a%03d' % SESSIONS[key]['n']


def projects():
    return os.path.join(CONFIG, 'projects', HOME.replace('/', '-').replace('.', '-'))


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='milliseconds').replace('+00:00', 'Z')


def log(event, **fields):
    with open(LOG, 'a') as f:
        f.write(json.dumps({'t': round(time.time(), 3), 'ev': event, **fields}) + '\n')


def record(path, event):
    with open(path, 'a') as f:
        f.write(json.dumps({'timestamp': now(), **event}) + '\n')


def rows():
    try:
        return json.load(open(AGENTS))
    except (OSError, ValueError):
        return []


def save_rows(all_rows):
    # Chat reads it with cat at any moment: renamed into place, never half.
    tmp = AGENTS + '.tmp'
    json.dump(all_rows, open(tmp, 'w'))
    os.replace(tmp, AGENTS)


def listed(sid, drop=(), **fields):
    all_rows = rows()
    for row in all_rows:
        if row.get('sessionId') == sid:
            for key in drop:
                row.pop(key, None)
            row.update(fields)
    save_rows(all_rows)


def tool_use_id(key):
    return 'toolu_e2e_ask%d' % SESSIONS[key]['n']


def seed_transcripts():
    os.makedirs(projects(), exist_ok=True)
    for key, s in SESSIONS.items():
        path = os.path.join(projects(), sid_of(key) + '.jsonl')
        open(path, 'w').close()
        record(path, {'type': 'user', 'message': {'role': 'user', 'content': 'Ask me something'}})
        record(path, {'type': 'assistant', 'message': {
            'id': 'msg_e2e_ask%d' % s['n'], 'role': 'assistant', 'stop_reason': 'tool_use',
            'content': [{'type': 'tool_use', 'id': tool_use_id(key), 'name': 'AskUserQuestion',
                         'input': {'questions': s['questions']}}]}})


def seed_rows(pids):
    keep = [r for r in rows() if not str(r.get('sessionId', '')).startswith('e2e00000-')]
    for key, s in SESSIONS.items():
        row = {'sessionId': sid_of(key), 'pid': pids[key], 'name': 'E2E ask ' + key,
               'cwd': HOME, 'kind': s['kind'], 'status': 'busy',
               'waitingFor': s['waiting'], 'startedAt': 1790000000500 + s['n']}
        if s['kind'] == 'background':
            row.update(id='e2eask%02d' % s['n'], state='blocked')
        keep.append(row)
    save_rows(keep)


def key_of(sid):
    return next(k for k in SESSIONS if sid_of(k) == sid)


class Dialog:
    """Claude Code's question dialog, key by key."""

    def __init__(self, questions):
        self.qs = questions
        self.at = 0  # len(qs) is the review
        self.row = [0] * len(questions)
        self.ticks = [set() for _ in questions]
        self.picked = [None] * len(questions)
        self.other = [''] * len(questions)
        self.review = 0
        self.result = None  # ('answered', {question: answer}) or ('declined',)

    def answers(self):
        out = {}
        for i, q in enumerate(self.qs):
            if q['multiSelect']:
                out[q['question']] = ', '.join(
                    o['label'] for n, o in enumerate(q['options']) if n in self.ticks[i])
            else:
                out[q['question']] = self.picked[i] or ''
        return out

    def advance(self):
        self.at += 1
        if self.at == len(self.qs) and len(self.qs) == 1 and not self.qs[0]['multiSelect']:
            self.result = ('answered', self.answers())  # one choice answers at once

    def press(self, k, ch=''):
        if self.result:
            return
        if k == 'esc':
            self.result = ('declined',)
        elif self.at == len(self.qs):  # the review
            if k == 'down':
                self.review = 1
            elif k == 'up':
                self.review = 0
            elif k == 'enter':
                self.result = ('answered', self.answers()) if self.review == 0 else ('declined',)
        else:
            self.question(k, ch)

    def question(self, k, ch):
        q, i = self.qs[self.at], self.at
        n = len(q['options'])
        on_other = self.row[i] == n
        if k == 'down':
            self.row[i] = min(self.row[i] + 1, n)
        elif k == 'up':
            self.row[i] = max(self.row[i] - 1, 0)
        elif q['multiSelect']:
            # Space ticks and Enter ticks too: it toggles.
            if k in ('space', 'enter') and not on_other:
                self.ticks[i] ^= {self.row[i]}
            elif k == 'tab':
                self.at += 1
        elif on_other and k in ('char', 'space'):
            self.other[i] += ' ' if k == 'space' else ch
        elif on_other and k == 'back':
            self.other[i] = self.other[i][:-1]
        elif k == 'enter':
            if on_other and self.other[i]:
                self.picked[i] = self.other[i]
                self.advance()
            elif not on_other:
                self.picked[i] = q['options'][self.row[i]]['label']
                self.advance()

    def tabs(self):
        marks = []
        for i, q in enumerate(self.qs):
            done = bool(self.ticks[i]) if q['multiSelect'] else self.picked[i] is not None
            marks.append(('☒ ' if done else '☐ ') + q['header'])
        if len(self.qs) == 1 and not self.qs[0]['multiSelect']:
            return ' ' + marks[0]
        return '←  ' + '  '.join(marks) + '  ✔ Submit  →'

    def screen(self):
        rule = '─' * 120
        lines = ['', ' ▐▛███▛█   Claude Code v2.1.287', '', rule]
        if self.at == len(self.qs):
            lines += [self.tabs(), '', 'Review your answers', '']
            for q, (text, answer) in zip(self.qs, self.answers().items()):
                lines += [' ● ' + text, '   → ' + answer]
            lines += ['', 'Ready to submit your answers?', '',
                      ('❯ ' if self.review == 0 else '  ') + '1. Submit answers',
                      ('❯ ' if self.review == 1 else '  ') + '2. Cancel']
            return lines
        q, i = self.qs[self.at], self.at
        n = len(q['options'])
        lines += [self.tabs(), '', q['question'], '']
        for o, option in enumerate(q['options']):
            mark = '❯ ' if self.row[i] == o else '  '
            if q['multiSelect']:
                box = '[✔]' if o in self.ticks[i] else '[ ]'
                lines += [f'{mark}{o + 1}. {box} {option["label"]}', '         ' + option['description']]
            else:
                lines += [f'{mark}{o + 1}. {option["label"]}', '     ' + option['description']]
        mark = '❯ ' if self.row[i] == n else '  '
        if q['multiSelect']:
            lines += [f'{mark}{n + 1}. [ ] Type something', '     Submit']
        else:
            lines += [f'{mark}{n + 1}. {self.other[i] or "Type something."}']
        lines += [rule, f'  {n + 2}. Chat about this', '']
        footer = 'Enter to select · '
        footer += 'Tab/Arrow keys to navigate' if len(self.qs) > 1 else '↑/↓ to navigate'
        if self.row[i] == n and len(self.qs) == 1 and not q['multiSelect']:
            footer += ' · ctrl+g to edit in Vim'
        return lines + [footer + ' · Esc to cancel']


def tokens(data):
    """Keys out of the bytes a terminal sent: (name, character)."""
    out = []
    while data:
        for seq, name in (('\x1b[A', 'up'), ('\x1b[B', 'down'), ('\x1b[C', 'right'),
                          ('\x1b[D', 'left')):
            if data.startswith(seq):
                out.append((name, ''))
                data = data[len(seq):]
                break
        else:
            ch, data = data[0], data[1:]
            out.append(({'\r': 'enter', '\n': 'enter', '\t': 'tab', ' ': 'space',
                         '\x1b': 'esc', '\x7f': 'back', '\x08': 'back'}.get(ch, 'char'), ch))
    return out


def run(sid, pane):
    key = key_of(sid)
    path = os.path.join(projects(), sid + '.jsonl')
    log('attach', sid=sid, pane=pane)
    state = os.path.join(CONFIG, 'sessions', f'{os.getpid()}.json')
    if pane:
        os.makedirs(os.path.dirname(state), exist_ok=True)
        # Compact, as the CLI writes it: chat's host script greps for it.
        with open(state, 'w') as f:
            json.dump({'pid': os.getpid(), 'sessionId': sid, 'cwd': os.getcwd(),
                       'kind': 'interactive', 'status': 'busy',
                       'waitingFor': 'input needed'}, f, separators=(',', ':'))
    dialog = Dialog(SESSIONS[key]['questions'])

    def write(text):
        os.write(1, text.encode())

    def draw():
        write('\x1b[2J\x1b[H' + '\r\n'.join(dialog.screen()))

    def finish():
        result = dialog.result
        if result[0] == 'answered':
            answers = result[1]
            record(path, {'type': 'user', 'message': {'role': 'user', 'content': [{
                'type': 'tool_result', 'tool_use_id': tool_use_id(key),
                'content': 'User has answered your questions: ' + '; '.join(
                    f'"{q}"="{a}"' for q, a in answers.items())}]},
                'toolUseResult': {'questions': SESSIONS[key]['questions'],
                                  'answers': answers}})
            record(path, {'type': 'assistant', 'message': {
                'id': 'msg_e2e_ask_done%d' % SESSIONS[key]['n'], 'role': 'assistant',
                'stop_reason': 'end_turn',
                'content': [{'type': 'text', 'text': 'Continuing after your answer.'}]}})
            log('answered', sid=sid, answers=answers)
        else:
            record(path, {'type': 'user', 'message': {'role': 'user', 'content': [{
                'type': 'tool_result', 'tool_use_id': tool_use_id(key),
                'content': 'User declined to answer questions', 'is_error': True}]},
                'toolUseResult': 'Error: User declined to answer questions'})
            log('declined', sid=sid)
        listed(sid, drop=('waitingFor',), status='idle', **({} if pane else {'state': 'done'}))
        if pane:
            with open(state, 'w') as f:
                json.dump({'pid': os.getpid(), 'sessionId': sid, 'cwd': os.getcwd(),
                           'kind': 'interactive', 'status': 'idle'}, f, separators=(',', ':'))
        # As the CLI erases its dialog when it closes: chat refuses a pane
        # whose screen still says Enter to select.
        write('\x1b[2J\x1b[H❯ ')

    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    old = termios.tcgetattr(0)
    tty.setraw(0)
    decoder = codecs.getincrementaldecoder('utf-8')('replace')
    try:
        draw()
        while True:
            ready, _, _ = select.select([0], [], [], 1.0)
            if not ready:
                continue
            chunk = os.read(0, 4096)
            if not chunk:
                break
            for k, ch in tokens(decoder.decode(chunk)):
                log('key', sid=sid, k=k, c=ch)
                if dialog.result is None:
                    dialog.press(k, ch)
                    if dialog.result:
                        finish()
                    else:
                        draw()
    finally:
        try:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        except termios.error:
            pass  # The terminal went with the hang-up.
        if pane:
            try:
                os.remove(state)
            except OSError:
                pass
    return 0


def main(argv):
    mode = argv[0]
    if mode == '--seed-transcripts':
        seed_transcripts()
    elif mode == '--seed-rows':
        seed_rows(json.loads(argv[1]))
    elif mode == '--attach':
        found = next((r['sessionId'] for r in rows() if r.get('id') == argv[1]), None)
        log('attach-id', id=argv[1], found=bool(found))
        if found is None:
            print(f'No session {argv[1]}')
            return 1
        return run(found, False)
    elif mode == '--pane':
        return run(argv[1], True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
