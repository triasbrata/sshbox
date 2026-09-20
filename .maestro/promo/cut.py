"""Cuts a raw promo recording down to its action.

Maestro waits a second or more between steps, so a raw clip is mostly idle
screen. This keeps the listed stretches, speeds some up, and joins them:

    python3 cut.py raw.mp4 out.mp4 20.0-21.2 24.6-26.2 26.2-33.4@4 ...

Each segment is START-END in seconds of the raw clip, with an optional @SPEED.
"""
import subprocess
import sys


def parse(arg):
    span, _, speed = arg.partition('@')
    start, end = (float(x) for x in span.split('-'))
    assert end > start, arg
    return start, end, float(speed or 1)


def main():
    src, out, *specs = sys.argv[1:]
    segs = [parse(s) for s in specs]
    # screenrecord writes a frame only when the screen changes, so the input is
    # made constant-rate first: trimming variable-rate video keeps the last
    # frame's whole gap and runs long.
    n = len(segs)
    head = '[0:v]fps=30,split=' + str(n) + ''.join(f'[s{i}]' for i in range(n))
    # Only a sped-up stretch needs resampling back to 30 fps; on a plain one the
    # second fps filter holds the last frame for the raw clip's bogus 1/3 rate.
    parts = [
        f'[s{i}]trim=start={s}:end={e},setpts=(PTS-STARTPTS)/{sp}'
        + (',fps=30' if sp != 1 else '') + f'[v{i}]'
        for i, (s, e, sp) in enumerate(segs)
    ]
    joined = ''.join(f'[v{i}]' for i in range(n))
    graph = ';'.join([head] + parts) + f';{joined}concat=n={n}:v=1:a=0[out]'
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', src,
        '-filter_complex', graph, '-map', '[out]',
        '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart', out,
    ], check=True)
    print(out, round(sum((e - s) / sp for s, e, sp in segs), 2), 's')


if __name__ == '__main__':
    assert parse('1-2.5@4') == (1.0, 2.5, 4.0)
    main()
