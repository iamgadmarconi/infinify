#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure benchmark-contract tests. Run these only in the authorized guest."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
import ctypes as C

SPEC = importlib.util.spec_from_file_location('bench', Path(__file__).with_name('native_path_bench.py'))
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class Contracts(unittest.TestCase):
    def test_frozen_trace_is_deterministic_and_has_unique_poses(self):
        a = bench.make_trace(120, 2, 240)
        self.assertEqual(bench.encoded(a), bench.encoded(bench.make_trace(120, 2, 240)))
        self.assertEqual(len(a['frames']), 480)
        self.assertEqual([r['index'] for r in a['frames']], list(range(480)))
        window = {'screen_rect': [100., 200., 480., 320.]}
        poses = [tuple(bench.matrix(row, window)) for row in a['frames']]
        self.assertEqual(len(set(poses)), 480)
        self.assertTrue(all(a['frames'][i]['due_ns'] < a['frames'][i + 1]['due_ns'] for i in range(479)))

    def test_wire_sizes_and_nearest_rank_distribution(self):
        self.assertEqual((bench.HEADER.size, bench.IDENTITY.size, bench.RECORD.size), (16, 24, 80))
        self.assertEqual(bench.distribution([4, 1, 3, 2]), {'count': 4, 'p50': 2, 'p95': 4, 'p99': 4, 'max': 4})
        self.assertIsNone(bench.distribution([])['p99'])

    def test_observable_trace_span_is_bounded_at_six_hundred_points(self):
        trace = bench.make_trace(60, 2, 600)
        self.assertEqual(max(row['pan_x'] for row in trace['frames']), 600)
        self.assertEqual(max(row['pan_y'] for row in trace['frames']), 75)
        with self.assertRaises(ValueError):
            bench.make_trace(60, 2, 601)

    def test_pixel_proof_rejects_producer_and_clock_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'samples.jsonl'
            submitted = {0: {'send_before_ns': 10}}
            row = {'schema': bench.SCHEMA, 'run_id': 'r', 'trace_sha256': 'h', 'clock': bench.SHARED_CLOCK,
                   'observer_kind': 'independent_display_pixels', 'capture_method': 'producer_drawable',
                   'occluded': False, 'trace_index': 0, 'presented_ns': 20, 'capture_requested_hz': 120}
            path.write_text(json.dumps(row) + '\n')
            with self.assertRaises(ValueError):
                bench.parse_optical(path, 'r', 'h', submitted, 120)
            row['capture_method'] = 'display_capture'; row['clock'] = 'wall_clock'
            path.write_text(json.dumps(row) + '\n')
            with self.assertRaises(ValueError):
                bench.parse_optical(path, 'r', 'h', submitted, 120)

    def test_sparse_pixel_samples_are_not_cadence_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'samples.jsonl'
            submitted = {i: {'send_before_ns': i + 10} for i in range(10)}
            path.write_text(json.dumps({'schema': bench.SCHEMA, 'run_id': 'r', 'trace_sha256': 'h', 'clock': bench.SHARED_CLOCK,
                                       'observer_kind': 'independent_display_pixels', 'capture_method': 'display_capture',
                                       'occluded': False, 'trace_index': 0, 'presented_ns': 20,
                                       'capture_requested_hz': 120}) + '\n')
            result = bench.parse_optical(path, 'r', 'h', submitted, 120)
            self.assertEqual(result['coverage'], 0.1)
            self.assertFalse(result['cadence_eligible'])
            self.assertIn('observed_pose_gap_intervals', result)
            self.assertNotIn('missed_refresh_intervals', result)

    def test_comparison_refuses_acknowledgement_only_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            reports = []
            for name in ('scalar', 'optimized'):
                path = directory / (name + '.json')
                bench.write_json(path, {'schema': bench.SCHEMA, 'clock': bench.SHARED_CLOCK,
                                        'variant': name, 'trace_sha256': 'same', 'fixture_geometry': [],
                                        'host_sha256': 'same', 'environment': {}, 'system': {}, 'hz': 120,
                                        'winner_eligible': False,
                                        'acknowledgement_round_trip_ms': {'p99': 1 if name == 'optimized' else 10}})
                reports.append(str(path))
            output = directory / 'comparison.json'
            self.assertEqual(bench.compare(argparse.Namespace(reports=reports, output=str(output))), 0)
            result = json.loads(output.read_text())
            self.assertIsNone(result['winner'])
            self.assertTrue(result['matched_inputs'])

    def test_bad_probe_lengths_are_rejected(self):
        with self.assertRaises(ValueError):
            bench.verify_probe(bytes(71))
        body = bench.struct.pack('<4Ii3I4Q2I', 1, 0, 0, 2000, 123, 0, 0, 0, 0, 0, 0, 0, 1, 0)
        with self.assertRaises(ValueError):
            bench.verify_probe(body)

    @unittest.skipUnless(sys.platform == 'darwin', 'shared Mach clock contract requires authorized macOS guest')
    def test_parent_child_share_the_observer_mach_clock(self):
        # A process-relative Python3.9 monotonic clock cannot satisfy this bound.
        before = bench.shared_ns()
        child = json.loads(subprocess.check_output(
            [sys.executable, str(Path(__file__).with_name('native_path_bench.py')), 'clock'], text=True))
        after = bench.shared_ns()
        self.assertEqual(child['clock'], 'mach_absolute_time_ns')
        self.assertEqual(child['schema'], 2)
        self.assertLessEqual(before, child['now_ns'])
        self.assertLessEqual(child['now_ns'], after)
        # Independent spelling of the observer's exact native clock conversion.
        class Timebase(C.Structure):
            _fields_ = [('numer', C.c_uint32), ('denom', C.c_uint32)]
        system = C.CDLL(None)
        absolute = system.mach_absolute_time
        absolute.argtypes = []
        absolute.restype = C.c_uint64
        info = Timebase()
        system.mach_timebase_info.argtypes = [C.POINTER(Timebase)]
        self.assertEqual(system.mach_timebase_info(C.byref(info)), 0)
        lower = absolute() * info.numer // info.denom
        shared = bench.shared_ns()
        upper = absolute() * info.numer // info.denom
        self.assertLessEqual(lower, shared)
        self.assertLessEqual(shared, upper)

    def test_legacy_clock_cannot_select_a_visible_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            reports = []
            for name in ('a', 'b'):
                path = directory / (name + '.json')
                bench.write_json(path, {'schema': 1, 'clock': 'python.monotonic_ns',
                                        'variant': name, 'winner_eligible': True})
                reports.append(str(path))
            with self.assertRaisesRegex(ValueError, 'visible latency invalid'):
                bench.compare(argparse.Namespace(reports=reports, output=str(directory / 'out.json')))


if __name__ == '__main__':
    unittest.main()
