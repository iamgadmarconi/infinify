#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Boundary-only idle counters for six explicitly spawned native windows.

The fixture-only baseline has overlapping original windows. The managed phase
has a fitted grid and an extra static canvas surface. Those geometry/surface
differences prevent treating the delta as isolated compositor overhead. No
cadence or optical-presentation assertion is made, and the regular render
benchmark is unchanged.
"""
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
if sys.argv[1:] != ['--live-owned-fixture']:
    print('LIVE NOT RUN: pass --live-owned-fixture for the disposable native idle comparison.')
    raise SystemExit(0 if len(sys.argv) == 1 else 2)
if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
    raise SystemExit('NOT RUN: another Infinify is running.')
stage = subprocess.run(['defaults', 'read', 'com.apple.WindowManager', 'GloballyEnabled'], capture_output=True, text=True)
if stage.returncode == 0 and stage.stdout.strip() == '1':
    raise SystemExit('NOT RUN: Stage Manager is enabled.')
APP = Path(os.environ.get('INFINIFY_BENCH_APP', ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify')).resolve()
spec = importlib.util.spec_from_file_location('owned_idle_helper', ROOT / 'native/privileged/fixture_v2_test.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
assert APP.is_file() and (owned.BUILD / 'host').is_file() and (owned.BUILD / 'payload-arm64.dylib').is_file(), 'Build the app and helper first.'
(ROOT / 'target/ipc').mkdir(exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix='idle.', dir=ROOT / 'target/ipc'))
runtime = evidence / 'h'
runtime.mkdir(mode=0o700)
sock = evidence / 's'
print(f'Evidence: {evidence}', flush=True)
inputs = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (APP, owned.BUILD / 'host', owned.BUILD / 'payload-arm64.dylib', Path(__file__))}
(evidence / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')


class Rusage(C.Structure):
    # SDK sys/resource.h, RUSAGE_INFO_V0. Only memory and the start-identity
    # counter are consumed; CPU units come from ps cumulative time instead.
    _fields_ = [('uuid', C.c_uint8 * 16)] + [(key, C.c_uint64) for key in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups',
        'pageins', 'wired_size', 'resident_size', 'phys_footprint',
        'proc_start_abstime', 'proc_exit_abstime')]


class ProcessInfo(C.Structure):
    # SDK sys/proc_info.h, PROC_PIDTBSDINFO; fixed-width native arm64 layout.
    _fields_ = [(name, C.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
        'svuid', 'svgid', 'reserved')] + [
        ('comm', C.c_char * 16), ('name', C.c_char * 32)] + [
        (name, C.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')] + [
        ('nice', C.c_int32), ('birth_sec', C.c_uint64), ('birth_usec', C.c_uint64)]


libproc = C.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
libproc.proc_pid_rusage.restype = C.c_int
libproc.proc_pidinfo.argtypes = [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int]
libproc.proc_pidinfo.restype = C.c_int
owned.sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(owned.Rect)]
owned.sky.SLSGetWindowBounds.restype = C.c_int
owned.sky.SLSGetWindowOwner.argtypes = [C.c_int, C.c_uint32, C.POINTER(C.c_int)]
owned.sky.SLSGetWindowOwner.restype = C.c_int
owned.sky.SLSConnectionGetPID.argtypes = [C.c_int, C.POINTER(C.c_int)]
owned.sky.SLSConnectionGetPID.restype = C.c_int
server_pids = subprocess.run(['pgrep', '-x', 'WindowServer'], capture_output=True, text=True).stdout.split()
server_pid = int(server_pids[0]) if len(server_pids) == 1 else None
host = app = before = host_identity = None
identities = {}
app_log = None
result = {'scope': 'six static owned native windows, cooperative helper only; no Dock injection',
          'interval_seconds_requested': 6,
          'limitations': ['WindowServer counters cover the whole desktop, including unrelated applications.',
                          'Fixture-only overlapping originals differ from the managed grid plus static canvas surface.',
                          'Memory values are endpoint RSS and charged physical footprint, not peaks or all GPU allocations.',
                          'An idle interval has no frame-rate or optical-presentation claim.']}


def interrupted(number, _frame):
    raise SystemExit(128 + number)


for number in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, interrupted)


def read_process(pid):
    if pid is None:
        return None
    row = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,time=,rss='], capture_output=True, text=True)
    fields = row.stdout.split()
    if row.returncode or len(fields) < 3:
        return None
    text = fields[-2]
    days = 0
    if '-' in text:
        prefix, text = text.split('-', 1)
        days = int(prefix)
    cpu = 0.0
    for part in text.split(':'):
        cpu = cpu * 60 + float(part)
    usage = Rusage()
    available = libproc.proc_pid_rusage(pid, 0, C.byref(usage)) == 0
    return {'pid': pid, 'started': ' '.join(fields[:-2]), 'at': time.monotonic(),
            'cpu_seconds': days * 86400 + cpu, 'rss_kib': int(fields[-1]),
            'kernel_start': usage.proc_start_abstime if available else None,
            'physical_footprint_bytes': usage.phys_footprint if available else None}


def process_interval(first, last):
    if first is None or last is None:
        return None
    assert (first['pid'], first['started'], first['kernel_start']) == (last['pid'], last['started'], last['kernel_start']), 'process identity changed across idle interval'
    elapsed = last['at'] - first['at']
    cpu = last['cpu_seconds'] - first['cpu_seconds']
    assert elapsed > 0 and cpu >= 0
    return {'pid': first['pid'], 'seconds': elapsed, 'cpu_percent_one_core': 100 * cpu / elapsed,
            'rss_start_kib': first['rss_kib'], 'rss_end_kib': last['rss_kib'],
            'physical_footprint_start_bytes': first['physical_footprint_bytes'],
            'physical_footprint_end_bytes': last['physical_footprint_bytes']}


def quiet_interval(managed):
    targets = {'app': app.pid if managed else None, 'helper': host.child.pid,
               'window_server_whole_desktop': server_pid}
    first = {name: read_process(pid) for name, pid in targets.items()}
    assert first['helper'] and (not managed or first['app'])
    # No IPC, geometry, window-list, helper or process polling during these six
    # seconds. The cooperating host and managed app do only their own idle work.
    time.sleep(6)
    last = {name: read_process(pid) for name, pid in targets.items()}
    assert last['helper'] and (not managed or last['app'])
    return {name: process_interval(first[name], last[name]) for name in targets}


def process_identity(pid):
    info = ProcessInfo()
    assert libproc.proc_pidinfo(pid, 3, 0, C.byref(info), C.sizeof(info)) == C.sizeof(info)
    assert info.pid == pid and info.uid == os.getuid() and info.birth_sec and info.birth_usec < 1000000, 'fresh same-user process identity'
    return (pid, info.birth_sec, info.birth_usec)


def window_identity(wid):
    assert host.child.poll() is None, 'owned host exited'
    owner, pid = C.c_int(), C.c_int()
    assert owned.sky.SLSGetWindowOwner(owned.sky.SLSMainConnectionID(), wid, C.byref(owner)) == 0
    assert owned.sky.SLSConnectionGetPID(owner.value, C.byref(pid)) == 0
    assert pid.value == host.child.pid and process_identity(pid.value) == host_identity, 'owned window process identity changed'
    identity = (pid.value, wid, *host_identity[1:])
    assert identity == identities[wid], 'window differs from exact cooperative enrollment'
    return {'owner': owner.value, 'identity': list(identity)}


def observe(wids):
    values = {}
    for wid in wids:
        identity = window_identity(wid)
        bounds = owned.Rect()
        assert owned.sky.SLSGetWindowBounds(owned.sky.SLSMainConnectionID(), wid, C.byref(bounds)) == 0
        values[str(wid)] = {**identity, 'bounds': [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height],
                            'screen': owned.screen(wid), 'transform': owned.transform(wid), 'alpha': owned.alpha(wid)}
        assert window_identity(wid) == identity, 'window identity or owner changed during independent read'
    return values


def ask(request):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(4)
        connection.connect(str(sock))
        connection.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
    response = json.loads(data)
    assert 'Ok' in response, response
    return response['Ok']


def state():
    return ask('State')['State']


def until(read, passed, timeout=8):
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if passed(value):
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.05)


def pose(value):
    return (value['camera'], value['zoom'], [(w['id'], w['position'], w['size']) for w in value['windows']])


try:
    host = owned.Host('--windows', '6', '--size', '1700x1100', '--activation', 'regular',
                      '--all-spaces', 'yes', '--level', '4', '--watchdog', '150', run=runtime)
    host_identity = process_identity(host.child.pid)
    ready = next(line for line in host.text().splitlines() if line.startswith('READY ')).split()
    assert int(ready[1]) == host.child.pid
    wids = [int(v) for v in ready[2:]]
    assert len(wids) == len(set(wids)) == 6
    # This authenticated control connection sends only PROBE, with no native
    # frames or enrollment. Close it before the app takes its own session.
    audit = owned.Conn(host)
    try:
        assert audit.status == 0 and audit.scope == 1 and audit.server_pid == host.child.pid and audit.caps & 16
        probe = audit.probe()
        assert probe['scope'] == 1 and probe['server_pid'] == host.child.pid
        assert all(probe[key] == 0 for key in ('held', 'restoring', 'journal_pending', 'table_count'))
        assert len(probe['fixtures']) == 6
        identities = {who[1]: who for who in probe['fixtures']}
        assert set(identities) == set(wids)
        assert all((who[0], who[2], who[3]) == host_identity for who in identities.values())
    finally:
        audit.close()
    result['owned_host_identity'] = list(host_identity)
    time.sleep(2)
    before = observe(wids)
    result['original_geometry'] = before
    result['fixture_only'] = quiet_interval(False)
    assert observe(wids) == before, 'original native scene changed during baseline'
    nonce = evidence / 'nonce'
    with open(nonce, 'x') as file:
        os.chmod(nonce, 0o600)
        file.write(host.nonce + '\n')
    shader = evidence / 'static.glsl'
    shader.write_text('precision highp float;\nvoid main(){gl_FragColor=vec4(0.07,0.09,0.12,1.0);}\n')
    config = evidence / 'config.toml'
    config.write_text(f'[background]\ntype = "shader"\npath = "{shader}"\nanimate_fps = 0\n')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('INFINIFY_DEBUG'):
            del env[key]
    # These two flags permit the owned fixture level. No animated background,
    # source synthesizer, frame-stat timer or diagnostic trace is enabled.
    env.update(INFINIFY_DEBUG_BENCH='1', INFINIFY_DEBUG_NATIVE_BENCH='1')
    app_log = open(evidence / 'app.log', 'w')
    app = subprocess.Popen([str(APP), '--windowed', '16384x16384', '--only-pid', str(host.child.pid),
                            '--no-native-focus', '--no-hover-forwarding', '--native-helper', str(runtime), str(nonce),
                            '--config', str(config), '--socket', str(sock), '--state', str(evidence / 'state.json')],
                           stdout=app_log, stderr=app_log, env=env)
    until(lambda: sock.exists() or app.poll() is not None, bool)
    assert app.poll() is None, 'owned app failed to start'
    initial = until(state, lambda value: len(value['windows']) == 6 and all(not w['suspended'] for w in value['windows']))
    time.sleep(1.1)
    initial = state()
    cx, cy = initial['camera']
    out = initial['outputs'][0]['size']
    wide = max(w['size'][0] for w in initial['windows'])
    high = max(w['size'][1] for w in initial['windows'])
    for i, window in enumerate(sorted(initial['windows'], key=lambda w: w['title'])):
        ask({'Move': {'window': window['id'], 'to': [round(cx + (i % 3 - 1) * (wide + 40)), round(cy + (.5 - i // 3) * (high + 40))]}})
    zoom = round(min(out[0] / (3 * wide + 400), out[1] / (2 * high + 120)), 4)
    ask({'Zoom': zoom})
    until(state, lambda value: abs(value['zoom'] - zoom) < 1e-10)
    ask({'Camera': [cx, cy]})
    until(state, lambda value: abs(value['zoom'] - zoom) < 1e-10 and all(abs(a - b) < 1e-6 for a, b in zip(value['camera'], [cx, cy])))
    time.sleep(2)
    first_state = state()
    first_geometry = observe(wids)
    result['managed_geometry'] = first_geometry
    result['managed_pose'] = pose(first_state)
    result['managed'] = quiet_interval(True)
    assert pose(state()) == pose(first_state), 'managed canvas changed during idle interval'
    assert observe(wids) == first_geometry, 'managed native geometry changed during idle interval'
    ask({'Action': 'quit'})
    app.wait(timeout=6)
    assert app.returncode == 0, ('owned app did not shut down normally', app.returncode)
    until(lambda: observe(wids), lambda value: value == before, timeout=4)
    journal = host.wait_journal('empty')
    assert journal['windows'] == []
    result['exact_restoration'] = True
    result['empty_restoration_journal'] = True
finally:
    if app and app.poll() is None:
        try:
            ask({'Action': 'quit'})
            app.wait(timeout=6)
        except Exception:
            app.terminate()
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=3)
    try:
        if host and before and host.child.poll() is None:
            until(lambda: observe(wids), lambda value: value == before, timeout=4)
            if (runtime / 'v2-journal.json').exists():
                assert host.wait_journal('empty')['windows'] == []
    finally:
        for child in owned.hosts:
            child.stop()
        if app_log:
            app_log.close()
        result['app_exit'] = None if app is None else {'pid': app.pid, 'returncode': app.returncode}
        result['helper_exits'] = [{'pid': child.child.pid, 'returncode': child.child.returncode} for child in owned.hosts]
        result['children_exited'] = (app is None or app.poll() is not None) and all(child.child.poll() is not None for child in owned.hosts)
        result['status'] = 'PASS' if sys.exc_info()[0] is None and result.get('exact_restoration') and result['children_exited'] else 'FAIL'
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
