#!/usr/bin/env python3
"""Splits tools/e2e_android.sh's units across the shards e2e.yml runs at once.

    e2e_shards.py --shard I/N UNIT...   the units shard I of N runs, in order
    e2e_shards.py --plan N UNIT...      every shard, its units and its seconds

The units come in the order the script runs them, and each shard keeps that
order: a unit that must come last (text_size, which leaves the UI at 160%)
stays last in whichever shard has it.

Which shard a unit goes to is worked out from measured seconds, kept in
e2e/android_durations.tsv (a unit, a tab, its seconds), by the longest first,
each to the shard with the least so far. The same table always gives the same
shards. A unit the table does not know counts as DEFAULT seconds and is
named on stderr, so a new block is still run, and the table can be brought up
to date from the durations each shard uploads.
"""
import argparse
import os
import sys

DEFAULT = 120
TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'e2e',
                     'android_durations.tsv')


def read_table(path):
    """{unit: seconds} from a TSV; blank lines and # comments are skipped."""
    table = {}
    with open(path, encoding='utf-8') as f:
        for n, line in enumerate(f, start=1):
            line = line.split('#', 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise ValueError(f'{path}:{n}: want "unit seconds", got {line!r}')
            table[parts[0]] = int(parts[1])
    return table


def assign(units, table, shards):
    """A list of `shards` lists of units, each in the order `units` gave."""
    if shards < 1:
        raise ValueError('shards must be at least 1')
    if len(set(units)) != len(units):
        raise ValueError('a unit is named twice')
    cost = {u: table.get(u, DEFAULT) for u in units}
    load = [0] * shards
    where = {}
    # Longest first; a tie goes by name, so the result never depends on order.
    for u in sorted(units, key=lambda u: (-cost[u], u)):
        i = min(range(shards), key=lambda i: (load[i], i))
        where[u] = i
        load[i] += cost[u]
    return [[u for u in units if where[u] == i] for i in range(shards)]


def parse_shard(text):
    """'2/4' -> (1, 4): a zero-based index and the count."""
    try:
        i, n = (int(x) for x in text.split('/'))
    except ValueError:
        raise ValueError(f'--shard wants I/N, got {text!r}')
    if not 1 <= i <= n:
        raise ValueError(f'--shard {text}: I must be 1 to N')
    return i - 1, n


def main(argv=None, out=sys.stdout, err=sys.stderr):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument('--shard')
    g.add_argument('--plan', type=int)
    p.add_argument('--table', default=TABLE)
    p.add_argument('units', nargs='+')
    a = p.parse_args(argv)
    table = read_table(a.table)
    for u in a.units:
        if u not in table:
            print(f'e2e_shards: no duration for {u}; counting {DEFAULT} s', file=err)
    if a.shard:
        i, n = parse_shard(a.shard)
        for u in assign(a.units, table, n)[i]:
            print(u, file=out)
        return 0
    for i, mine in enumerate(assign(a.units, table, a.plan), start=1):
        total = sum(table.get(u, DEFAULT) for u in mine)
        print(f'shard {i}/{a.plan}: {total} s, {len(mine)} units: {" ".join(mine)}',
              file=out)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except ValueError as e:
        print(f'e2e_shards: {e}', file=sys.stderr)
        sys.exit(2)
