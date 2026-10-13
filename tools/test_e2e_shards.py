#!/usr/bin/env python3
"""Tests for tools/e2e_shards.py: python3 tools/test_e2e_shards.py"""
import io
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_shards as s  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def table_file(text):
    f = tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False)
    f.write(text)
    f.close()
    return f.name


class ReadTable(unittest.TestCase):
    def test_reads_units_and_skips_comments(self):
        path = table_file('# unit\tseconds\n\na\t10\nb 20  # note\n')
        self.assertEqual(s.read_table(path), {'a': 10, 'b': 20})

    def test_refuses_a_bad_line(self):
        path = table_file('a 10 extra\n')
        with self.assertRaisesRegex(ValueError, ':1: want'):
            s.read_table(path)

    def test_the_repos_table_reads(self):
        self.assertTrue(s.read_table(s.TABLE))


class Assign(unittest.TestCase):
    units = ['smoke', 'a', 'b', 'c', 'd', 'last']
    table = {'smoke': 10, 'a': 100, 'b': 90, 'c': 50, 'd': 40, 'last': 30}

    def test_union_is_every_unit_once(self):
        for n in range(1, 8):
            got = s.assign(self.units, self.table, n)
            self.assertEqual(len(got), n)
            flat = [u for shard in got for u in shard]
            self.assertEqual(sorted(flat), sorted(self.units))

    def test_each_shard_keeps_the_run_order(self):
        for shard in s.assign(self.units, self.table, 3):
            self.assertEqual(shard, [u for u in self.units if u in shard])

    def test_longest_first_to_the_least_loaded(self):
        # a 100 -> 0, b 90 -> 1, c 50 -> 1 (90), d 40 -> 0 (100),
        # last 30 -> 1 (140 vs 140, lower index 0? 0 has 140, 1 has 140) -> 0,
        # smoke 10 -> 1.
        got = s.assign(self.units, self.table, 2)
        self.assertEqual(got, [['a', 'd', 'last'], ['smoke', 'b', 'c']])

    def test_one_shard_is_everything_in_order(self):
        self.assertEqual(s.assign(self.units, self.table, 1), [self.units])

    def test_unknown_unit_counts_the_default(self):
        got = s.assign(['x', 'y'], {'y': s.DEFAULT + 1}, 2)
        self.assertEqual(got, [['y'], ['x']])

    def test_more_shards_than_units_leaves_some_empty(self):
        self.assertEqual(s.assign(['a'], {}, 3), [['a'], [], []])

    def test_refuses_zero_shards_and_twice_named_units(self):
        with self.assertRaises(ValueError):
            s.assign(['a'], {}, 0)
        with self.assertRaises(ValueError):
            s.assign(['a', 'a'], {}, 1)


class ParseShard(unittest.TestCase):
    def test_reads_one_based(self):
        self.assertEqual(s.parse_shard('2/4'), (1, 4))

    def test_refuses_nonsense(self):
        for bad in ('x', '0/4', '5/4', '1', '1/2/3'):
            with self.assertRaises(ValueError):
                s.parse_shard(bad)


class Main(unittest.TestCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        path = table_file('a 100\nb 90\nc 50\n')
        code = s.main(['--table', path, *argv], out, err)
        return code, out.getvalue(), err.getvalue()

    def test_shard_prints_its_units(self):
        self.assertEqual(self.run_main('--shard', '2/2', 'a', 'b', 'c'),
                         (0, 'b\nc\n', ''))

    def test_plan_prints_every_shard(self):
        code, out, _ = self.run_main('--plan', '2', 'a', 'b', 'c')
        self.assertEqual(out, 'shard 1/2: 100 s, 1 units: a\n'
                              'shard 2/2: 140 s, 2 units: b c\n')

    def test_names_a_unit_with_no_duration(self):
        _, out, err = self.run_main('--shard', '1/1', 'a', 'new')
        self.assertEqual(out, 'a\nnew\n')
        self.assertIn('no duration for new', err)

    def test_command_line_refuses_a_bad_shard(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, 'e2e_shards.py'),
                            '--shard', '9/4', 'a'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn('I must be 1 to N', r.stderr)


if __name__ == '__main__':
    unittest.main()
