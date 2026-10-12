#!/usr/bin/env python3
"""Adds one release's notes, in English and Indonesian, to the website's list.

    tool/release_notes.py --version 1.0.7 --build 66 --changes changes.txt \
        [--prs prs.jsonl] [--body body.md] releases.json

release.yml runs it after a release: changes.txt holds the commit messages
since the previous tag that came in no pull request, prs.jsonl the pull
requests merged since then, a JSON object a line with title, body and
feature (whether a commit in it carries `Release: feature`), releases.json is
site/releases.json from the R2 bucket, which jeansh.brata.cloud/releases
reads, newest first, and body.md, when asked for, is written with the same
notes for the tag's GitHub release. The notes are
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
MAX_CHANGES = 30_000  # characters of pull requests and commits sent
MAX_PR_BODY = 4_000  # characters of one pull request's description
FEED_LINE = ("The builds are served from Jeansh's own host; this release "
             "carries only latest.json, which the app reads to find them.")

PROMPT = """\
You write the release notes for Jeansh, an SSH client for Android, iOS and
the desktop: tabs and tmux panes, a files drawer and code editor, port
forwarding, Tailscale, a database browser, chat with Claude Code, and
notifications from servers.

Below are the pull requests merged in this release, each a "## PR:" title, a
[feature] mark when it brings a new feature, and its description, and then
any commit messages that came in no pull request. Write the notes a user of
the app reads, in English and in Indonesian (natural, friendly Indonesian,
not a word-for-word translation):

- a short title;
- "features": one entry for each pull request marked [feature], at most 4,
  each with its "name", one sentence of "what" it does for the user, and
  "how": 1 to 6 short steps saying how to use it, naming where in the app it
  is (screen, menu, tab), the button or its tooltip, the shortcut, or the
  shell command to type. Take the steps only from what the description says;
  never invent a button, a menu or a shortcut. Both languages list the same
  features in the same order;
- "items": up to 6 short bullets about the other changes users notice, fixes
  above all.

Leave out work users never see (CI, releases, docs, tests, refactoring, build
numbers) unless it changes what they get. Never mention commit hashes, issue
or pull request numbers, file or function names, people, hosts, IP
addresses, paths on anyone's machine, keys, tokens or tickets.

Reply with JSON only, in this shape:
{"en": {"title": "...",
        "features": [{"name": "...", "what": "...", "how": ["...", "..."]}],
        "items": ["..."]},
 "id": {"title": "...", "features": [...], "items": ["..."]}}
"""


def die(message):
    print(f"release_notes: {message}", file=sys.stderr)
    raise SystemExit(1)


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _feature(lang, feature):
    """One feature, trimmed, or ValueError saying what is wrong."""
    if not isinstance(feature, dict):
        raise ValueError(f"a {lang!r} feature is not an object")
    for field in ("name", "what"):
        if not _text(feature.get(field)):
            raise ValueError(f"a {lang!r} feature has no {field}")
    how = feature.get("how")
    if (not isinstance(how, list) or not 1 <= len(how) <= 6
            or not all(_text(step) for step in how)):
        raise ValueError(f"{lang!r} feature {feature['name'].strip()!r} "
                         "needs 1 to 6 steps saying how to use it")
    return {"name": feature["name"].strip(), "what": feature["what"].strip(),
            "how": [step.strip() for step in how]}


def parse_notes(text):
    """The notes in a model's reply, or ValueError saying what is wrong."""
    text = text.strip()
    if text.startswith("```"):  # a fence despite being asked for JSON only
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    notes = json.loads(text)
    result = {}
    for lang in ("en", "id"):
        part = notes.get(lang) if isinstance(notes, dict) else None
        if not isinstance(part, dict):
            raise ValueError(f"no {lang!r} notes")
        title = part.get("title")
        items = part.get("items", [])
        features = part.get("features", [])
        if not _text(title):
            raise ValueError(f"no {lang!r} title")
        if (not isinstance(items, list) or len(items) > 6
                or not all(_text(i) for i in items)):
            raise ValueError(f"{lang!r} takes at most 6 bullets, each text")
        if not isinstance(features, list) or len(features) > 4:
            raise ValueError(f"{lang!r} takes at most 4 features")
        if not items and not features:
            raise ValueError(f"{lang!r} has neither a feature nor a bullet")
        result[lang] = {"title": title.strip(),
                        "items": [i.strip() for i in items]}
        if features:
            result[lang]["features"] = [_feature(lang, f) for f in features]
    if (len(result["en"].get("features", []))
            != len(result["id"].get("features", []))):
        raise ValueError("'en' and 'id' list a different number of features")
    return result


def pr_changes(prs, commits=""):
    """What the model reads: each pull request, then the loose commits."""
    blocks = []
    for pr in prs:
        title = (pr.get("title") or "").strip()
        if not title:
            continue
        body = (pr.get("body") or "").strip()[:MAX_PR_BODY]
        mark = "[feature]\n" if pr.get("feature") else ""
        blocks.append(f"## PR: {title}\n{mark}{body}".rstrip())
    if commits.strip():
        blocks.append("## Commits in no pull request\n" + commits.strip())
    return "\n\n".join(blocks)[:MAX_CHANGES]


def release_body(name, notes):
    """The tag's GitHub release text: English, then Indonesian, then where
    the builds are."""
    out = [f"Jeansh {name}"]
    for lang, heading, how, changes in (
            ("en", "What's new", "How to use it", "Other changes"),
            ("id", "Yang baru", "Cara pakai", "Perubahan lain")):
        part = notes[lang]
        out.append(f"## {heading}: {part['title']}")
        for feature in part.get("features", []):
            steps = "\n".join(f"{n}. {step}"
                              for n, step in enumerate(feature["how"], 1))
            out.append(f"### {feature['name']}\n\n{feature['what']}\n\n"
                       f"**{how}:**\n\n{steps}")
        if part["items"]:
            label = f"### {changes}\n\n" if part.get("features") else ""
            out.append(label + "\n".join(f"- {i}" for i in part["items"]))
    out.append(FEED_LINE)
    return "\n\n".join(out) + "\n"


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
    parser.add_argument("--prs")
    parser.add_argument("--body")
    parser.add_argument("releases")
    args = parser.parse_args()

    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        die("OPENROUTER_API_KEY is not set")
    model = os.environ.get("RELEASE_NOTES_MODEL") or MODEL

    with open(args.changes, encoding="utf-8") as f:
        changes = f.read()
    prs = []
    if args.prs:
        with open(args.prs, encoding="utf-8") as f:
            prs = [json.loads(line) for line in f if line.strip()]
    changes = pr_changes(prs, changes)
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
    if args.body:
        with open(args.body, "w", encoding="utf-8") as f:
            f.write(release_body(args.version, notes))
    print(f"v{args.version}: {notes['en']['title']}")


if __name__ == "__main__":
    main()
