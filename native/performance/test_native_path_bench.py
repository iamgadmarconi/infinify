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

    def test_held_steps_are_unique_bounded_and_counterbalance_requested_phase(self):
        trace = bench.make_trace(60, 2, 600, kind='held-step')
        self.assertEqual(bench.encoded(trace), bench.encoded(bench.make_trace(60, 2, 600, kind='held-step')))
        self.assertEqual(trace['kind'], 'held-step')
        self.assertEqual(len(trace['frames']), 48)
        self.assertLess(trace['duration_ns'], 5_000_000_000)
        self.assertEqual(trace['duration_ns'] - trace['frames'][-1]['due_ns'], 100_000_000)
        self.assertEqual([row['phase'] for row in trace['frames']], ['pan'] * 24 + ['zoom'] * 24)
        window = {'screen_rect': [100., 200., 480., 320.]}
        self.assertEqual(len({tuple(bench.matrix(row, window)) for row in trace['frames']}), 48)
        for bucket in range(6):
            self.assertEqual(sum(row['requested_phase_bucket'] == bucket for row in trace['frames']), 8)
        for index, row in enumerate(trace['frames']):
            offset = row['due_ns'] - index * trace['nominal_hold_ns']
            expected = (row['requested_phase_bucket'] + 0.5) * (1e9 / 60) / 6
            self.assertLessEqual(abs(offset - expected), 1)
        self.assertTrue(all(a['due_ns'] < b['due_ns'] for a, b in zip(trace['frames'], trace['frames'][1:])))
        self.assertEqual(bench.make_trace(60, 2)['kind'], 'continuous')
        with self.assertRaises(ValueError):
            bench.make_trace(29, 2, 600, kind='held-step')
        with self.assertRaises(ValueError):
            bench.make_trace(60, 2, 119, kind='held-step')

    def test_held_step_latency_requires_every_pose_and_actual_phase_bucket(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'held.jsonl'
            submitted = {index: {'send_before_ns': index * 100_000_000,
                                  'requested_phase_bucket': index % 6} for index in range(24)}
            samples = [{'schema': bench.SCHEMA, 'run_id': 'r', 'trace_sha256': 'h',
                        'clock': bench.SHARED_CLOCK, 'observer_kind': 'independent_display_pixels',
                        'capture_method': 'display_capture', 'occluded': False, 'trace_index': index,
                        'presented_ns': submitted[index]['send_before_ns'] + (index % 6 + 1) * 1_000_000,
                        'capture_requested_hz': 60, 'actual_phase_bucket': index % 6} for index in range(24)]
            path.write_text(''.join(json.dumps(row) + '\n' for row in samples))
            result = bench.parse_optical(path, 'r', 'h', submitted, 60, 'held-step')
            self.assertTrue(result['latency_eligible'])
            self.assertFalse(result['cadence_eligible'])
            self.assertEqual(result['coverage'], 1)
            self.assertAlmostEqual(result['phase_balanced_mean_first_pose_ms'], 3.5)
            self.assertEqual([value['count'] for value in result['actual_phase_latency_ms'].values()], [4] * 6)
            self.assertNotIn('observed_pose_gap_intervals', result)
            path.write_text(''.join(json.dumps(row) + '\n' for row in samples[:-1]))
            result = bench.parse_optical(path, 'r', 'h', submitted, 60, 'held-step')
            self.assertGreater(result['coverage'], 0.9)
            self.assertFalse(result['latency_eligible'])
            for row in samples:
                row['actual_phase_bucket'] = 0
            path.write_text(''.join(json.dumps(row) + '\n' for row in samples))
            result = bench.parse_optical(path, 'r', 'h', submitted, 60, 'held-step')
            self.assertEqual(result['coverage'], 1)
            self.assertFalse(result['phase_balance_complete'])
            self.assertFalse(result['latency_eligible'])

    def test_capture_metrics_separate_repeated_poses_raw_gaps_and_stale_exclusions(self):
        raw = [{'type': 'observer'},
               {'type': 'pixels', 'presented_ns': 0, 'callback_ns': 1_000_000,
                'marker_bounds': [1, 1, 10, 10], 'unobscured': True, 'rejection_reason': 'none'},
               {'type': 'pixels', 'presented_ns': 16_666_667, 'callback_ns': 60_000_000,
                'marker_bounds': None, 'unobscured': False, 'rejection_reason': 'already_stale_at_callback'},
               {'type': 'pixels', 'presented_ns': 33_333_334, 'callback_ns': 65_000_000,
                'marker_bounds': [1, 1, 10, 10], 'unobscured': False, 'visibility_witness_ns': 72_000_000},
               {'type': 'pixels', 'presented_ns': 50_000_001, 'callback_ns': 70_000_000,
                'marker_bounds': [1, 1, 10, 10], 'unobscured': True, 'rejection_reason': 'none'}]
        matched = [{'trace_index': 0, 'presented_ns': 0, 'pose_age_ms': 1},
                   {'trace_index': 0, 'presented_ns': 50_000_001, 'pose_age_ms': 51}]
        result = bench.capture_observation_metrics(raw, matched, 60, 0, 60_000_000,
                                                   {'multiple_matching_poses': 2})
        self.assertEqual(result['raw_complete_frame_records'], 4)
        self.assertEqual(result['raw_callback_gap_ms']['count'], 3)
        self.assertEqual(result['raw_callback_gap_ms']['max'], 59)
        self.assertEqual(result['repeated_pose_samples'], 1)
        self.assertEqual(result['distinct_admissible_poses'], 1)
        self.assertEqual(result['captured_pose_age_ms']['max'], 51)
        self.assertEqual(result['rejection_reasons'], {'already_stale_at_callback': 1, 'stale_visibility_witness': 1})
        self.assertEqual(result['decoder_exclusions']['multiple_matching_poses'], 2)

    def test_held_decoder_uses_first_capture_and_keeps_repeats_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            window = {'wid': 42, 'screen_rect': [100., 200., 480., 320.],
                      'bounds': [100., 200., 480., 320.]}
            fixture_path = directory / 'fixture.json'
            bench.write_json(fixture_path, {'pid': 123, 'windows': [window]})
            trace = bench.make_trace(60, 2, 600, kind='held-step')
            base, frames = 1_000_000_000, []
            raw = [{'schema': bench.SCHEMA, 'type': 'observer', 'clock': bench.SHARED_CLOCK,
                    'fixture_manifest_sha256': bench.digest(fixture_path), 'wid': 42, 'pid': 123,
                    'capture_method': 'display_capture', 'filtered_fixture_only': True,
                    'point_scale_x': 1, 'point_scale_y': 1, 'requested_hz': 60},
                   {'type': 'pixels', 'presented_ns': base - 100_000_000,
                    'callback_ns': base - 99_000_000, 'marker_bounds': None}]
            for row in trace['frames']:
                pose = bench.matrix(row, window)
                frame = {'trace_index': row['index'], 'send_before_ns': base + row['due_ns'],
                         'observed_window_matrix': pose, 'requested_phase_bucket': row['requested_phase_bucket']}
                frames.append(frame)
                a, _, _, d, tx, ty = pose
                rect = [-tx / a, -ty / d, 480 / a, 320 / d]
                # Write the later repeated pose first to verify timestamp-based
                # first-capture selection, independently of JSONL arrival order.
                for delay in (40_000_000, 20_000_000):
                    at = frame['send_before_ns'] + delay
                    raw.append({'type': 'pixels', 'presented_ns': at, 'callback_ns': at + 1_000_000,
                                'marker_bounds': rect, 'unobscured': True,
                                'visibility_witness_ns': at + 2_000_000, 'rejection_reason': 'none'})
            report = {'schema': bench.SCHEMA, 'clock': bench.SHARED_CLOCK, 'run_id': 'held',
                      'trace_sha256': 'trace', 'fixture_manifest_sha256': bench.digest(fixture_path),
                      'hz': 60, 'trace_kind': 'held-step', 'start_shared_ns': base,
                      'trace_duration_ns': trace['duration_ns'], 'status': 'measured_control_path',
                      'restoration': {'independently_verified': True}}
            bench.write_json(directory / 'run.json', report)
            (directory / 'frames.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in frames))
            raw_path = directory / 'raw.jsonl'
            raw_path.write_text(''.join(json.dumps(row) + '\n' for row in raw))
            bench.decode_pixels(argparse.Namespace(run_dir=str(directory), fixture_manifest=str(fixture_path),
                                                   raw_pixels=str(raw_path), output=str(directory / 'decoded.jsonl')))
            result = json.loads((directory / 'run.json').read_text())
            self.assertEqual(result['optical']['coverage'], 1)
            self.assertEqual(result['optical']['held_step_latency_ms']['count'], 48)
            self.assertAlmostEqual(result['optical']['held_step_latency_ms']['max'], 20)
            self.assertTrue(result['latency_comparison_eligible'])
            self.assertFalse(result['winner_eligible'])
            self.assertFalse(result['optical']['cadence_eligible'])
            capture = result['optical']['capture_observation']
            self.assertEqual(capture['repeated_pose_samples'], 48)
            self.assertEqual(capture['admissible_pose_samples'], 96)
            self.assertAlmostEqual(capture['captured_pose_age_ms']['max'], 40)
            # A first observation after the frozen final hold cannot complete
            # latency coverage while lying outside the sensor diagnostic window.
            late_raw = [row for row in raw if row.get('marker_bounds') != rect]
            late_at = base + trace['duration_ns'] + 1_000_000
            late_raw.append({'type': 'pixels', 'presented_ns': late_at, 'callback_ns': late_at + 1_000_000,
                             'marker_bounds': rect, 'unobscured': True,
                             'visibility_witness_ns': late_at + 2_000_000, 'rejection_reason': 'none'})
            raw_path.write_text(''.join(json.dumps(row) + '\n' for row in late_raw))
            bench.decode_pixels(argparse.Namespace(run_dir=str(directory), fixture_manifest=str(fixture_path),
                                                   raw_pixels=str(raw_path), output=str(directory / 'decoded.jsonl')))
            result = json.loads((directory / 'run.json').read_text())
            self.assertEqual(result['optical']['observed_poses'], len(trace['frames']) - 1)
            self.assertFalse(result['latency_comparison_eligible'])
            self.assertEqual(result['optical']['capture_observation']['decoder_exclusions']['outside_held_observation_window'], 1)

    def test_continuous_ninety_percent_gate_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'continuous.jsonl'
            submitted = {index: {'send_before_ns': index * 1_000_000} for index in range(10)}
            rows = [{'schema': bench.SCHEMA, 'run_id': 'r', 'trace_sha256': 'h', 'clock': bench.SHARED_CLOCK,
                     'observer_kind': 'independent_display_pixels', 'capture_method': 'display_capture',
                     'occluded': False, 'trace_index': index, 'presented_ns': index * 1_000_000 + 100_000,
                     'capture_requested_hz': 60} for index in range(9)]
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            result = bench.parse_optical(path, 'r', 'h', submitted, 60)
            self.assertEqual(result['coverage'], 0.9)
            self.assertTrue(result['cadence_eligible'])
            self.assertIn('observed_pose_gap_intervals', result)

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

    def test_conditional_cadence_excludes_missing_or_rejected_capture_intervals(self):
        period = 1_000_000_000 / 60
        times = {i: 1_000_000_000 + round(i * period) for i in (0, 1, 2, 4, 5, 6)}
        raw = [{'type': 'pixels', 'presented_ns': t, 'callback_ns': t + 1_000_000}
               for t in times.values()]
        poses = [{'presented_ns': times[i], 'trace_index': pose, 'pose_age_ms': 1}
                 for i, pose in ((0, 0), (1, 0), (2, 1), (4, 3), (6, 4))]
        result = bench.capture_observation_metrics(raw, poses, 60, times[0], times[6], {})
        self.assertEqual(result['one_refresh_transitions'], 2)
        self.assertEqual(result['repeated_in_one_refresh_transitions'], 1)
        self.assertEqual(result['fresh_pose_fraction_in_one_refresh_transitions'], 0.5)
        self.assertEqual(result['one_refresh_transition_fraction'], 0.4)

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
