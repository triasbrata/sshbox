/// The host helper chat hands its messages to: `jeansh-agg.py`, a python3
/// script with only the standard library, run over the session's own SSH
/// connection. It is not a model and starts none. It delivers a message to a
/// running Claude Code session by writing one JSON line to the session's
/// messaging socket, which every session publishes as `messagingSocketPath`
/// in `<config>/sessions/<pid>.json`, so nothing is ever typed into a
/// terminal.
///
/// What it does, one JSON line on stdout for each call:
///
/// - `hello`: its version.
/// - `probe <session-id>`: whether the session can be reached and whether it
///   would hold or refuse a message from a peer (`crossSessionInbound` in
///   user, project or managed settings, or a bypass-permissions mode).
/// - `deliver`, with an id, the session id and the text as base64 (and, for
///   a stopped background session, its short id and the claude path): keeps the message in a journal on the host and
///   answers `accepted` at once; a detached child then delivers it. The same
///   `<id>` again answers what the journal says and does nothing: that is the
///   exactly-once. A stopped background session is brought back in place with
///   `claude respawn` (never `--bg --resume`, which makes a copy). A session
///   that holds or refuses peer messages is not written to at all.
/// - `status <id>`: the journal's state, and `delivered` once the session's
///   transcript records a user line whose `origin.from` is `jeansh-<id>`.
///
/// Sends to one session go one at a time, in the order accepted, each only
/// once its whole line is ready, with a gap between them. A message whose
/// line was written is never written again, whatever happens to the helper.
///
/// The script is [aggregatorScript]; chat installs it as
/// `~/.local/share/jeansh/jeansh-agg.py`, see [aggregatorInstallCommand].
library;

/// What the first line of the script says, to tell its own copy from somebody
/// else's file of the same name.
const aggregatorMarker = '# jeansh-agg: installed by Jeansh';

/// Bumped with every change to [aggregatorScript]: the app replaces an
/// installed copy that says less.
const aggregatorVersion = 2;

/// Where, under the home folder, the script is installed.
const aggregatorDir = '.local/share/jeansh';
const aggregatorFile = 'jeansh-agg.py';

const aggregatorScript = r'''#!/usr/bin/env python3
# jeansh-agg: installed by Jeansh
# Delivers a chat message to a running Claude Code session through its
# messaging socket. No model, nothing typed. See lib/src/chat/aggregator_script.dart.
import base64
import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

VERSION = 2
ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
SID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
JOB_RE = re.compile(r"^[0-9a-f]{8}$")
MAX_TEXT = 200000
KEEP_SECONDS = 7 * 86400


def num(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


# The pause after each send to a session, so a burst never overruns its inbox.
GAP = num("JEANSH_AGG_GAP", 0.6)
# How long a stopped session is given to come back and bind its socket.
WAKE = num("JEANSH_AGG_WAKE", 20)
# How long a turn for the lock may wait for the sends before it.
TURN = num("JEANSH_AGG_TURN", 120)


def out(obj, code=0):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    sys.exit(code)


def fail(why, code=1, **more):
    d = {"ok": False, "error": why}
    d.update(more)
    out(d, code)


def home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def cfg_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home(), ".claude")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(home(), ".local", "state")
    d = os.path.join(base, "jeansh", "agg")
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.lstat(d)
    if os.path.islink(d) or st.st_uid != os.getuid():
        fail("the journal folder is not ours")
    os.chmod(d, 0o700)
    return d


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, ValueError, TypeError):
        return True


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def find_session(sid):
    best = None
    for f in glob.glob(os.path.join(cfg_dir(), "sessions", "*.json")):
        d = read_json(f)
        if not isinstance(d, dict) or d.get("sessionId") != sid:
            continue
        if not alive(d.get("pid")) or not d.get("messagingSocketPath"):
            continue
        if best is None or (d.get("updatedAt") or 0) > (best.get("updatedAt") or 0):
            best = d
    return best


def find_transcript(sid):
    g = glob.glob(os.path.join(cfg_dir(), "projects", "*", sid + ".jsonl"))
    return g[0] if g else None


def tail(path, size):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            f.seek(max(0, end - size))
            data = f.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if end > size:
        lines = lines[1:]
    return [l.decode("utf-8", "replace") for l in lines if l.strip()]


def inbound_setting(cwd):
    # The strictest of what a session reads: managed, then the project's,
    # then the user's. Anything but accept holds or refuses; a value this
    # does not know is held, as Claude Code does.
    paths = [
        "/Library/Application Support/ClaudeCode/managed-settings.json",
        "/etc/claude-code/managed-settings.json",
    ]
    if cwd:
        paths += [
            os.path.join(cwd, ".claude", "settings.local.json"),
            os.path.join(cwd, ".claude", "settings.json"),
        ]
    paths.append(os.path.join(cfg_dir(), "settings.json"))
    found = None
    for p in paths:
        d = read_json(p)
        if not isinstance(d, dict) or "crossSessionInbound" not in d:
            continue
        v = d["crossSessionInbound"]
        if v == "accept":
            found = found or "accept"
            continue
        return v if v in ("hold", "refuse") else "hold"
    return found


def last_mode(sid):
    path = find_transcript(sid)
    if not path:
        return None
    for l in reversed(tail(path, 262144)):
        if '"permissionMode"' not in l:
            continue
        try:
            d = json.loads(l)
        except ValueError:
            continue
        if isinstance(d, dict) and isinstance(d.get("permissionMode"), str):
            return d["permissionMode"]
    return None


def reachable(sock):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    try:
        s.connect(sock)
        return True
    except OSError:
        return False
    finally:
        s.close()


def probe_info(sid):
    s = find_session(sid)
    info = {"live": s is not None}
    if s is None:
        return info
    info["kind"] = s.get("kind")
    info["status"] = s.get("status")
    info["version"] = s.get("version")
    info["reachable"] = reachable(s["messagingSocketPath"])
    inbound = inbound_setting(s.get("cwd"))
    mode = last_mode(sid)
    info["inbound"] = inbound
    info["mode"] = mode
    if inbound in ("hold", "refuse"):
        info["hold"] = "crossSessionInbound is %s" % inbound
    elif mode == "bypassPermissions":
        info["hold"] = "the session bypasses permission prompts"
    return info


def rec_path(d, mid):
    return os.path.join(d, mid + ".json")


def load_rec(d, mid):
    return read_json(rec_path(d, mid))


def save_rec(d, rec):
    rec["updatedAt"] = time.time()
    tmp = rec_path(d, rec["id"]) + ".tmp.%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f)
    os.rename(tmp, rec_path(d, rec["id"]))


def all_recs(d):
    recs = []
    for f in glob.glob(os.path.join(d, "*.json")):
        r = read_json(f)
        if isinstance(r, dict) and "id" in r:
            recs.append(r)
    return recs


def prune(d):
    now = time.time()
    for f in glob.glob(os.path.join(d, "*.json")):
        try:
            if now - os.path.getmtime(f) > KEEP_SECONDS:
                os.unlink(f)
        except OSError:
            pass


def delivered(rec):
    path = find_transcript(rec["session"])
    if not path:
        return False
    needle = "jeansh-" + rec["id"]
    for l in tail(path, 4 * 1024 * 1024):
        if needle not in l:
            continue
        try:
            d = json.loads(l)
        except ValueError:
            continue
        if not isinstance(d, dict):
            continue
        # A message that reached a session mid-turn is not a user line but an
        # attachment, and carries its origin inside it.
        a = d.get("attachment")
        o = d.get("origin") or (a.get("origin") if isinstance(a, dict) else None)
        if isinstance(o, dict) and o.get("from") == needle:
            return True
    return False


def view(rec, d):
    if rec["state"] in ("sent", "sending", "unknown") and delivered(rec):
        rec["state"] = "delivered"
        save_rec(d, rec)
    v = {k: rec.get(k) for k in ("id", "session", "state", "reason", "seq", "createdAt", "sentAt")}
    s = find_session(rec["session"])
    v["sessionStatus"] = s.get("status") if s else None
    v["ok"] = True
    return v


def send_line(sock, line, token):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    try:
        s.connect(sock)
        if token:
            s.sendall((json.dumps({"type": "auth", "token": token}) + "\n").encode("utf-8"))
        s.sendall(line)
    finally:
        s.close()


def peer_token(s):
    sock = s["messagingSocketPath"]
    name = "%s.%s.key" % (s["pid"], hashlib.sha256(sock.encode("utf-8")).hexdigest())
    d = read_json(os.path.join(cfg_dir(), "sessions", name))
    if isinstance(d, dict) and isinstance(d.get("peerToken"), str):
        return d["peerToken"]
    return None


def find_claude(given):
    if given and os.path.isfile(given) and os.access(given, os.X_OK):
        return given
    w = shutil.which("claude")
    if w:
        return w
    for p in (os.path.join(home(), ".local", "bin", "claude"), os.path.join(home(), ".claude", "local", "claude")):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def finish(d, rec, state, reason=None):
    rec["state"] = state
    if reason:
        rec["reason"] = reason
    save_rec(d, rec)


def run_delivery(d, rec, job, claude):
    sid = rec["session"]
    lock = open(os.path.join(d, "lock-" + sid), "a")
    waited = time.time()
    # One at a time for a session, in the order they were accepted.
    while True:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cur = load_rec(d, rec["id"]) or rec
        if cur["state"] != "accepted":
            return
        before = [r for r in all_recs(d) if r.get("session") == sid and r.get("state") == "accepted" and r.get("seq", 0) < rec["seq"]]
        if not before:
            break
        fcntl.flock(lock, fcntl.LOCK_UN)
        if time.time() - waited > TURN:
            finish(d, rec, "undeliverable", "the messages before it took too long")
            return
        time.sleep(0.2)
    try:
        s = find_session(sid)
        if s is None and job and JOB_RE.match(job):
            c = find_claude(claude)
            if c:
                try:
                    subprocess.run([c, "respawn", job], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                except (OSError, subprocess.SubprocessError):
                    pass
                end = time.time() + WAKE
                while s is None and time.time() < end:
                    time.sleep(0.25)
                    s = find_session(sid)
        if s is None:
            return finish(d, rec, "undeliverable", "the session is not running on this host")
        info = probe_info(sid)
        if info.get("hold"):
            return finish(d, rec, "refused", info["hold"])
        if not info.get("reachable"):
            return finish(d, rec, "undeliverable", "the session's messaging socket does not answer")
        # The whole line is made before the socket is touched.
        line = (json.dumps({
            "type": "user",
            "from": "jeansh-" + rec["id"],
            "uuid": rec["uuid"],
            "message": {"role": "user", "content": rec["text"]},
        }) + "\n").encode("utf-8")
        rec["state"] = "sending"
        save_rec(d, rec)
        try:
            send_line(s["messagingSocketPath"], line, peer_token(s))
        except OSError as e:
            # Written or not, it is never written again: say what is known.
            return finish(d, rec, "unknown", "the write ended with %s" % e.__class__.__name__)
        rec["sentAt"] = time.time()
        finish(d, rec, "sent")
        time.sleep(GAP)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def cmd_deliver(args):
    if len(args) < 2 or not ID_RE.match(args[0]) or not SID_RE.match(args[1]):
        fail("usage: deliver <id> <session-id> --text-b64 <b64> [--job <id>] [--claude <path>]", 2)
    mid, sid = args[0], args[1]
    opts = {}
    rest = args[2:]
    while rest:
        if rest[0] in ("--text-b64", "--job", "--claude") and len(rest) >= 2:
            opts[rest[0]] = rest[1]
            rest = rest[2:]
        else:
            fail("unknown argument", 2)
    try:
        text = base64.b64decode(opts.get("--text-b64", ""), validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        fail("the text is not base64 of UTF-8", 2)
    if not text.strip() or len(text) > MAX_TEXT:
        fail("the text is empty or too long", 2)
    d = state_dir()
    prune(d)
    # The journal's lock makes the check and the write one step.
    jl = open(os.path.join(d, "journal.lock"), "a")
    fcntl.flock(jl, fcntl.LOCK_EX)
    have = None
    if have is not None:
        fcntl.flock(jl, fcntl.LOCK_UN)
        v = view(have, d)
        v["duplicate"] = True
        out(v)
    seq = max([r.get("seq", 0) for r in all_recs(d)] + [0]) + 1
    rec = {"id": mid, "uuid": mid if re.match(r"^[0-9a-f-]{36}$", mid) else None, "session": sid,
           "text": text, "seq": seq, "state": "accepted", "createdAt": time.time()}
    if rec["uuid"] is None:
        h = hashlib.sha256(mid.encode("utf-8")).hexdigest()
        rec["uuid"] = "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:32])
    save_rec(d, rec)
    fcntl.flock(jl, fcntl.LOCK_UN)
    jl.close()
    sys.stdout.write(json.dumps({"ok": True, "id": mid, "state": "accepted", "seq": seq}, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    if os.environ.get("JEANSH_AGG_FOREGROUND") == "1":
        run_delivery(d, rec, opts.get("--job"), opts.get("--claude"))
        sys.exit(0)
    if os.fork() != 0:
        os._exit(0)
    os.setsid()
    if os.fork() != 0:
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    try:
        run_delivery(d, rec, opts.get("--job"), opts.get("--claude"))
    except BaseException as e:
        try:
            finish(d, load_rec(d, mid) or rec, "unknown", "the helper stopped with %s" % e.__class__.__name__)
        except BaseException:
            pass
    os._exit(0)


def main(argv):
    if not argv:
        fail("usage: jeansh-agg.py hello | probe <session-id> | deliver ... | status <id>", 2)
    c, args = argv[0], argv[1:]
    if c == "hello":
        out({"ok": True, "version": VERSION, "python": list(sys.version_info[:3])})
    if c == "probe":
        if len(args) != 1 or not SID_RE.match(args[0]):
            fail("usage: probe <session-id>", 2)
        d = probe_info(args[0])
        d["ok"] = True
        out(d)
    if c == "deliver":
        cmd_deliver(args)
    if c == "status":
        if len(args) != 1 or not ID_RE.match(args[0]):
            fail("usage: status <id>", 2)
        d = state_dir()
        rec = load_rec(d, args[0])
        if rec is None:
            out({"ok": True, "id": args[0], "state": "unknown-id"})
        out(view(rec, d))
    fail("unknown command", 2)


if __name__ == "__main__":
    main(sys.argv[1:])
''';

/// The shell that puts [aggregatorScript] in place for the login that runs it,
/// reading the script from its standard input: nothing is quoted into the
/// command line. It leaves a file that is not Jeansh's own, a link, or a copy
/// of the same or a newer version alone, and prints `ok`, `kept` or
/// `refused` and, with no python3, `nopython`.
const aggregatorInstallCommand =
    '''
command -v python3 >/dev/null 2>&1 || { echo nopython; exit 0; }
d="\$HOME/$aggregatorDir"
f="\$d/$aggregatorFile"
mkdir -p "\$d" && chmod 700 "\$d" || { echo refused; exit 0; }
if [ -L "\$f" ]; then echo refused; exit 0; fi
if [ -e "\$f" ]; then
  [ -f "\$f" ] && [ -O "\$f" ] || { echo refused; exit 0; }
  [ "\$(sed -n 2p "\$f")" = '$aggregatorMarker' ] || { echo refused; exit 0; }
  have=\$(sed -n 's/^VERSION = \\([0-9]*\\)\$/\\1/p' "\$f" | head -n 1)
  [ "\${have:-0}" -ge $aggregatorVersion ] && { echo kept; exit 0; }
fi
t="\$f.new.\$\$"
( umask 077; cat > "\$t" ) && chmod 700 "\$t" && mv -f "\$t" "\$f" && echo ok || { rm -f "\$t"; echo refused; }
''';

/// The shell command that runs one call of the helper with [args], each
/// quoted as one word. [args] are never taken from a message's text: the
/// text goes in as base64.
String aggregatorRunCommand(List<String> args) {
  String quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
  return 'python3 "\$HOME/$aggregatorDir/$aggregatorFile" '
      '${args.map(quote).join(' ')}';
}
