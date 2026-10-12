#!/usr/bin/env python3
"""Checks what tool/release_notes.py makes of a model's reply, offline:
python3 tool/test_release_notes.py"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_notes import (  # noqa: E402
    FEED_LINE, add_release, parse_notes, pr_changes, release_body)

good = {
    "en": {"title": " Smoother tmux ", "items": ["Panes keep their output."]},
    "id": {"title": "Tmux lebih mulus", "items": ["Panel menyimpan keluarannya."]},
}

# A plain reply, and the same inside a fence, come out trimmed.
for text in (json.dumps(good), "```json\n" + json.dumps(good) + "\n```"):
    notes = parse_notes(text)
    assert notes["en"]["title"] == "Smoother tmux", notes
    assert notes["id"]["items"] == ["Panel menyimpan keluarannya."], notes

# Each of these is refused, not published.
for bad in (
    "not json",
    json.dumps({"en": good["en"]}),  # no Indonesian
    json.dumps({**good, "id": {"title": "", "items": ["x"]}}),  # no title
    json.dumps({**good, "en": {"title": "t", "items": []}}),  # no bullets
    json.dumps({**good, "en": {"title": "t", "items": ["x"] * 7}}),  # too many
    json.dumps({**good, "en": {"title": "t", "items": [3]}}),  # not text
    json.dumps([good]),
):
    try:
        parse_notes(bad)
    except ValueError:
        continue
    raise AssertionError(f"accepted {bad!r}")

# The new release goes first, and a release written again replaces its entry.
old = [{"version": "1.0.7"}, {"version": "1.0.6"}]
assert add_release(old, {"version": "1.0.8"}) == [{"version": "1.0.8"}] + old
again = add_release(old, {"version": "1.0.7", "build": 67})
assert again == [{"version": "1.0.7", "build": 67}, {"version": "1.0.6"}], again

# A release with a feature: the feature, trimmed, with its steps.
feature_en = {"name": " Folder download ", "what": "Download a whole folder.",
              "how": ["Long-press a folder in the files drawer.", " Tap Download. "]}
feature_id = {"name": "Unduh folder", "what": "Unduh satu folder utuh.",
              "how": ["Tekan lama folder di laci file.", "Ketuk Download."]}
with_features = {
    "en": {"title": "Folders", "features": [feature_en], "items": ["A fix."]},
    "id": {"title": "Folder", "features": [feature_id], "items": []},
}
notes = parse_notes(json.dumps(with_features))
assert notes["en"]["features"] == [{
    "name": "Folder download", "what": "Download a whole folder.",
    "how": ["Long-press a folder in the files drawer.", "Tap Download."]}], notes
assert notes["id"]["items"] == [] and notes["id"]["features"][0]["how"], notes

# An entry from before features, kept as it is, with no features key added.
assert "features" not in parse_notes(json.dumps(good))["en"]


def features(en, id_=None):
    return json.dumps({"en": {"title": "t", "features": en, "items": []},
                       "id": {"title": "t", "items": [] if id_ is None else ["x"],
                              "features": en if id_ is None else id_}})


for bad in (
    features([{**feature_en, "how": []}]),  # no steps
    features([{k: v for k, v in feature_en.items() if k != "how"}]),  # no how
    features([{**feature_en, "how": ["  "]}]),  # an empty step
    features([{**feature_en, "how": ["x"] * 7}]),  # too many steps
    features([{**feature_en, "name": ""}]),  # no name
    features([{**feature_en, "what": None}]),  # no what
    features(["Folder download"]),  # not an object
    features([feature_en] * 5),  # too many features
    features([feature_en], []),  # Indonesian lost the feature
    features([]),  # neither a feature nor a bullet
):
    try:
        parse_notes(bad)
    except ValueError:
        continue
    raise AssertionError(f"accepted {bad!r}")

# The model reads each pull request, its feature marked, then loose commits.
text = pr_changes([
    {"title": "Folder download", "body": "Long-press a folder.\n", "feature": True},
    {"title": "Fix a crash", "body": None, "feature": False},
    {"title": "", "body": "dropped"},
    {"title": "Long", "body": "x" * 5000},
], "* tidy the editor\n")
assert text.startswith("## PR: Folder download\n[feature]\nLong-press a folder."), text
assert "## PR: Fix a crash\n\n## PR: Long" in text, text
assert "dropped" not in text and "x" * 4001 not in text, text
assert text.endswith("## Commits in no pull request\n* tidy the editor"), text
assert pr_changes([], "* only commits") == "## Commits in no pull request\n* only commits"

# The GitHub release: English, then Indonesian, the steps numbered, the
# feed's sentence last.
body = release_body("1.0.120", notes)
assert body.startswith("Jeansh 1.0.120\n\n## What's new: Folders\n\n### Folder download"), body
assert "1. Long-press a folder in the files drawer.\n2. Tap Download." in body, body
assert "### Other changes\n\n- A fix." in body, body
assert body.index("## What's new") < body.index("## Yang baru: Folder"), body
assert "**Cara pakai:**\n\n1. Tekan lama" in body, body
assert "Perubahan lain" not in body, body  # Indonesian has no bullets
assert body.rstrip().endswith(FEED_LINE), body
old_body = release_body("1.0.7", parse_notes(json.dumps(good)))
assert "### " not in old_body and "- Panes keep their output." in old_body, old_body

print("release_notes: ok")
