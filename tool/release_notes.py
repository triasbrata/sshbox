#!/usr/bin/env python3
"""Adds one release's notes, in English and Indonesian, to the website's list.

    tool/release_notes.py --version 1.0.7 --build 66 --changes changes.txt releases.json

release.yml runs it after a release: changes.txt holds the commit messages
since the previous tag, releases.json is site/releases.json from the R2
bucket, which jeansh.brata.cloud/releases reads, newest first. The notes are
written by a model through OpenRouter's OpenAI-compatible chat completions
API, with $OPENROUTER_API_KEY, and $RELEASE_NOTES_MODEL or MODEL.

Needs no pip package. tool/test_release_notes.py covers what it does with a
reply, without a key or a network.
"""

import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "anthropic/claude-sonnet-5"
MAX_CHANGES = 30_000  # characters of commit messages sent, of the newest first

PROMPT = """\
You write the release notes for Jeansh, an SSH client for Android, iOS and
the desktop: tabs and tmux panes, a files drawer and code editor, port
forwarding, Tailscale, a database browser, and notifications from servers.

From the commit messages below, write the notes a user of the app reads:
a short title, then 1 to 6 short bullets about what changed for them, in
English and in Indonesian (natural, friendly Indonesian, not a word-for-word
translation). Leave out work users never see (CI, releases, docs, tests,
refactoring, build numbers) unless it changes what they get. Never mention
commit hashes, file or function names, people, hosts, IP addresses, keys or
tokens.

Reply with JSON only, in this shape:
{"en": {"title": "...", "items": ["..."]}, "id": {"title": "...", "items": ["..."]}}
"""


def die(message):
    print(f"release_notes: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_notes(text):
    """The notes in a model's reply, or ValueError saying what is wrong."""
    text = text.strip()
    if text.startswith("```"):  # a fence despite being asked for JSON only
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    notes = json.loads(text)
    for lang in ("en", "id"):
        part = notes.get(lang) if isinstance(notes, dict) else None
        if not isinstance(part, dict):
            raise ValueError(f"no {lang!r} notes")
        title, items = part.get("title"), part.get("items")
        if not isinstance(title, str) or not title.strip():
            raise ValueError(f"no {lang!r} title")
        if (not isinstance(items, list) or not 1 <= len(items) <= 6
                or not all(isinstance(i, str) and i.strip() for i in items)):
            raise ValueError(f"{lang!r} needs 1 to 6 bullets")
    return {lang: {"title": notes[lang]["title"].strip(),
                   "items": [i.strip() for i in notes[lang]["items"]]}
            for lang in ("en", "id")}


def add_release(releases, entry):
    """releases with entry first, and any older entry for its version gone."""
    return [entry] + [r for r in releases if r.get("version") != entry["version"]]


def ask(key, model, changes):
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": PROMPT},
            {"role": "user", "content": changes or "(no commit messages)"},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.3,
    }).encode()
    request = urllib.request.Request(API, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://jeansh.brata.cloud",
        "X-Title": "Jeansh release notes",
    })
    try:
        with urllib.request.urlopen(request, timeout=120) as reply:
            answer = json.load(reply)
    except urllib.error.HTTPError as e:
        # OpenRouter's error body names the problem and never echoes the key.
        die(f"OpenRouter answered HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
    except (urllib.error.URLError, TimeoutError) as e:
        die(f"could not reach OpenRouter: {e}")
    try:
        return answer["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        die(f"OpenRouter sent no message back: {json.dumps(answer)[:300]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--changes", required=True)
    parser.add_argument("releases")
    args = parser.parse_args()

    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        die("OPENROUTER_API_KEY is not set")
    model = os.environ.get("RELEASE_NOTES_MODEL") or MODEL

    with open(args.changes, encoding="utf-8") as f:
        changes = f.read()[:MAX_CHANGES]
    with open(args.releases, encoding="utf-8") as f:
        releases = json.load(f)
    if not isinstance(releases, list):
        die(f"{args.releases} is not a list of releases")

    for attempt in (1, 2, 3):
        try:
            notes = parse_notes(ask(key, model, changes))
            break
        except ValueError as e:  # json.JSONDecodeError is one too
            print(f"release_notes: reply {attempt} unusable: {e}", file=sys.stderr)
    else:
        die(f"{model} gave no usable notes in 3 tries")

    entry = {
        "version": args.version,
        "build": args.build,
        "date": datetime.date.today().isoformat(),
        **notes,
    }
    with open(args.releases, "w", encoding="utf-8") as f:
        json.dump(add_release(releases, entry), f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"v{args.version}: {notes['en']['title']}")


if __name__ == "__main__":
    main()
