# Promo shots

Maestro flows that drive the app for the promo video's footage, one per shot.
They are not tests: they change demo data and app tabs, so they run **only on
the emulator**, never on a phone or the tablet.

```sh
sh .maestro/promo/record.sh db-edit     # → ~/jeansh-promo/footage/raw/db-edit.mp4
sh .maestro/promo/record.sh resume
sh .maestro/promo/record.sh notify
```

`record.sh` turns "show touches" on, records with `screenrecord` at 16 Mbps
around the Maestro run, pulls the clip, and puts the setting back.

## The shots

| Flow | What it records |
|---|---|
| `db-edit.yaml` | A MongoDB cell edited in its dialog, a row added, the unsaved colours, then Save. |
| `resume.yaml` | A tmux session running, the app force-stopped and opened again, the tab restored and the panes still alive. |
| `notify.yaml` | A job ending in a `curl` to the app's own forwarded port, and the push landing on screen. |
| `setup-panes.yaml` | Not a shot. Puts the `demo` tab back into the two clean panes `resume.yaml` films. |

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

## Four things to know

- **Maestro matches a whole text, not a part of it.** `visible: "demo"` finds
  the tab, whose text is exactly that, and never the Home page's host card. A
  partial match needs a regex: `"(?s).*Terminal buddy.*"`.
- **The launcher must not be filmed.** The emulator's home screen carries the
  owner's calendar widget, so `resume.yaml`'s force-stop frames are cut out of
  the clip rather than shown.
- **`hideKeyboard` before the beat worth filming.** Typing leaves the soft
  keyboard over half the screen; both flows dismiss it before what they are
  there to record.
- **The Flutter semantics tree is sometimes empty** when Maestro reads it, so
  the Home page's host card is tapped by point (13%, 27%) rather than by text,
  even though a regex for its text should match.

## What `notify.yaml` needed from the container

`AcceptEnv LC_*` is appended to `/config/sshd/sshd_config` in `jeansh-demo`
and its sshd reloaded with `kill -HUP <pid>`; without it the shell never
receives `LC_SSHBOX_NOTIFY_URL` or `LC_SSHBOX_NOTIFY_SECRET` and
`env | grep -c LC_SSHBOX_NOTIFY` prints 0. (The container also carries `tmux`
and `git config --global core.pager cat` from the earlier shots.)

**Every session carries its own reverse forward**, which is why the flow opens
a session of its own before sending anything. A tmux session that outlived the
connection it was made on keeps the old URL, and the `curl` then fails with
`curl: (7) Failed to connect to 127.0.0.1:<port>` — the port it names is dead
while the container listens on a newer one (`netstat -ltn` inside it shows
which). Open a fresh session and the variables match a forward that is up.

The notification is filmed as the heads-up banner over the terminal, not from
the shade: the shade also shows the system's own notifications.

## Claude Code in the container

`Dockerfile` here is the image `jeansh-demo` first ran, with tmux and git added
(they had been `apk add`ed by hand), and Claude Code from its native installer.
The login user's home is `/config`, a volume that hides anything built into it,
so Claude goes under `/opt/claude` and is linked at `/usr/local/bin/claude`,
on the PATH of login and non-login shells alike. Its auto-updater is off, since
it would install a second copy into `/config` that PATH never reaches; rebuild
the image to update.

```sh
sudo docker build -t jeansh-demo:claude - < .maestro/promo/Dockerfile
sh .maestro/promo/swap-demo.sh
```

`swap-demo.sh` recreates `jeansh-demo` from that image on the same `/config`
volume, so the home, `/config/project`, `sshd_config` (`AcceptEnv LC_*`),
`.gitconfig` and the **host keys** stay — the key lives in
`/config/ssh_host_keys`, not in the image, and the emulator's pin still holds.
`jeansh-mongo` and `jeansh-redis` run in `jeansh-demo`'s network namespace,
which Docker records by container id, so any new `jeansh-demo` strands them;
the script recreates them too, on their own volumes. It keeps the old three as
`jeansh-demo-old`, `jeansh-mongo-old` and `jeansh-redis-old`. To roll back:

```sh
sudo docker rm -f jeansh-demo jeansh-mongo jeansh-redis
for c in jeansh-demo jeansh-mongo jeansh-redis; do sudo docker rename $c-old $c; done
sudo docker start jeansh-demo jeansh-mongo jeansh-redis
```

tmux sessions die with the container, so the restored `demo` tabs come back
with their sessions gone; `setup-panes.yaml` puts the panes back.

**Signing Claude in** is done once, by a person:

```sh
sudo docker exec -it -u demo -e HOME=/config -w /config/project jeansh-demo bash -lc claude
```

(`-e HOME=/config` because the image's env says `HOME=/root`, which
`docker exec` keeps; over SSH the home is right by itself, so opening the
`demo` host in Jeansh and typing `claude` works too.) Pick a theme, choose the
Claude account, open the link it prints, and paste the code back if asked.
The credentials land in `/config/.claude`, on the volume, so they survive the
next rebuild.
