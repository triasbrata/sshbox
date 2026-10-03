#!/usr/bin/env python3
"""Changed lib/ lines that no unit or widget test runs: a report, never a gate.

usage: tool/uncovered_changed_lines.py <lcov.info> <unified-diff, -U0>

Reads the lcov file `flutter test --coverage` wrote and the diff of a pull
request, and prints markdown for the job summary: per file, the added lines
that lcov counts and no test hit, which are the ones an e2e step has to
reach. A file lcov does not list at all was loaded by no test. Stdlib only.
"""
import re
import sys


def lcov(path):
    """{file: {line: hits}} for the executable lines lcov lists."""
    files, cur = {}, None
    for row in open(path):
        row = row.strip()
        if row.startswith("SF:"):
            cur = files.setdefault(row[3:], {})
        elif row.startswith("DA:") and cur is not None:
            line, hits = row[3:].split(",")[:2]
            cur[int(line)] = cur.get(int(line), 0) + int(hits)
    return files


def added(diff):
    """{file: [line, ...]} added under lib/, from a -U0 diff."""
    out, cur = {}, None
    for row in diff.splitlines():
        if row.startswith("+++ "):
            name = row[4:]
            cur = name[2:] if name.startswith("b/") else None
            if cur and not (cur.startswith("lib/") and cur.endswith(".dart")):
                cur = None
        elif row.startswith("@@") and cur:
            m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", row)
            start, count = int(m[1]), int(m[2] or 1)
            out.setdefault(cur, []).extend(range(start, start + count))
    return out


def ranges(lines):
    parts, i = [], 0
    while i < len(lines):
        j = i
        while j + 1 < len(lines) and lines[j + 1] == lines[j] + 1:
            j += 1
        parts.append(str(lines[i]) if i == j else f"{lines[i]}-{lines[j]}")
        i = j + 1
    return ", ".join(parts)


def report(cov, diff):
    rows, total, missed = [], 0, 0
    for name, lines in sorted(added(diff).items()):
        if name not in cov:
            rows.append(f"- `{name}`: no test loads this file")
            continue
        counted = [n for n in lines if n in cov[name]]
        miss = [n for n in counted if cov[name][n] == 0]
        total += len(counted)
        missed += len(miss)
        if miss:
            rows.append(f"- `{name}`: {ranges(miss)}")
    head = "### Changed `lib/` lines no test runs"
    if not rows:
        return f"{head}\n\nEvery changed line a test can count is hit, or none changed.\n"
    return (
        f"{head}\n\n{missed} of {total} counted changed lines are not hit. "
        "A report only: each is for an e2e step to reach.\n\n" + "\n".join(rows) + "\n"
    )


if __name__ == "__main__":
    print(report(lcov(sys.argv[1]), open(sys.argv[2]).read()))
