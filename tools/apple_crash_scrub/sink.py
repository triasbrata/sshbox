#!/usr/bin/env python3
"""A stand-in for Sentry's ingest, for tools/check_apple_crash_scrub.sh.

  sink.py serve PORT OUT          keeps every envelope POSTed to it, one per
                                  line of OUT, as base64 of what was sent
  sink.py check OUT raw|scrubbed  reads them back and holds each event to
                                  what apple/NativeCrashes.swift keeps
"""
import base64
import getpass
import gzip
import json
import socket
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# What NativeCrashes.scrub keeps, and so NativeCrashes.kt: anything else in a
# native event is a leak.
KEEP_EVENT = {"event_id", "timestamp", "level", "platform", "release", "dist",
              "environment", "sdk", "fingerprint", "exception", "contexts",
              "debug_meta"}
KEEP_OS = {"name", "version"}
KEEP_DEVICE = {"family", "model", "manufacturer", "brand", "archs", "arch", "simulator"}
KEEP_EXCEPTION = {"type", "value", "module", "thread_id", "mechanism", "stacktrace"}
KEEP_MECHANISM = {"type", "handled", "synthetic"}
KEEP_FRAME = {"function", "module", "filename", "package", "lineno", "colno",
              "in_app", "platform", "instruction_addr"}
KEEP_IMAGE = {"type", "uuid", "debug_id", "image_addr", "image_size", "code_file"}


def paths(value, where=""):
    """Every string in an event that is a path rather than a bare name."""
    if isinstance(value, dict):
        for k, v in value.items():
            yield from paths(v, f"{where}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from paths(v, f"{where}[{i}]")
    elif isinstance(value, str) and "/" in value:
        yield f"{where}: {value!r}"


def serve(port, out):
    class Sink(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            with open(out, "a") as f:
                f.write(base64.b64encode(body).decode() + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"id":"0"}')

        def log_message(self, *_):
            pass

    class Server(ThreadingHTTPServer):
        def server_bind(self):
            # HTTPServer's own bind asks DNS for the host's full name, which
            # on a CI Mac can take long enough that nothing listens yet.
            socketserver.TCPServer.server_bind(self)
            self.server_name, self.server_port = "127.0.0.1", port

    # Threaded: a client that opens a connection and holds it, as a URL
    # session does, must not keep the next envelope waiting behind it.
    Server(("127.0.0.1", port), Sink).serve_forever()


def wait(port, seconds=60):
    """Exit 0 once a connect to the sink succeeds, 1 if none does in time."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=2).close()
            print(f"sink listening on {port}")
            return 0
        except OSError:
            time.sleep(0.2)
    return 1


def envelopes(out):
    """Each envelope as (the bytes sent, its header, its event items)."""
    for line in open(out):
        raw = base64.b64decode(line)
        lines = raw.split(b"\n")
        header, events, i = json.loads(lines[0]), [], 1
        while i + 1 < len(lines):
            item = json.loads(lines[i])
            payload = lines[i + 1]
            if item.get("type") == "event":
                events.append((payload, json.loads(payload)))
            i += 2
        yield raw, header, events


def extra_keys(what, got, keep):
    extra = set(got) - keep
    return [f"{what}: {sorted(extra)}"] if extra else []


HANG_TAGS = {"hang.since_wake": {"<30s", "<300s", "older"},
             "hang.occluded": {"true", "false"}}


def hang_tag_leaks(event):
    """An App Hang carries two constant tags, and no event any other."""
    tags = event.get("tags")
    if tags is None:
        return []
    types = [x.get("mechanism", {}).get("type")
             for x in event.get("exception", {}).get("values", [])]
    if "AppHang" not in types:
        return [f"tags on a {types} event: {tags!r}"]
    return [f"hang tag {k}={v!r}" for k, v in tags.items()
            if v not in HANG_TAGS.get(k, set())]


def outside_allowlist(event):
    bad = extra_keys("event", event, KEEP_EVENT | {"tags"})
    bad += hang_tag_leaks(event)
    contexts = event.get("contexts", {})
    bad += extra_keys("contexts", contexts, {"os", "device"})
    bad += extra_keys("os", contexts.get("os", {}), KEEP_OS)
    bad += extra_keys("device", contexts.get("device", {}), KEEP_DEVICE)
    for e in event.get("exception", {}).get("values", []):
        bad += extra_keys("exception", e, KEEP_EXCEPTION)
        bad += extra_keys("mechanism", e.get("mechanism", {}), KEEP_MECHANISM)
        if e.get("value"):
            bad.append(f"exception value: {e['value']!r}")
        for f in e.get("stacktrace", {}).get("frames", []):
            bad += extra_keys("frame", f, KEEP_FRAME)
    meta = event.get("debug_meta", {})
    bad += extra_keys("debug_meta", meta, {"images"})
    for image in meta.get("images", []):
        bad += extra_keys("image", image, KEEP_IMAGE)
    bad += [f"a path at {p}" for p in paths(event)]
    return bad


def symbolicable(event):
    """The crash keeps what symbolication needs: addresses and images."""
    bad = []
    frames = [f for e in event.get("exception", {}).get("values", [])
              for f in e.get("stacktrace", {}).get("frames", [])]
    if not frames or not all(f.get("instruction_addr") for f in frames):
        bad.append("a frame without its instruction_addr")
    images = event.get("debug_meta", {}).get("images", [])
    if not images:
        bad.append("no debug_meta images")
    for image in images:
        for key in ("type", "image_addr", "image_size", "code_file"):
            if not image.get(key):
                bad.append(f"an image without {key}: {image}")
        if not (image.get("uuid") or image.get("debug_id")):
            bad.append(f"an image without an id: {image}")
    return bad


def check(out, mode):
    host = socket.gethostname().split(".")[0]
    # What a SentryCrash report carries about this machine and this person,
    # which none of the native envelopes may.
    leaks = ["leak", "xnu", "Darwin Kernel", "/Users/", host, getpass.getuser()]
    native, dart, failures = [], [], []
    for raw, header, events in envelopes(out):
        for payload, event in events:
            if event.get("platform") == "dart":
                dart.append(payload)
            else:
                native.append((raw, event))

    def typed(e):
        return [x.get("type") for x in e.get("exception", {}).get("values", [])]

    crash = [e for _, e in native if e.get("level") == "fatal"]
    # The NSError's domain is its type. The sleep before it, on the main
    # thread, usually brings an app hang too, held to the same list.
    error = [e for _, e in native if "check" in typed(e)]
    if len(crash) != 1 or len(error) != 1:
        failures.append(f"wanted one crash and one NSError, got {len(crash)} and {len(error)}")
    print(f"native events: {[typed(e) for _, e in native]}")
    print(f"--- the crash, as sent ({mode}) ---")
    print(json.dumps(crash[0] if crash else None, indent=2, sort_keys=True))

    if mode == "raw":
        text = json.dumps(crash[0]) if crash else ""
        for leak in ["xnu", "kernel_version", "scope-user-leak", "tag-leak", "extra-leak"]:
            if leak not in text:
                failures.append(f"raw crash lacks {leak!r}: the check would prove nothing")
    else:
        for raw, event in native:
            what = f"{event.get('level')} {event.get('event_id')}"
            failures += [f"{what}: {b}" for b in outside_allowlist(event)]
        if crash:
            failures += [f"crash: {b}" for b in symbolicable(crash[0])]
            text = raw.decode("utf-8", "replace")
            failures += [f"{what}: {leak!r} in the envelope" for leak in leaks if leak in text]
        print("--- the NSError, as sent ---")
        print(json.dumps(error[0] if error else None, indent=2, sort_keys=True))

    # Dart's envelope, byte for byte as Dart handed it over, in either mode.
    if len(dart) != 1 or b"kept as Dart sent it" not in dart[0] \
            or b"from Dart, already scrubbed" not in dart[0]:
        failures.append(f"Dart's event did not arrive as sent: {dart!r}")
    else:
        print("--- Dart's event, as sent ---")
        print(dart[0].decode())

    for f in failures:
        print("FAIL", f)
    print("ok" if not failures else f"{len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "wait":
        sys.exit(wait(int(sys.argv[2])))
    else:
        check(sys.argv[2], sys.argv[3])
