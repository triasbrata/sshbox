# Promo shots

Maestro flows that drive the app for the promo video's footage, one per shot.
They are not tests: they change demo data and app tabs, so they run **only on
the emulator**, never on a phone or the tablet.

```sh
sh .maestro/promo/record.sh db-edit     # → ~/jeansh-promo/footage/raw/db-edit.mp4
sh .maestro/promo/record.sh resume
```

`record.sh` turns "show touches" on, records with `screenrecord` at 16 Mbps
around the Maestro run, pulls the clip, and puts the setting back.

## The shots

| Flow | What it records |
|---|---|
| `db-edit.yaml` | A MongoDB cell edited in its dialog, a row added, the unsaved colours, then Save. |
| `resume.yaml` | A tmux session running, the app force-stopped and opened again, the tab restored and the panes still alive. |

`notify` is missing on purpose: see the bottom of this file.

## What the emulator needs first

- The "demo" host (demo@10.0.2.2:2222, container `jeansh-demo`) with **Use
  tmux** on and its file tree root at `/config/project`.
- Tabs open: `demo` with two tmux panes (a shell on the left, something alive
  such as `top` on the right) and `MongoDB on demo` showing `shop.customers`
  with nothing unsaved.
- Containers `jeansh-demo`, `jeansh-mongo` and `jeansh-redis` running.

`db-edit.yaml` leaves the demo data changed. Put it back with:

```sh
sudo docker cp .maestro/promo/reset-demo.js jeansh-mongo:/tmp/reset-demo.js
sudo docker exec jeansh-mongo mongosh --quiet shop /tmp/reset-demo.js
```

## Cutting the raw clip

Maestro waits a second or more between steps, so a raw recording is mostly idle
screen. `cut.py` keeps the stretches that matter, speeds some up and joins them:

```sh
python3 .maestro/promo/cut.py raw.mp4 out.mp4 19.8-20.8 26.0-33.4@4.5 56.6-58.7
```

Find the timestamps by sampling the raw clip:
`ffmpeg -i raw.mp4 -vf "fps=1,scale=400:-1,drawtext=text='%{pts\:hms}':fontcolor=yellow,tile=8x6" -frames:v 1 sheet.png`.

## Two things to know

- **Maestro matches a whole text, not a part of it.** `visible: "demo"` finds
  the tab, whose text is exactly that, and never the Home page's host card. A
  partial match needs a regex: `"(?s).*Terminal buddy.*"`.
- **The launcher must not be filmed.** The emulator's home screen carries the
  owner's calendar widget, so `resume.yaml`'s force-stop frames are cut out of
  the clip rather than shown.

## Why there is no `notify` flow

The shot wanted a push from the server landing on the phone. The demo
container's sshd has no `AcceptEnv LC_*`, so the session's shell never receives
`LC_SSHBOX_NOTIFY_URL` and `LC_SSHBOX_NOTIFY_SECRET` (`env | grep -c
LC_SSHBOX_NOTIFY` prints 0 in that shell), and there is nothing to send with.
Add `AcceptEnv LC_*` to `/config/sshd/sshd_config` in `jeansh-demo`, restart
its sshd and reconnect the host, and the shot becomes a plain `curl` to
`$LC_SSHBOX_NOTIFY_URL` followed by pressing Home.
