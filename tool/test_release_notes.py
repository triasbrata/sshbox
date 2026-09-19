#!/usr/bin/env python3
"""Checks what tool/release_notes.py makes of a model's reply, offline:
python3 tool/test_release_notes.py"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_notes import add_release, parse_notes  # noqa: E402

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

print("release_notes: ok")
