#!/usr/bin/env python3
"""A stand-in for a full-screen program that reads the mouse, for the e2e
flows that check a tmux tab keeps the program's terminal modes (#261).

    e2e_mouse_tui.py mouse LOG   alternate screen, mouse tracking 1000/1002 and
                                 SGR 1006, as Claude Code turns them on
    e2e_mouse_tui.py plain LOG   the normal screen with a long scrollback, and
                                 no mouse mode

Every chunk the program is typed is appended to LOG as its repr, so a runner
can read, from the host, what reached the program: terminal text is painted,
not something a UI flow can read. A 'r' typed at it empties the log, so a
runner can start a phase clean.
"""
import os
import sys
import termios
import tty

mode, log = sys.argv[1], sys.argv[2]
out = sys.stdout


def say(text):
    out.write(text)
    out.flush()


if mode == 'mouse':
    say('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[2J\x1b[Hmouse stand-in up')
else:
    for n in range(1, 121):
        say('plain-line-%03d\r\n' % n)

open(log, 'a').close()
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        if data == b'r':
            open(log, 'w').close()
            continue
        with open(log, 'a') as f:
            f.write(repr(data) + '\n')
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
