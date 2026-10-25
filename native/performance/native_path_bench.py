#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Matched, fixture-only native transform benchmark. No permission changes/injection.

Acknowledgements and independent native geometry are deliberately separate from
displayed pixels. An external display-pixel observer is required to pick a winner.
"""
import argparse
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import secrets
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time

HEADER = struct.Struct('<IHHQ')
IDENTITY = struct.Struct('<iIQQ')
RECORD = struct.Struct('<iIQQ6dfI')
HELLO, FRAME, HEARTBEAT, RESTORE, PROBE, ENROLLMENT = 1, 2, 3, 4, 5, 6
REPLY = 0x8000
MAX_BODY = 131072
FIXTURE_KIND = 'infinify-disposable-cooperative-host'
SCHEMA = 2
SHARED_CLOCK = 'mach_absolute_time_ns'
_mach_clock = None


def shared_ns():
    """Cross-process macOS uptime, identical to SCK's mach-absolute clock.

    Python before 3.10 may offset monotonic_ns() separately in each process.
    Those values cannot be subtracted from another process's display timestamp.
    Keep all evidence timestamps on the explicit native clock; ordinary
    time.monotonic() remains suitable for a process-local timeout duration.
    """
    global _mach_clock
    if _mach_clock is None:
        if sys.platform != 'darwin':
            raise RuntimeError('shared benchmark clock requires macOS mach_absolute_time')
        class Timebase(C.Structure):
            _fields_ = [('numer', C.c_uint32), ('denom', C.c_uint32)]
        system = C.CDLL(None)
        absolute = system.mach_absolute_time
        absolute.argtypes = []
        absolute.restype = C.c_uint64
        info_fn = system.mach_timebase_info
        info_fn.argtypes = [C.POINTER(Timebase)]
        info_fn.restype = C.c_int
        info = Timebase()
        if info_fn(C.byref(info)) or not info.numer or not info.denom:
            raise RuntimeError('cannot resolve shared Mach timebase')
        _mach_clock = absolute, info.numer, info.denom
    absolute, numer, denom = _mach_clock
    return absolute() * numer // denom


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def distribution(values):
    values = sorted(values)
    if not values:
        return {'count': 0, 'p50': None, 'p95': None, 'p99': None, 'max': None}
    return {'count': len(values), **{f'p{q}': values[max(0, math.ceil(len(values) * q / 100) - 1)]
                                    for q in (50, 95, 99)}, 'max': values[-1]}


def make_trace(hz, seconds, pan_points=120, kind='continuous'):
    if not 1 <= hz <= 240 or not 1 <= seconds <= 30 or not 0 <= pan_points <= 600:
        raise ValueError('trace requires hz 1..240, seconds per phase 1..30, pan 0..600')
    if kind not in ('continuous', 'held-step'):
        raise ValueError('trace kind must be continuous or held-step')
    if kind == 'held-step':
        if hz < 30 or pan_points < 120:
            raise ValueError('held-step requires hz 30..240 and pan span 120..600 for distinct observable poses')
        frames, buckets, steps = [], 6, 48
        period_ns = 1_000_000_000 / hz
        spacing_ns = math.ceil(hz / 10) * period_ns
        for index in range(steps):
            phase, local = ('pan', index) if index < steps // 2 else ('zoom', index - steps // 2)
            t = local / (steps // 2 - 1)
            bucket = index % buckets
            frames.append({'index': index, 'phase': phase,
                           'due_ns': round(index * spacing_ns + (bucket + 0.5) * period_ns / buckets),
                           'requested_phase_bucket': bucket,
                           'zoom': 0.75 if phase == 'pan' else 0.6 + 0.3 * t,
                           'pan_x': pan_points * t, 'pan_y': pan_points * 0.125 * t})
        return {'schema': SCHEMA, 'kind': kind, 'hz': hz, 'clock': SHARED_CLOCK,
                'steps': steps, 'phase_bucket_count': buckets,
                'phase_bucket_basis': 'requested offsets relative to trace origin; actual captured-clock phase is reported separately',
                'nominal_hold_ns': round(spacing_ns),
                'duration_ns': frames[-1]['due_ns'] + round(spacing_ns), 'frames': frames}
    frames = []
    count = round(hz * seconds)
    for phase in ('pan', 'zoom'):
        for i in range(count):
            t = i / max(1, count - 1)
            # Unique poses, bounded motion, identical arithmetic for every backend.
            zoom = 0.75 if phase == 'pan' else 0.6 + 0.3 * t
            frames.append({'index': len(frames), 'phase': phase,
                           'due_ns': round(len(frames) * 1_000_000_000 / hz),
                           'zoom': zoom, 'pan_x': pan_points * t,
                           'pan_y': pan_points * 0.125 * t})
    return {'schema': SCHEMA, 'kind': kind, 'hz': hz, 'seconds_per_phase': seconds,
            'duration_ns': round(len(frames) * 1_000_000_000 / hz),
            'clock': SHARED_CLOCK, 'frames': frames}


def matrix(frame, window):
    scale = 1 / frame['zoom']
    x, y = window['screen_rect'][:2]
    return [scale, 0., 0., scale, -(x + frame['pan_x']) * scale,
            -(y + frame['pan_y']) * scale]


def close_matrix(actual, wanted):
    # WindowServer stores float components; this is geometry, never pixel proof.
    return all(abs(a - b) <= max(0.001, abs(b) * 2e-6) for a, b in zip(actual, wanted))


def private_file(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError(f'expected current-user regular 0600 file: {path}')
    return path


class NativeReadback:
    """Read-only independent connection; no native setters are resolved."""
    class Affine(C.Structure):
        _fields_ = [(n, C.c_double) for n in ('a', 'b', 'c', 'd', 'tx', 'ty')]

    class Rect(C.Structure):
        _fields_ = [(n, C.c_double) for n in ('x', 'y', 'w', 'h')]

    class Process(C.Structure):
        _fields_ = [(n, C.c_uint32) for n in ('flags', 'status', 'xstatus', 'pid', 'ppid',
                                            'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
        _fields_ += [('comm', C.c_char * 16), ('name', C.c_char * 32)]
        _fields_ += [(n, C.c_uint32) for n in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
        _fields_ += [('nice', C.c_int32), ('birth_sec', C.c_uint64), ('birth_usec', C.c_uint64)]

    def __init__(self):
        if sys.platform != 'darwin':
            raise RuntimeError('live native queries require macOS')
        self.sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
        self.proc = C.CDLL('/usr/lib/libproc.dylib')
        self.sky.SLSMainConnectionID.restype = C.c_int
        self.cid = self.sky.SLSMainConnectionID()
        for name, output in [('SLSGetWindowTransform', self.Affine), ('SLSGetWindowBounds', self.Rect),
                             ('SLSGetScreenRectForWindow', self.Rect), ('SLSGetWindowOwner', C.c_int),
                             ('SLSGetWindowAlpha', C.c_float)]:
            fn = getattr(self.sky, name)
            fn.argtypes = [C.c_int, C.c_uint32, C.POINTER(output)]
            fn.restype = C.c_int
        self.sky.SLSConnectionGetPID.argtypes = [C.c_int, C.POINTER(C.c_int)]
        self.sky.SLSConnectionGetPID.restype = C.c_int
        self.proc.proc_pidinfo.argtypes = [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int]
        self.proc.proc_pidinfo.restype = C.c_int
        self.proc.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
        self.proc.proc_pidpath.restype = C.c_int

    def process(self, pid):
        info = self.Process()
        if self.proc.proc_pidinfo(pid, 3, 0, C.byref(info), C.sizeof(info)) != C.sizeof(info):
            raise RuntimeError(f'cannot resolve exact fixture process {pid}')
        path = C.create_string_buffer(4096)
        if self.proc.proc_pidpath(pid, path, len(path)) <= 0:
            raise RuntimeError('cannot resolve fixture executable')
        return {'pid': info.pid, 'birth_sec': info.birth_sec, 'birth_usec': info.birth_usec,
                'uid': info.uid, 'host_path': os.fsdecode(path.value)}

    def query(self, name, wid, output):
        value = output()
        if getattr(self.sky, name)(self.cid, wid, C.byref(value)):
            raise RuntimeError(f'{name} failed for fixture window {wid}')
        return value

    def transform(self, wid):
        t = self.query('SLSGetWindowTransform', wid, self.Affine)
        return [getattr(t, n) for n, _ in t._fields_]

    def window(self, wid):
        owner = self.query('SLSGetWindowOwner', wid, C.c_int).value
        pid = C.c_int()
        if self.sky.SLSConnectionGetPID(owner, C.byref(pid)):
            raise RuntimeError('cannot resolve fixture window owner PID')
        result = {'wid': wid, 'owner': owner, 'pid': pid.value, 'transform': self.transform(wid),
                  'alpha': self.query('SLSGetWindowAlpha', wid, C.c_float).value}
        for key, name in [('bounds', 'SLSGetWindowBounds'), ('screen_rect', 'SLSGetScreenRectForWindow')]:
            r = self.query(name, wid, self.Rect)
            result[key] = [r.x, r.y, r.w, r.h]
        return result

    def verify_fixture(self, fixture):
        if fixture.get('schema') != 1 or fixture.get('fixture_kind') != FIXTURE_KIND:
            raise ValueError('only a benchmark-supervised disposable fixture is admitted')
        process = self.process(fixture['pid'])
        for key in ('pid', 'birth_sec', 'birth_usec', 'uid', 'host_path'):
            if process[key] != fixture[key]:
                raise ValueError(f'fixture process identity changed: {key}')
        if fixture['uid'] != os.getuid() or digest(fixture['host_path']) != fixture['host_sha256']:
            raise ValueError('fixture executable/user changed')
        windows = fixture['windows']
        if not 1 <= len(windows) <= 16 or len({w['wid'] for w in windows}) != len(windows):
            raise ValueError('expected 1..16 distinct disposable fixture windows')
        for w in windows:
            now = self.window(w['wid'])
            if now['pid'] != fixture['pid'] or now['owner'] != w['owner']:
                raise ValueError('fixture window identity changed')
            if now['bounds'] != w['bounds']:
                raise ValueError('fixture native bounds changed between matched runs')

    def restored(self, fixture):
        self.verify_fixture(fixture)
        return all(self.transform(w['wid']) == w['transform']
                   and self.window(w['wid'])['alpha'] == w['alpha'] for w in fixture['windows'])


class Connection:
    def __init__(self, runtime, nonce, server_pid, server_uid, role=1, token=bytes(16)):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(5)
        self.s.connect(str(Path(runtime) / 'v2.sock'))
        self.seq = 0
        libc = C.CDLL(None, use_errno=True)
        uid, gid = C.c_uint32(), C.c_uint32()
        if libc.getpeereid(self.s.fileno(), C.byref(uid), C.byref(gid)) or uid.value != server_uid:
            self.s.close()
            raise ValueError('helper Unix peer UID differs from explicit server identity')
        # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=2.
        peer = struct.unpack('i', self.s.getsockopt(0, 2, 4))[0]
        if peer != server_pid:
            self.s.close()
            raise ValueError('helper Unix peer PID differs from explicit server identity')
        self.send(HELLO, struct.pack('<4sHH64s16s', b'DWv2', 2, role, nonce.encode(), token))
        kind, _, body = self.recv()
        if kind != HELLO or len(body) != 48:
            raise ValueError('invalid helper HELLO reply')
        status, self.lease_ms, self.max_records, _, self.caps, self.scope, _, reported_pid, self.token = struct.unpack('<7Ii16s', body)
        if status or reported_pid != server_pid or not 100 <= self.lease_ms <= 60000:
            raise ValueError('helper refused or misidentified HELLO')

    def send(self, kind, body=b''):
        self.seq += 1
        self.s.sendall(HEADER.pack(len(body), kind, 0, self.seq) + body)
        return self.seq

    def read(self, count):
        result = bytearray()
        while len(result) < count:
            part = self.s.recv(count - len(result))
            if not part:
                raise EOFError('helper connection ended')
            result.extend(part)
        return bytes(result)

    def recv(self):
        size, kind, flags, seq = HEADER.unpack(self.read(16))
        if size > MAX_BODY or not kind & REPLY or flags:
            raise ValueError('invalid helper reply header')
        return kind & ~REPLY, seq, self.read(size)

    def request(self, kind, body=b''):
        seq = self.send(kind, body)
        actual_kind, actual_seq, result = self.recv()
        if (actual_kind, actual_seq) != (kind, seq):
            raise ValueError('helper request/reply mismatch')
        return result

    def close(self):
        self.s.close()

    def shutdown(self):
        try:
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


class MailboxConnection(Connection):
    """Existing DWv2 messages through the VM's bounded native file adapter."""
    def __init__(self, library, runtime, nonce, server_pid, server_uid, role=1, token=bytes(16)):
        self.lib = C.CDLL(str(library))
        self.lib.ifwsp_mb_open.argtypes = [C.c_char_p, C.c_char_p, C.c_int, C.c_uint32,
                                         C.c_uint16, C.c_void_p, C.c_void_p, C.POINTER(C.c_void_p)]
        self.lib.ifwsp_mb_open.restype = C.c_int
        self.lib.ifwsp_mb_send.argtypes = [C.c_void_p, C.c_uint16, C.c_uint64, C.c_void_p, C.c_uint32]
        self.lib.ifwsp_mb_send.restype = C.c_int
        self.lib.ifwsp_mb_recv.argtypes = [C.c_void_p, C.POINTER(C.c_uint16), C.POINTER(C.c_uint64),
                                         C.c_void_p, C.c_uint32, C.POINTER(C.c_uint32), C.c_uint32]
        self.lib.ifwsp_mb_recv.restype = C.c_int
        for name in ('ifwsp_mb_shutdown', 'ifwsp_mb_close'):
            getattr(self.lib, name).argtypes = [C.c_void_p]
            getattr(self.lib, name).restype = None
        self._condition = threading.Condition()
        self._active, self._stopping = 0, False
        self._handle = C.c_void_p()
        hello, key = C.create_string_buffer(48), C.create_string_buffer(token, 16)
        error = self.lib.ifwsp_mb_open(os.fsencode(runtime), nonce.encode(), server_pid, server_uid,
                                      role, key, hello, C.byref(self._handle))
        if error:
            raise OSError(error, 'bounded mailbox HELLO failed')
        status, self.lease_ms, self.max_records, _, self.caps, self.scope, _, reported_pid, self.token = struct.unpack('<7Ii16s', hello.raw)
        self.seq = 1
        if status or reported_pid != server_pid or not 100 <= self.lease_ms <= 60000:
            self.close()
            raise ValueError('mailbox refused or misidentified HELLO')

    def _call(self, name, *arguments):
        with self._condition:
            if self._stopping or not self._handle:
                raise EOFError('mailbox lane is closed')
            self._active += 1
            handle = self._handle
        try:
            error = getattr(self.lib, name)(handle, *arguments)
            if error:
                raise OSError(error, 'bounded mailbox IO failed')
        finally:
            with self._condition:
                self._active -= 1
                self._condition.notify_all()

    def send(self, kind, body=b''):
        self.seq += 1
        data = C.create_string_buffer(body)
        self._call('ifwsp_mb_send', kind, self.seq, data, len(body))
        return self.seq

    def recv(self):
        kind, seq, length = C.c_uint16(), C.c_uint64(), C.c_uint32()
        data = C.create_string_buffer(2048)
        self._call('ifwsp_mb_recv', C.byref(kind), C.byref(seq), data, len(data), C.byref(length), 5000)
        return kind.value, seq.value, data.raw[:length.value]

    def shutdown(self):
        with self._condition:
            if self._handle and not self._stopping:
                self._stopping = True
                self.lib.ifwsp_mb_shutdown(self._handle)

    def close(self):
        self.shutdown()
        deadline = time.monotonic() + 6
        with self._condition:
            while self._active and time.monotonic() < deadline:
                self._condition.wait(max(0, deadline - time.monotonic()))
            if self._active:
                # A blocked native call still owns the mappings. Retain them
                # until process exit rather than invalidate borrowed storage.
                return
            if self._handle:
                self.lib.ifwsp_mb_close(self._handle)
                self._handle = C.c_void_p()


def verify_probe(body):
    if len(body) < 72:
        raise ValueError('short helper probe')
    values = struct.unpack('<4Ii3I4Q2I', body[:72])
    result = dict(zip(('scope', 'caps', 'queue', 'lease_ms', 'server_pid', 'held', 'restoring',
                       'journal_pending', 'frames_received', 'frames_applied', 'frames_superseded',
                       'journal_writes', 'table_count', 'fixture_count'), values))
    expected = 72 + result['table_count'] * 112 + result['fixture_count'] * 24
    if expected != len(body):
        raise ValueError('helper probe record count mismatch')
    return result


def parse_optical(path, run_id, trace_hash, submitted, hz, trace_kind='continuous'):
    """External output-pixel evidence only; producer timestamps are never accepted."""
    if not path:
        return {'available': False, 'reason': 'no independent display-pixel observer supplied'}
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    seen = set()
    samples, requested_buckets, actual_buckets = [], {}, {}
    for row in rows:
        if (row.get('schema') != SCHEMA or row.get('run_id') != run_id or row.get('trace_sha256') != trace_hash
                or row.get('clock') != SHARED_CLOCK
                or row.get('observer_kind') != 'independent_display_pixels'
                or row.get('capture_method') not in ('display_capture', 'external_camera')
                or row.get('occluded') is not False):
            raise ValueError('optical evidence identity/clock/method/occlusion is not admissible')
        index = row['trace_index']
        if index not in submitted or index in seen:
            raise ValueError('optical sample has unknown/duplicate trace index')
        presented = row['presented_ns']
        if type(presented) is not int or presented < submitted[index]['send_before_ns']:
            raise ValueError('optical timestamp predates its input')
        latency_ms = (presented - submitted[index]['send_before_ns']) / 1e6
        samples.append((presented, latency_ms))
        for key, buckets in (('requested_phase_bucket', requested_buckets), ('actual_phase_bucket', actual_buckets)):
            bucket = row.get(key, submitted[index].get(key))
            if type(bucket) is int and 0 <= bucket < 6:
                buckets.setdefault(bucket, []).append(latency_ms)
        seen.add(index)
    samples.sort()
    if not samples:
        raise ValueError('empty optical observation file')
    gaps = [(b[0] - a[0]) / 1e6 for a, b in zip(samples, samples[1:])]
    period = 1000 / hz
    observer_hz = min(row.get('capture_requested_hz', 0) for row in rows)
    coverage = len(samples) / len(submitted)
    result = {'available': True, 'source_sha256': digest(path), 'observed_poses': len(samples),
            'coverage': coverage, 'cadence_eligible': coverage >= 0.9 and observer_hz >= hz,
            'input_to_visible_ms': distribution([s[1] for s in samples]),
            'observed_pose_gap_ms': distribution(gaps),
            'observed_pose_gap_intervals': sum(max(0, round(g / period) - 1) for g in gaps),
            'pose_gap_note': 'unobserved intervals between decoded poses; includes capture/decoder omissions, not physical missed refreshes',
            'observer': rows[0].get('observer', 'unspecified'),
            'limits': 'external observer must decode actual displayed transformed poses; no self-observed counters'}
    if trace_kind == 'held-step':
        complete = len(samples) == len(submitted)
        phase_complete = all(actual_buckets.get(bucket) for bucket in range(6))
        result.update(cadence_eligible=False, latency_eligible=complete and phase_complete and observer_hz >= hz,
                      held_step_latency_ms=distribution([sample[1] for sample in samples]),
                      requested_phase_latency_ms={str(bucket): distribution(requested_buckets.get(bucket, [])) for bucket in range(6)},
                      actual_phase_latency_ms={str(bucket): distribution(actual_buckets.get(bucket, [])) for bucket in range(6)},
                      phase_balance_complete=phase_complete,
                      phase_balanced_mean_first_pose_ms=(sum(sum(actual_buckets[b]) / len(actual_buckets[b])
                                                           for b in range(6)) / 6 if phase_complete else None),
                      latency_note='first captured pose per held step; all steps and all six actual phase buckets required; no continuous smoothness claim')
        result.pop('observed_pose_gap_ms')
        result.pop('observed_pose_gap_intervals')
        result['pose_gap_note'] = 'held steps intentionally retain one pose; no continuous-cadence interpretation'
    return result


def capture_observation_metrics(raw, admissible, hz, start_ns, end_ns, exclusions):
    """Describe the saved sensor stream separately from first-pose coverage."""
    pixels = [row for row in raw if row.get('type') == 'pixels'
              and start_ns <= row.get('presented_ns', -1) <= end_ns]
    displayed = sorted(row['presented_ns'] for row in pixels)
    callbacks = sorted(row['callback_ns'] for row in pixels if type(row.get('callback_ns')) is int)
    matched = [row for row in admissible if start_ns <= row['presented_ns'] <= end_ns]
    distinct = len({row['trace_index'] for row in matched})
    by_time = {row['presented_ns']: row for row in matched}
    period_ns = 1e9 / hz
    consecutive, repeated_consecutive = 0, 0
    for before, after in zip(displayed, displayed[1:]):
        if (before in by_time and after in by_time
                and abs(after - before - period_ns) <= period_ns * 0.1):
            consecutive += 1
            repeated_consecutive += by_time[before]['trace_index'] == by_time[after]['trace_index']
    reasons = {}
    for row in pixels:
        reason = row.get('rejection_reason')
        if not reason or reason == 'none':
            if row.get('marker_bounds') and row.get('unobscured') is not True:
                witness = row.get('visibility_witness_ns')
                reason = ('stale_visibility_witness' if type(witness) is int
                          and witness - row['presented_ns'] > 2e9 / hz else 'visibility_refused')
            elif not row.get('marker_bounds'):
                reason = 'no_marker'
        if reason and reason != 'none':
            reasons[reason] = reasons.get(reason, 0) + 1
    return {'window_start_ns': start_ns, 'window_end_ns': end_ns,
            'raw_complete_frame_records': len(pixels),
            'raw_callback_gap_ms': distribution([(b - a) / 1e6 for a, b in zip(callbacks, callbacks[1:])]),
            'raw_display_time_gap_ms': distribution([(b - a) / 1e6 for a, b in zip(displayed, displayed[1:])]),
            'rejection_reasons': reasons, 'decoder_exclusions': exclusions,
            'admissible_pose_samples': len(matched), 'distinct_admissible_poses': distinct,
            'repeated_pose_samples': len(matched) - distinct,
            'one_refresh_transitions': consecutive,
            'repeated_in_one_refresh_transitions': repeated_consecutive,
            'fresh_pose_fraction_in_one_refresh_transitions': (1 - repeated_consecutive / consecutive) if consecutive else None,
            'one_refresh_transition_fraction': consecutive / (len(displayed) - 1) if len(displayed) > 1 else 0,
            'conditional_cadence_limit': 'only adjacent admissible captures one requested refresh apart; missing/rejected captures excluded; not total output FPS',
            'captured_pose_age_ms': distribution([row['pose_age_ms'] for row in matched]),
            'limits': 'complete-frame callback records only; gaps include capture/scheduling omissions; repeated poses are expected during held steps; no physical-refresh claim'}


def run(args):
    native = NativeReadback()
    fixture = json.loads(Path(args.fixture_manifest).read_text())
    native.verify_fixture(fixture)
    if not native.restored(fixture):
        raise ValueError('fixture is not at the saved original transform/alpha before run')
    trace = json.loads(Path(args.trace).read_text())
    if (trace.get('schema') != SCHEMA or trace.get('clock') != SHARED_CLOCK
            or not trace.get('frames') or not 1 <= trace['hz'] <= 240):
        raise ValueError('invalid/legacy frozen trace; regenerate with shared Mach clock schema 2')
    if trace.get('kind') == 'held-step':
        duration = trace.get('duration_ns')
        if (len(trace['frames']) not in (24, 48) or type(duration) is not int or not 0 < duration <= 6_000_000_000
                or duration <= trace['frames'][-1]['due_ns']):
            raise ValueError('held-step trace must contain 24 or 48 poses and finish within six seconds')
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    nonce = private_file(args.nonce_file).read_text().strip()
    if len(nonce) != 64 or any(c not in '0123456789abcdef' for c in nonce):
        raise ValueError('invalid private nonce file')
    run_id, trace_hash = secrets.token_hex(16), digest(args.trace)
    environment = json.loads(Path(args.environment).read_text()) if args.environment else {}
    report = {'schema': SCHEMA, 'run_id': run_id, 'variant': args.variant, 'trace_sha256': trace_hash,
              'fixture_manifest_sha256': digest(args.fixture_manifest), 'fixture_geometry': [w['bounds'] for w in fixture['windows']],
              'host_sha256': fixture['host_sha256'], 'environment': environment,
              'system': {'platform': platform.platform(), 'machine': platform.machine()},
              'clock': SHARED_CLOCK, 'hz': trace['hz'], 'sample_hz': args.sample_hz,
              'trace_kind': trace.get('kind', 'continuous'),
              'trace_duration_ns': trace.get('duration_ns'),
              'source_hashes': {},
              'limits': ['acknowledgement latency is not visible latency',
                         'native geometry is not optical presentation',
                         'observer queries add equal measurement load to each variant']}
    for value in args.artifact:
        label, separator, name = value.partition('=')
        if not separator:
            raise ValueError('--artifact requires LABEL=PATH')
        report['source_hashes'][label] = digest(name)
    write_json(output / 'run.json', report)
    control = heartbeat = None
    stop, finished = threading.Event(), threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: stop.set())
    submitted, replies, geometry, errors = {}, [], [], []
    lock = threading.Lock()
    reader = observer = beater = None
    rows = (output / 'frames.jsonl').open('w')
    restoration = {'attempted': False, 'independently_verified': False}
    try:
        connect = (lambda *values: MailboxConnection(args.mailbox_client, *values)) if args.mailbox_client else Connection
        control = connect(args.runtime, nonce, args.server_pid, args.server_uid)
        before = verify_probe(control.request(PROBE))
        if before['held'] or before['restoring'] or before['table_count'] or before['journal_pending']:
            raise ValueError('helper has pre-existing restoration obligations; refusing benchmark')
        report['probe_before'] = before
        heartbeat = connect(args.runtime, nonce, args.server_pid, args.server_uid, 2, control.token)

        def beat():
            try:
                while not stop.wait(min(0.25, control.lease_ms / 4000)):
                    reply = heartbeat.request(HEARTBEAT)
                    if len(reply) != 16 or struct.unpack('<4I', reply)[0]:
                        raise ValueError('heartbeat refused')
            except Exception as error:
                errors.append(f'heartbeat: {error}')
                stop.set()

        def receive():
            try:
                while True:
                    kind, seq, body = control.recv()
                    arrived = shared_ns()
                    if kind == PROBE and finished.is_set() and seq == control.seq:
                        report['probe_after'] = verify_probe(body)
                        return
                    if kind != FRAME or len(body) < 24:
                        raise ValueError('unexpected frame reply')
                    disposition, count, superseded, reserved, applied = struct.unpack('<4IQ', body[:24])
                    if disposition not in (0, 1) or reserved or len(body) != 24 + count:
                        raise ValueError('invalid frame reply body')
                    with lock:
                        sent = next((s for s in submitted.values() if s['wire_seq'] == seq), None)
                    if sent is None:
                        raise ValueError('reply does not match a submitted frame')
                    if disposition == 0 and (count != len(fixture['windows']) or any(body[24:])):
                        raise ValueError(f'helper did not apply every fixture record: {list(body[24:])}')
                    replies.append({'trace_index': sent['trace_index'], 'wire_seq': seq, 'received_ns': arrived,
                                    'disposition': disposition, 'superseded': superseded,
                                    'applied_total': applied,
                                    'round_trip_ms': (arrived - sent['send_before_ns']) / 1e6})
            except Exception as error:
                errors.append(f'receiver: {error}')
                stop.set()

        def observe():
            observed_native = NativeReadback()
            wid = fixture['windows'][0]['wid']
            period = round(1e9 / args.sample_hz)
            due = shared_ns()
            try:
                while not stop.is_set():
                    begin = shared_ns()
                    actual = observed_native.transform(wid)
                    at = shared_ns()
                    with lock:
                        candidates = list(submitted.values())[-max(64, trace['hz']):]
                    match = next((s for s in reversed(candidates) if close_matrix(actual, s['observed_window_matrix'])), None)
                    geometry.append({'sample_ns': at, 'query_ns': at - begin, 'matrix': actual,
                                     'trace_index': match['trace_index'] if match else None,
                                     'input_to_geometry_ms': (at - match['send_before_ns']) / 1e6 if match else None})
                    due += period
                    stop.wait(max(0, (due - shared_ns()) / 1e9))
            except Exception as error:
                errors.append(f'independent geometry: {error}')
                stop.set()

        beater = threading.Thread(target=beat, daemon=True)
        reader = threading.Thread(target=receive, daemon=True)
        observer = threading.Thread(target=observe, daemon=True)
        beater.start(); reader.start(); observer.start()
        start = shared_ns() + 100_000_000
        report['start_shared_ns'] = start
        for frame in trace['frames']:
            if stop.is_set():
                raise RuntimeError('; '.join(errors) or 'benchmark interrupted')
            deadline = start + frame['due_ns']
            delay = deadline - shared_ns()
            if delay > 0:
                stop.wait(delay / 1e9)
            matrices = [matrix(frame, w) for w in fixture['windows']]
            body = struct.pack('<II', len(matrices), 0) + b''.join(
                RECORD.pack(fixture['pid'], w['wid'], fixture['birth_sec'], fixture['birth_usec'], *m, 1., 0)
                for w, m in zip(fixture['windows'], matrices))
            sent = {'trace_index': frame['index'], 'phase': frame['phase'], 'due_ns': deadline,
                    'wire_seq': control.seq + 1, 'send_before_ns': shared_ns(),
                    'observed_window_matrix': matrices[0]}
            if 'requested_phase_bucket' in frame:
                sent['requested_phase_bucket'] = frame['requested_phase_bucket']
            with lock:
                submitted[frame['index']] = sent
            control.send(FRAME, body)
            sent['send_after_ns'] = shared_ns()
            sent['send_call_ms'] = (sent['send_after_ns'] - sent['send_before_ns']) / 1e6
            sent['scheduler_late_ms'] = max(0, sent['send_before_ns'] - deadline) / 1e6
            rows.write(json.dumps(sent) + '\n')
        if trace.get('kind') == 'held-step':
            # Preserve the final step's observation opportunity before the drain
            # and restoration. Holds remain inside the frozen bounded duration.
            stop.wait(max(0, (start + trace['duration_ns'] - shared_ns()) / 1e9))
            if stop.is_set():
                raise RuntimeError('; '.join(errors) or 'held-step benchmark interrupted')
        finished.set()
        # A serial-queue probe is a drain barrier, including when the last frame
        # was answered before the sender set finished. The receiver owns reads.
        control.send(PROBE)
        reader.join(5)
        if reader.is_alive():
            raise RuntimeError('final frame reply did not drain; benchmark incomplete')
        if errors:
            raise RuntimeError('; '.join(errors))
        last = trace['frames'][-1]
        report['final_pose_independently_verified'] = all(
            close_matrix(native.transform(w['wid']), matrix(last, w)) for w in fixture['windows'])
        if not report['final_pose_independently_verified']:
            raise RuntimeError('final helper acknowledgement differs from independent native transform')
        report['status'] = 'measured_control_path'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
    finally:
        stop.set()
        for thread in (beater, observer):
            if thread:
                thread.join(2)
        if control:
            restoration['attempted'] = True
            try:
                if reader and reader.is_alive():
                    # An outstanding receiver owns reads; disconnect invokes restoration.
                    control.shutdown()
                    reader.join(6)
                    control.close()
                    restoration['method'] = 'control_disconnect'
                else:
                    body = control.request(RESTORE)
                    if len(body) < 16:
                        raise ValueError('short restoration reply')
                    count, pending, persisted, reserved = struct.unpack('<4I', body[:16])
                    if pending or not persisted or reserved or len(body) != 16 + count * 32:
                        raise ValueError('helper restoration unresolved or undurable')
                    restoration.update(method='restore_all', helper_count=count, journal_persisted=True)
                    control.close()
            except Exception as error:
                restoration['error'] = str(error)
                control.close()
        if heartbeat:
            heartbeat.shutdown()
            if beater:
                beater.join(2)
            heartbeat.close()
        end = time.monotonic() + 4
        while True:
            try:
                restoration['independently_verified'] = native.restored(fixture)
            except Exception as error:
                restoration['verification_error'] = str(error)
            if restoration['independently_verified'] or time.monotonic() >= end:
                break
            time.sleep(0.02)
        rows.close()
        report['restoration'] = restoration
        report['frames_submitted'] = len(submitted)
        report['send_call_ms'] = distribution([s['send_call_ms'] for s in submitted.values() if 'send_call_ms' in s])
        report['scheduler_late_ms'] = distribution([s['scheduler_late_ms'] for s in submitted.values() if 'scheduler_late_ms' in s])
        report['acknowledgement_round_trip_ms'] = distribution([r['round_trip_ms'] for r in replies if r['disposition'] == 0])
        report['applied_replies'] = sum(r['disposition'] == 0 for r in replies)
        report['dropped_replies'] = sum(r['disposition'] == 1 for r in replies)
        report['helper_reported_superseded'] = sum(r['superseded'] for r in replies)
        report['geometry_sample_count'] = len(geometry)
        report['independent_geometry_query_ms'] = distribution([r['query_ns'] / 1e6 for r in geometry])
        # First independent observation of each pose; polling resolution bounds this metric.
        first = {}
        for g in geometry:
            if g['trace_index'] is not None:
                first.setdefault(g['trace_index'], g['input_to_geometry_ms'])
        report['first_observed_geometry_ms'] = distribution(list(first.values()))
        try:
            report['optical'] = parse_optical(args.optical_samples, run_id, trace_hash, submitted, trace['hz'],
                                              trace.get('kind', 'continuous'))
        except Exception as error:
            report['optical'] = {'available': False, 'error': str(error)}
            report['status'] = 'failed'
        report['winner_eligible'] = bool(report.get('status') == 'measured_control_path'
                                         and restoration['independently_verified']
                                         and report['optical'].get('cadence_eligible'))
        if not restoration['independently_verified']:
            report['status'] = 'failed'
        for name, values in [('replies.jsonl', replies), ('geometry.jsonl', geometry)]:
            (output / name).write_text(''.join(json.dumps(row) + '\n' for row in values))
        write_json(output / 'run.json', report)
    print(json.dumps({'report': str(output / 'run.json'), 'status': report['status'],
                      'winner_eligible': report['winner_eligible'], 'restoration': restoration}))
    return 0 if report['status'] != 'failed' else 1


def fixture(args):
    native = NativeReadback()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    os.chmod(output, 0o700)
    runtime = output / 'runtime'; runtime.mkdir(mode=0o700)
    nonce = secrets.token_hex(32)
    nonce_file = output / 'nonce'; nonce_file.write_text(nonce + '\n'); nonce_file.chmod(0o600)
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: stop.set())
    host = Path(args.host).resolve()
    log = (output / 'host.log').open('w')
    child = subprocess.Popen([str(host), str(Path(args.payload).resolve()), str(runtime), nonce,
                              '--windows', str(args.windows), '--size', args.size,
                              '--watchdog', str(args.hold_seconds), '--all-spaces', 'yes'], stdout=log, stderr=log)
    manifest = None
    cleanup = {'pid': child.pid, 'terminated': False, 'originals_verified_before_exit': None}
    try:
        until = time.monotonic() + 10
        ready = None
        while time.monotonic() < until and child.poll() is None and not stop.is_set():
            ready = next((line.split() for line in (output / 'host.log').read_text().splitlines()
                          if line.startswith(f'READY {child.pid} ')), None)
            if ready:
                break
            time.sleep(0.04)
        if not ready:
            raise RuntimeError('disposable cooperative host did not become ready: '
                               + (output / 'host.log').read_text()[-2000:])
        if len(ready[2:]) != args.windows:
            raise RuntimeError('disposable fixture window count differs from requested workload')
        manifest = {'schema': 1, 'fixture_kind': FIXTURE_KIND, **native.process(child.pid),
                    'host_sha256': digest(host), 'supervisor_pid': os.getpid(),
                    'created_shared_ns': shared_ns(), 'clock': SHARED_CLOCK, 'host_runtime': str(runtime),
                    'host_nonce_file': str(nonce_file),
                    'windows': [native.window(int(w)) for w in ready[2:]]}
        native.verify_fixture(manifest)
        write_json(output / 'fixture.json', manifest)
        print(json.dumps({'fixture_manifest': str(output / 'fixture.json'), 'pid': child.pid}), flush=True)
        while child.poll() is None and not stop.wait(0.1):
            pass
    finally:
        if manifest and child.poll() is None:
            try:
                cleanup['originals_verified_before_exit'] = native.restored(manifest)
            except Exception as error:
                cleanup['verification_error'] = str(error)
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        cleanup['terminated'] = child.poll() is not None
        cleanup['exit_code'] = child.returncode
        log.close()
        write_json(output / 'cleanup.json', cleanup)
    return 0 if cleanup['originals_verified_before_exit'] is True else 1


def decode_pixels(args):
    """Associate externally captured marker bounds with unambiguous sent poses.

    Bounding-box quantization may make neighbouring camera poses indistinguishable.
    Such frames are omitted rather than counted as missed output refreshes.
    """
    directory = Path(args.run_dir)
    report = json.loads((directory / 'run.json').read_text())
    if report.get('schema') != SCHEMA or report.get('clock') != SHARED_CLOCK:
        raise ValueError('legacy run clock is not cross-process; visible latency invalid, rerun schema 2')
    fixture = json.loads(Path(args.fixture_manifest).read_text())
    if digest(args.fixture_manifest) != report['fixture_manifest_sha256']:
        raise ValueError('pixel decoder fixture manifest differs from benchmark')
    raw = [json.loads(line) for line in Path(args.raw_pixels).read_text().splitlines() if line.strip()]
    metadata = next((row for row in raw if row.get('type') == 'observer'), None)
    window = fixture['windows'][0]
    if (not metadata or metadata.get('schema') != SCHEMA or metadata.get('clock') != SHARED_CLOCK
            or metadata.get('fixture_manifest_sha256') != report['fixture_manifest_sha256']
            or metadata.get('wid') != window['wid'] or metadata.get('pid') != fixture['pid']
            or metadata.get('capture_method') != 'display_capture'
            or metadata.get('filtered_fixture_only') is not True):
        raise ValueError('display observer identity/filter metadata differs')
    submitted = [json.loads(line) for line in (directory / 'frames.jsonl').read_text().splitlines() if line.strip()]
    sx, sy = metadata.get('point_scale_x', 1), metadata.get('point_scale_y', 1)
    if not 0 < sx <= 4 or not 0 < sy <= 4:
        raise ValueError('invalid display pixel-to-point scale')
    # Each observed marker edge is quantized by at most one output pixel;
    # width/height contain two independently quantized edges.
    uncertainty = (sx + 0.05, sy + 0.05, 2 * sx + 0.05, 2 * sy + 0.05)
    expected = []
    for frame in submitted:
        a, _, _, d, tx, ty = frame['observed_window_matrix']
        expected.append((frame, [-tx / a, -ty / d, window['bounds'][2] / a, window['bounds'][3] / d]))
    trace_kind = report.get('trace_kind', 'continuous')
    first_send = min(frame['send_before_ns'] for frame in submitted)
    end_ns = max(frame['send_before_ns'] for frame in submitted) + round(1e9 / report['hz'])
    if trace_kind == 'held-step':
        end_ns = report['start_shared_ns'] + report['trace_duration_ns']
    display_origin = min(row['presented_ns'] for row in raw if row.get('type') == 'pixels')
    period_ns = round(1e9 / report['hz'])
    decoded, ambiguous, seen, admissible = [], 0, set(), []
    exclusions = {'no_matching_pose': 0, 'multiple_matching_poses': 0,
                  'outside_held_observation_window': 0}
    for sample in sorted(raw, key=lambda row: row.get('presented_ns', -1)):
        if (sample.get('type') != 'pixels' or not sample.get('marker_bounds')
                or sample.get('unobscured') is not True):
            continue
        at = sample['presented_ns']
        if trace_kind == 'held-step' and not first_send <= at <= end_ns:
            exclusions['outside_held_observation_window'] += 1
            continue
        actual = sample['marker_bounds']
        candidates = []
        for frame, rect in expected:
            if frame['send_before_ns'] > at:
                continue
            distance = sum(abs(a - b) for a, b in zip(actual, rect))
            if all(abs(a - b) <= limit for a, b, limit in zip(actual, rect, uncertainty)):
                candidates.append((distance, frame))
        candidates.sort(key=lambda pair: pair[0])
        # The marker boundary is quantized to output pixels. More than one pose
        # within that uncertainty is ambiguous even if one is numerically nearer.
        if len(candidates) != 1:
            ambiguous += 1
            if first_send <= at <= end_ns:
                key = 'no_matching_pose' if not candidates else 'multiple_matching_poses'
                exclusions[key] += 1
            continue
        frame = candidates[0][1]
        actual_bucket = ((frame['send_before_ns'] - display_origin) % period_ns) * 6 // period_ns
        admissible.append({'trace_index': frame['trace_index'], 'presented_ns': at,
                           'pose_age_ms': (at - frame['send_before_ns']) / 1e6})
        if frame['trace_index'] in seen:
            continue
        seen.add(frame['trace_index'])
        decoded.append({'schema': SCHEMA, 'run_id': report['run_id'], 'trace_sha256': report['trace_sha256'],
                        'trace_index': frame['trace_index'], 'presented_ns': at,
                        'clock': SHARED_CLOCK, 'observer_kind': 'independent_display_pixels',
                        'capture_method': 'display_capture', 'occluded': False,
                        'observer': 'scoped ScreenCaptureKit display output marker bounding box',
                        'capture_requested_hz': metadata['requested_hz'],
                        'visibility_witness_ns': sample['visibility_witness_ns'],
                        'requested_phase_bucket': frame.get('requested_phase_bucket'),
                        'actual_phase_bucket': actual_bucket})
    Path(args.output).write_text(''.join(json.dumps(row) + '\n' for row in decoded))
    optical = parse_optical(args.output, report['run_id'], report['trace_sha256'],
                            {s['trace_index']: s for s in submitted}, report['hz'], trace_kind)
    optical.update(raw_samples_sha256=digest(args.raw_pixels), ambiguous_samples=ambiguous,
                   decoder_source_sha256=digest(__file__),
                   requested_observer_hz=metadata['requested_hz'],
                   physical_panel_optical_proof=False)
    optical['capture_observation'] = capture_observation_metrics(raw, admissible, report['hz'],
                                                                first_send, end_ns, exclusions)
    optical['phase_clock'] = {'origin_ns': display_origin, 'period_ns': period_ns, 'buckets': 6,
                              'basis': 'actual send phase modulo requested display period from captured display timestamp origin'}
    report['observer_configuration'] = {key: metadata.get(key) for key in
                                       ('capture_method', 'filtered_fixture_only', 'display_id',
                                        'width', 'height', 'point_scale_x', 'point_scale_y', 'requested_hz', 'clock',
                                        'observer_sha256', 'visibility_witness_policy')}
    # Quantized poses and inadequate capture cadence cannot establish smoothness.
    eligible = (trace_kind == 'continuous' and optical['coverage'] >= 0.9
                and metadata['requested_hz'] >= report['hz'])
    optical['cadence_eligible'] = eligible
    if not eligible and trace_kind == 'continuous':
        optical['limitation'] = 'insufficient unambiguous pose coverage/capture rate; no smoothness winner'
    report['optical'] = optical
    report['winner_eligible'] = (eligible and report['status'] == 'measured_control_path'
                                 and report['restoration']['independently_verified'])
    report['latency_comparison_eligible'] = (trace_kind == 'held-step' and optical.get('latency_eligible', False)
                                           and report['status'] == 'measured_control_path'
                                           and report['restoration']['independently_verified'])
    write_json(directory / 'run.json', report)
    print(json.dumps({'decoded': len(decoded), 'ambiguous_samples': ambiguous,
                      'coverage': optical['coverage'], 'winner_eligible': report['winner_eligible'],
                      'latency_comparison_eligible': report['latency_comparison_eligible']}))
    return 0


def compare(args):
    reports = [json.loads(Path(path).read_text()) for path in args.reports]
    if len(reports) < 2:
        raise ValueError('comparison needs at least two runs')
    if any(row.get('schema') != SCHEMA or row.get('clock') != SHARED_CLOCK for row in reports):
        raise ValueError('legacy report clock is not cross-process; visible latency invalid, rerun schema 2')
    same = all(all(row.get(key) == reports[0].get(key) for key in
                   ('trace_sha256', 'fixture_geometry', 'host_sha256', 'environment', 'system', 'hz',
                    'sample_hz', 'observer_configuration')) for row in reports)
    eligible = same and all(row.get('winner_eligible') and
                            'observed_pose_gap_intervals' in row.get('optical', {}) for row in reports)
    result = {'schema': SCHEMA, 'clock': SHARED_CLOCK, 'matched_inputs': same, 'winner': None,
              'basis': 'captured decoded-pose latency and unobserved pose intervals; gaps include capture/decoder omissions, not physical missed refreshes',
              'variants': [row['variant'] for row in reports]}
    if eligible:
        # No arbitrary scalar score: choose only if one variant dominates both
        # p99 captured-pose latency and unobserved decoded-pose intervals. Those
        # intervals can include observer/decoder omissions, never physical misses.
        def metrics(row):
            opt = row['optical']
            return (opt['input_to_visible_ms']['p99'], opt['observed_pose_gap_intervals'])
        candidates = [row for row in reports if all(all(a <= b for a, b in zip(metrics(row), metrics(other)))
                                                   for other in reports)]
        if len(candidates) == 1:
            result['winner'] = candidates[0]['variant']
        else:
            result['reason'] = 'captured-pose metrics trade off or tie; no unique dominating variant'
    else:
        result['reason'] = ('inputs/environment differ' if not same else
                            'missing admissible captured-pose evidence, current pose-gap metric, or restoration')
    write_json(args.output, result)
    print(json.dumps(result))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('clock', help='read the explicit cross-process Mach clock; no window operations')
    trace = commands.add_parser('trace', help='create a frozen pure-data workload; no native calls')
    trace.add_argument('--hz', type=int, default=120)
    trace.add_argument('--seconds', type=float, default=5)
    trace.add_argument('--pan-points', type=float, default=120)
    trace.add_argument('--kind', choices=('continuous', 'held-step'), default='continuous')
    trace.add_argument('--output', required=True)
    live = commands.add_parser('run', help='measure an explicitly scoped, already prepared native endpoint')
    live.add_argument('--live-owned-fixture', action='store_true', required=True)
    for flag in ('runtime', 'nonce-file', 'fixture-manifest', 'trace', 'output', 'variant'):
        live.add_argument('--' + flag, required=True)
    live.add_argument('--server-pid', type=int, required=True)
    live.add_argument('--server-uid', type=int, required=True)
    live.add_argument('--sample-hz', type=int, choices=range(1, 241), default=120)
    live.add_argument('--artifact', action='append', default=[], help='LABEL=PATH hashes executable/payload/source bytes')
    live.add_argument('--environment', help='frozen JSON describing hardware, display mode and observer configuration')
    live.add_argument('--optical-samples', help='independent decoded output-pixel JSONL; never producer timestamps')
    live.add_argument('--mailbox-client', help='VM-built native file transport adapter; omitted uses production Unix socket')
    owned = commands.add_parser('fixture', help='supervise only a newly spawned disposable cooperative host')
    owned.add_argument('--live-owned-fixture', action='store_true', required=True)
    owned.add_argument('--host', required=True)
    owned.add_argument('--payload', required=True)
    owned.add_argument('--output', required=True)
    owned.add_argument('--windows', type=int, choices=range(1, 17), default=4)
    owned.add_argument('--size', default='480x320')
    owned.add_argument('--hold-seconds', type=int, choices=range(1, 901), default=300)
    comparison = commands.add_parser('compare', help='compare saved runs; no native calls')
    comparison.add_argument('reports', nargs='+')
    comparison.add_argument('--output', required=True)
    decoder = commands.add_parser('decode-pixels', help='decode saved display-output marker samples; no native calls')
    for flag in ('run-dir', 'fixture-manifest', 'raw-pixels', 'output'):
        decoder.add_argument('--' + flag, required=True)
    args = parser.parse_args()
    if args.command == 'clock':
        print(json.dumps({'schema': SCHEMA, 'clock': SHARED_CLOCK, 'now_ns': shared_ns()}))
        return 0
    if args.command == 'trace':
        write_json(args.output, make_trace(args.hz, args.seconds, args.pan_points, args.kind))
        print(json.dumps({'trace': args.output, 'sha256': digest(args.output)})); return 0
    if args.command == 'fixture':
        return fixture(args)
    if args.command == 'run':
        return run(args)
    if args.command == 'decode-pixels':
        return decode_pixels(args)
    return compare(args)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError) as error:
        print(f'NOT MEASURED: {error}', file=sys.stderr)
        raise SystemExit(1)
