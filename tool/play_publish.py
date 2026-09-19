#!/usr/bin/env python3
"""Puts a built bundle on a Google Play testing track.

    tool/play_publish.py [--track alpha] [--dry-run] [--draft] <bundle.aab>
    tool/play_publish.py --preflight [--track alpha]

`tool/release.sh --publish` builds the bundle and then runs this; run it by
hand only to publish a bundle that is already built.

It needs no pip package: urllib speaks the Play Developer API v3 and openssl
signs the JSON Web Token the service account signs in with. Every step is one
API call -- insert an edit, upload the bundle, put it on the track, commit --
and any failure before the commit drops the edit again, so nothing half-done
is left on Play and the command can simply be run again.

Nothing it prints is a secret: not the service account's key, which only ever
goes to a file this user alone can read and only for as long as one signature
takes, and not the access token. Its output is safe to paste anywhere.

Release notes are deliberately not sent. store/RELEASE_NOTES*.md still describe
1.0 as the first release, and a testing track that quietly broadcasts stale
notes to real testers is worse than one with none; write them in the Play
Console, where they can be read before they go out.
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PACKAGE = "cloud.brata.terminal"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
V3 = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
UPLOAD = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}"
KEY_ENV = "PLAY_SERVICE_ACCOUNT_JSON"
KEY_DEFAULT = "~/keys/jeansh-play-service-account.json"
ROOT = Path(__file__).resolve().parent.parent


def die(*lines):
    for line in lines:
        print(f"play_publish: {line}", file=sys.stderr)
    raise SystemExit(1)


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def service_account():
    """The service account key, checked for shape but never printed."""
    path = Path(os.environ.get(KEY_ENV) or os.path.expanduser(KEY_DEFAULT))
    if not path.is_file():
        die(
            f"no service account key at {path}",
            f"put the JSON key there, or name its path in {KEY_ENV}.",
            "README.md, Releasing, says how to make one and what to grant it.",
        )
    try:
        key = json.loads(path.read_text())
    except OSError as e:
        die(f"{path} cannot be read: {e.strerror}")
    except ValueError:
        # The message would quote the file, so only its shape is reported.
        die(f"{path} is not JSON: download the key again from Google Cloud")
    if not isinstance(key, dict) or key.get("type") != "service_account":
        die(
            f"{path} is not a service account key",
            "it wants the JSON of a service account, not an OAuth client id.",
        )
    for field in ("client_email", "private_key"):
        if not key.get(field):
            die(f"{path} has no {field}: download the key again from Google Cloud")
    if not key["private_key"].lstrip().startswith("-----BEGIN"):
        die(f"{path}'s private_key is not a PEM key: download the key again")
    key.setdefault("token_uri", "https://oauth2.googleapis.com/token")
    return key


def sign(private_key, data):
    openssl = shutil.which("openssl")
    if not openssl:
        die(
            "no openssl, which signs the sign-in token",
            "install it: apt install openssl, or brew install openssl.",
        )
    # openssl reads a key from a file, not a pipe, so the key goes to one that
    # only this user can read (mktemp's 0600) and is deleted a signature later.
    with tempfile.NamedTemporaryFile(suffix=".pem") as pem:
        pem.write(private_key.encode())
        pem.flush()
        done = subprocess.run(
            [openssl, "dgst", "-sha256", "-sign", pem.name],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,  # it would quote the key's path and contents
        )
    if done.returncode != 0:
        die("openssl could not sign with the service account's key",
            "the key may be damaged: download it again from Google Cloud")
    return done.stdout


def call(method, url, *, body=None, headers=None, token=None, what="Play",
         timeout=60, soft=False):
    """One API call. Dies with Google's own message, which holds no secret."""
    request = urllib.request.Request(url, data=body, method=method)
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            raw = reply.read()
    except urllib.error.HTTPError as e:
        if soft:
            return None
        die(f"{what} failed: HTTP {e.code}", google_says(e))
    except (urllib.error.URLError, TimeoutError) as e:
        if soft:
            return None
        die(f"{what} could not reach Google: {e}")
    return json.loads(raw) if raw.strip() else {}


def google_says(error):
    try:
        body = json.loads(error.read())
    except Exception:
        return error.reason or "no message"
    if isinstance(body, dict):
        message = body.get("error", {})
        if isinstance(message, dict) and message.get("message"):
            return message["message"]
        if body.get("error_description"):  # the sign-in endpoint answers this way
            return f"{body.get('error')}: {body['error_description']}"
    return error.reason or "no message"


def assertion(key):
    """The signed JWT the service account signs in with (tested offline)."""
    now = int(time.time())
    parts = [
        {"alg": "RS256", "typ": "JWT"},
        {"iss": key["client_email"], "scope": SCOPE, "aud": key["token_uri"],
         "iat": now, "exp": now + 3600},
    ]
    signed = b".".join(b64(json.dumps(p, separators=(",", ":")).encode()) for p in parts)
    return f"{signed.decode()}.{b64(sign(key['private_key'], signed)).decode()}"


def access_token(key):
    reply = call(
        "POST", key["token_uri"],
        body=urllib.parse.urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion(key),
        }).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        what="signing in as the service account",
    )
    if not reply.get("access_token"):
        die("Google signed the service account in but sent no token back")
    return reply["access_token"]


def build_number():
    line = re.search(r"^version:\s*\S*?\+(\d+)\s*$", (ROOT / "pubspec.yaml").read_text(), re.M)
    if not line:
        die("pubspec.yaml has no version: X.Y.Z+N line to read the build number from")
    return int(line.group(1))


def check_track(track):
    if track == "production":
        die("this publishes to testing tracks only",
            "roll out to production from the Play Console, after a human look.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", track):
        die(f"{track!r} is not a track id",
            "closed testing is 'alpha' unless a custom track was made.")


def publish(args):
    key = service_account()
    version = build_number()
    size = os.path.getsize(args.bundle)
    token = access_token(key)

    edit = call("POST", f"{V3}/edits", token=token, what="opening a Play edit")["id"]
    committed = False
    try:
        bundles = call("GET", f"{V3}/edits/{edit}/bundles", token=token,
                       what="listing the bundles Play has")
        had = {b.get("versionCode") for b in bundles.get("bundles", [])}
        if version in had:
            die(f"Play already has build {version}, and takes each one only once",
                "commit a change to the app, which raises the build number, and",
                "build again: .githooks/pre-commit raises pubspec.yaml's +N.")

        print(f"uploading {size / 1e6:.1f} MB", flush=True)
        with open(args.bundle, "rb") as bundle:
            uploaded = call(
                "POST", f"{UPLOAD}/edits/{edit}/bundles?uploadType=media",
                body=bundle,
                headers={"Content-Type": "application/octet-stream",
                         "Content-Length": str(size)},
                token=token, what="the upload", timeout=900,
            )
        version = uploaded.get("versionCode", version)

        status = "draft" if args.draft else "completed"
        call("PUT", f"{V3}/edits/{edit}/tracks/{args.track}",
             body=json.dumps({
                 "track": args.track,
                 "releases": [{"versionCodes": [str(version)], "status": status}],
             }).encode(),
             headers={"Content-Type": "application/json"}, token=token,
             what=f"putting build {version} on the {args.track} track")

        if args.dry_run:
            print(f"dry run: build {version} would go out on {args.track} as {status};"
                  " the edit is dropped, so Play keeps none of it")
            return
        call("POST", f"{V3}/edits/{edit}:commit", token=token, what="the commit")
        committed = True
        print(f"build {version} is on the {args.track} track as {status}")
    finally:
        if not committed and call("DELETE", f"{V3}/edits/{edit}", token=token,
                                  soft=True) is None:
            print("play_publish: the Play edit could not be dropped; it expires"
                  " by itself and blocks nothing", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        prog="tool/play_publish.py",
        description="Uploads a bundle to Google Play and releases it on a testing track.",
        epilog=f"The service account key is read from ${KEY_ENV}, or from"
               f" {KEY_DEFAULT}. Release notes are not sent; write them in the"
               " Play Console.",
    )
    parser.add_argument("bundle", nargs="?", help="the .aab to upload")
    parser.add_argument("--track", default="alpha",
                        help="the track to release on (default: alpha, which is"
                             " Closed testing; a custom closed track's id is the"
                             " last part of its address in the Play Console, and"
                             " production is refused)")
    parser.add_argument("--draft", action="store_true",
                        help="leave the release as a draft instead of rolling it"
                             " out (Play takes nothing else until the app has"
                             " been published once)")
    parser.add_argument("--dry-run", action="store_true",
                        help="do everything but the commit, then drop the edit,"
                             " so no tester sees the build")
    parser.add_argument("--preflight", action="store_true",
                        help="check the track and the service account key only,"
                             " without reaching Google or needing a bundle")
    args = parser.parse_args()

    check_track(args.track)
    if args.preflight:
        service_account()
        print(f"play_publish: ready to release build {build_number()} on {args.track}")
        return
    if not args.bundle:
        parser.error("which bundle? Pass the .aab, or --preflight to check the setup")
    if not os.path.isfile(args.bundle):
        die(f"no bundle at {args.bundle}: build one with tool/release.sh")
    if not os.path.getsize(args.bundle):
        die(f"{args.bundle} is empty")
    publish(args)


if __name__ == "__main__":
    main()
