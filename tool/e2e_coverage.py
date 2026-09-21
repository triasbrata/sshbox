#!/usr/bin/env python3
"""Every feature the user has passed must say what guards it.

CLAUDE.md's Features table is the list of what this app promises. A row that
reads "UAT passed" is a promise the user has checked themselves, and the point
of this script is that no such promise can quietly lose its guard: each one
must appear in e2e/coverage.yaml saying what would catch it breaking.

    python3 tool/e2e_coverage.py            # report, exit 1 if anything is unguarded
    python3 tool/e2e_coverage.py --summary  # counts only
    python3 tool/e2e_coverage.py --orphans  # entries whose feature is gone from CLAUDE.md

It deliberately does NOT demand an e2e flow for everything. Some features are
better guarded by the widget tests that already exist, and some cannot be
automated on a runner at all -- a push notification arriving on a real phone,
an app icon, a website. What it demands is that somebody decided, wrote down
which, and said why. "todo" is a legal answer; it just shows up in the report.

Run from the repository root.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE_MD = ROOT / 'CLAUDE.md'
COVERAGE = ROOT / 'e2e' / 'coverage.yaml'

# What a coverage entry's `guard` may say.
GUARDS = {
    'e2e-android',   # a .maestro/ flow drives the real app on a device
    'e2e-desktop',   # an integration_test/ test drives the real desktop app
    'unit',          # widget or unit tests under test/ reach it; e2e would add nothing
    'manual',        # cannot be automated here -- `why` must say what makes it so
    'todo',          # nobody has decided yet; counted and reported, never silently
}


def slug(text: str) -> str:
    """A short stable key for a feature: the first eight words of its cell.

    Not the first clause alone -- six rows open with "Database browser:" and
    three with "Files drawer:", so a clause-only key would merge features that
    are nothing like each other and quietly guard one with another's flow.
    Reading past the colon separates them.

    CLAUDE.md's cells are long and get edited. When an edit reaches these first
    words the entry stops matching and the report says so rather than passing
    quietly -- the alarm working, not a bug.
    """
    words = re.sub(r'[^a-z0-9]+', ' ', text.lower()).split()
    return '-'.join(words[:8])


def features() -> list[tuple[str, str, str]]:
    """(slug, headline, uat) for every row of CLAUDE.md's Features table."""
    rows = []
    for line in CLAUDE_MD.read_text().splitlines():
        if not line.startswith('| '):
            continue
        cells = line.split('|')
        if len(cells) != 6:
            continue
        feature, _session, _commits, uat = (c.strip() for c in cells[1:5])
        if feature.startswith('Feature') or set(feature) <= set('- '):
            continue
        rows.append((slug(feature), feature, uat))
    return rows


def helper_only_tests() -> set[str]:
    """Test files that never build a widget.

    A file with no `testWidgets(` exercises logic and nothing else. That is
    often the right test -- but it cannot see a feature's wiring, and a
    `guard: unit` resting on one alone is the trap ctrl_click_test.dart fell
    into: six green tests on findLinks(), a string helper, while Ctrl+tap was
    dead on the tablet because nothing tested the key bar, the underlining,
    the tap or the opening.
    """
    pure = set()
    for path in sorted((ROOT / 'test').glob('*_test.dart')):
        if 'testWidgets(' not in path.read_text():
            pure.add('test/' + path.name)
    return pure


def audit(entries: dict[str, dict]) -> list[tuple[str, str]]:
    """`unit` guards whose NAMED tests never build the UI.

    Read the result as a question, not a verdict. It can only see the files an
    entry names in `by:`, and in this codebase a feature's widget tests usually
    live in the test file of the page that hosts it -- terminal_page_test,
    chat_page_test, file_editor_page_test, connect_sheet_test,
    home_databases_test -- not in a file named after the feature.

    This has already been got wrong once, four times over: Ctrl+tap, Import
    URI and two host-key prompts were all flagged here and moved to todo on the
    strength of their eponymous test files alone, and every one had widget
    tests all along in the page's file. Search the whole of test/,
    case-insensitively, for the feature's own strings before calling anything
    untested.

    An entry that says `ui: none` is exempt, for a feature that really is only
    logic -- parsing os-release, picking a port, walking a jump chain. That has
    to be claimed on purpose, so the alarm keeps meaning something.
    """
    pure = helper_only_tests()
    flagged = []
    for key, entry in entries.items():
        if entry.get('guard') != 'unit' or entry.get('ui') == 'none':
            continue
        named = [b.strip() for b in entry.get('by', '').split(',') if b.strip()]
        if named and all(b in pure for b in named):
            flagged.append((key, ', '.join(named)))
    return flagged


def coverage() -> dict[str, dict]:
    """e2e/coverage.yaml, read without a yaml dependency.

    The file is a flat map of slug -> {guard, by, why}, two-space indented, so
    a hand-rolled reader is smaller than taking a package for it.
    """
    if not COVERAGE.exists():
        return {}
    entries: dict[str, dict] = {}
    current: str | None = None
    for raw in COVERAGE.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        if not raw.startswith(' '):
            current = raw.split(':', 1)[0].strip()
            entries[current] = {}
        elif current:
            key, _, value = raw.strip().partition(':')
            entries[current][key.strip()] = value.strip().strip('"')
    return entries


def main() -> int:
    passed = [(s, f) for s, f, uat in features() if uat.lower().startswith('uat passed')]
    have = coverage()

    # Two features sharing a key would let one entry guard both, and the second
    # would look covered while nothing watched it. Refuse rather than guess.
    seen: dict[str, str] = {}
    clashes = []
    for key, headline in passed:
        if key in seen:
            clashes.append((key, seen[key], headline))
        seen[key] = headline
    if clashes:
        print('Two features share one key -- give one of them distinct opening words:')
        for key, first, second in clashes:
            print('  %s\n    %s\n    %s' % (key, first[:70], second[:70]))
        return 1

    unguarded, todo, bad, guarded = [], [], [], []
    for key, headline in passed:
        entry = have.get(key)
        if entry is None:
            unguarded.append((key, headline))
        elif entry.get('guard') not in GUARDS:
            bad.append((key, entry.get('guard')))
        elif entry['guard'] == 'todo':
            todo.append((key, headline))
        else:
            guarded.append((key, entry))

    if '--orphans' in sys.argv:
        live = {k for k, _ in passed}
        for key in sorted(set(have) - live):
            print('orphan (no passed feature in CLAUDE.md): %s' % key)
        return 0

    counts: dict[str, int] = {}
    for _key, entry in guarded:
        counts[entry['guard']] = counts.get(entry['guard'], 0) + 1

    print('UAT passed features: %d' % len(passed))
    for name in sorted(counts):
        print('  %-12s %d' % (name, counts[name]))
    print('  %-12s %d' % ('todo', len(todo)))
    print('  %-12s %d' % ('UNGUARDED', len(unguarded)))

    thin = audit(have)
    if thin:
        print('  %-12s %d  (unit, but no test builds the UI)' % ('THIN', len(thin)))

    if '--summary' in sys.argv:
        return 1 if unguarded or bad else 0

    if thin:
        print(
            '\nThin guards -- the tests NAMED here never build a widget. That '
            'is a question,\nnot a verdict: first grep the whole of test/ '
            'case-insensitively for the\nfeature\'s own strings, because its '
            'widget tests usually live in the test\nfile of the page that '
            'hosts it. Found some? Add them to `by:`. Found none?\nThen move '
            'it to todo, or say `ui: none` if it really is only logic:'
        )
        for key, by in thin:
            print('  %-50s %s' % (key[:50], by))

    for key, guard in bad:
        print('\nbad guard %r for %s -- allowed: %s' % (guard, key, ', '.join(sorted(GUARDS))))
    if todo:
        print('\nDecided but not built yet (todo):')
        for key, headline in todo:
            print('  %-50s %s' % (key, headline[:70]))
    if unguarded:
        print('\nNOT IN e2e/coverage.yaml -- a passed feature with nothing said about it:')
        for key, headline in unguarded:
            print('  %-50s %s' % (key, headline[:70]))
        print('\nAdd each to e2e/coverage.yaml with a guard of: %s' % ', '.join(sorted(GUARDS)))

    return 1 if unguarded or bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
