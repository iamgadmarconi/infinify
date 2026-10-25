#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""VM-only, fixture-scoped orchestration of already-built native benchmarks."""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import signal
import subprocess
import sys
import tempfile
import time

DOCK_VARIANTS = ('baseline', 'baseline-o2', 'candidate-scalar',
                 'candidate-scalar-inline', 'candidate-transaction', 'candidate-list')


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require_vm():
    if sys.platform != 'darwin':
        raise RuntimeError('execution is restricted to the authorized macOS VM')
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        raise RuntimeError(f'VM-only guard refused hw.model={model}')
    return model


def environment():
    """Read actual display modes; zero refresh means unknown, never 60 by inference."""
    cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cg.CGGetActiveDisplayList.argtypes = [C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)]
    cg.CGGetOnlineDisplayList.argtypes = cg.CGGetActiveDisplayList.argtypes
    cg.CGDisplayIsAsleep.argtypes = [C.c_uint32]
    cg.CGDisplayIsAsleep.restype = C.c_uint32
    cg.CGDisplayCopyDisplayMode.argtypes = [C.c_uint32]
    cg.CGDisplayCopyDisplayMode.restype = C.c_void_p
    for name in ('CGDisplayModeGetRefreshRate', 'CGDisplayModeGetPixelWidth', 'CGDisplayModeGetPixelHeight'):
        getattr(cg, name).argtypes = [C.c_void_p]
        getattr(cg, name).restype = C.c_double if name.endswith('RefreshRate') else C.c_size_t
    cg.CGDisplayModeRelease.argtypes = [C.c_void_p]
    ids, count = (C.c_uint32 * 32)(), C.c_uint32()
    if cg.CGGetActiveDisplayList(32, ids, C.byref(count)) or count.value >= 32:
        raise RuntimeError('active physical display modes could not be bounded')
    online_ids, online_count = (C.c_uint32 * 32)(), C.c_uint32()
    if cg.CGGetOnlineDisplayList(32, online_ids, C.byref(online_count)) or online_count.value >= 32:
        raise RuntimeError('online display list could not be bounded')
    displays = []
    for display in ids[:count.value]:
        mode = cg.CGDisplayCopyDisplayMode(display)
        if not mode:
            raise RuntimeError('active display mode unavailable')
        try:
            hz = cg.CGDisplayModeGetRefreshRate(mode)
            displays.append({'id': display, 'pixel_width': cg.CGDisplayModeGetPixelWidth(mode),
                             'pixel_height': cg.CGDisplayModeGetPixelHeight(mode),
                             'mode_refresh_hz': hz if hz > 0 else None,
                             'asleep': bool(cg.CGDisplayIsAsleep(display))})
        finally:
            cg.CGDisplayModeRelease(mode)
    return {'hw_model': require_vm(), 'displays': displays, 'active_display_count': len(displays),
            'awake_active_display_count': sum(not row['asleep'] for row in displays),
            'online_display_count': online_count.value,
            'online_displays': [{'id': display, 'asleep': bool(cg.CGDisplayIsAsleep(display))}
                                for display in online_ids[:online_count.value]], 'requested_trace_hz': 60,
            'requested_observer_hz': 60, 'refresh_note': 'zero mode refresh is unknown; delivered cadence is measured separately'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-owned-fixture', action='store_true')
    parser.add_argument('--root', default='/Users/admin/InfinifyPerf')
    parser.add_argument('--output')
    parser.add_argument('--admin', default='admin')
    parser.add_argument('--variant', action='append', choices=DOCK_VARIANTS + ('windowserver',))
    parser.add_argument('--repeats', type=int, choices=range(1, 6), default=3)
    parser.add_argument('--windows', type=int, choices=range(1, 17), default=4)
    parser.add_argument('--pan-points', type=float, default=600,
                        help='bounded trace span0..600;600 improves per-frame pixel-pose separation')
    parser.add_argument('--trace-kind', choices=('continuous', 'held-step'), default='continuous')
    parser.add_argument('--fixture-payload', help='common cooperative arm64 payload, never a measured backend')
    parser.add_argument('--environment-only', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    require_vm()
    if args.environment_only:
        print(json.dumps(environment()));return 0
    if os.geteuid() != 0 or not args.live_owned_fixture or not args.output:
        parser.error('root plus explicit --live-owned-fixture and fresh --output are required')
    variants = args.variant or ['candidate-scalar-inline', 'windowserver']
    if len(set(variants)) != len(variants):
        parser.error('each --variant must occur once')
    if 'windowserver' in variants and len(variants) > 2:
        parser.error('select one Dock variant plus WindowServer to fit its single 60-second lifetime')
    if 'windowserver' in variants and args.repeats > 3:
        parser.error('WindowServer comparisons permit at most three four-second repetitions per backend')
    account = pwd.getpwnam(args.admin)
    if account.pw_uid == 0:
        parser.error('fixture/controller must be a non-root login user')
    root, output = Path(args.root).resolve(), Path(args.output).resolve()
    script, bench = Path(__file__).resolve(), Path(__file__).with_name('native_path_bench.py').resolve()
    built = root / 'variants'
    host, observer = built / 'native-performance/marker-fixture', built / 'native-performance/display-observer'
    dock_loader, ws_loader = built / 'loader-pinned-arm64e', built / 'windowserver-mailbox/ws-loader-arm64e'
    mailbox_client = built / 'windowserver-mailbox/libmailbox-client.dylib'
    fixture_payload = Path(args.fixture_payload).resolve() if args.fixture_payload else built / 'candidate-list/helper/payload-arm64.dylib'
    payloads = {v: built / ('windowserver-mailbox' if v == 'windowserver' else v + '/helper') / 'payload-arm64e.dylib' for v in variants}
    artifacts = {'orchestrator': script, 'client': bench, 'fixture': host, 'observer': observer,
                 'fixture_payload': fixture_payload, **{v + '_payload': p for v, p in payloads.items()}}
    if any(v != 'windowserver' for v in variants):artifacts['dock_loader'] = dock_loader
    if 'windowserver' in variants:
        artifacts['windowserver_loader'] = ws_loader
        artifacts['mailbox_client'] = mailbox_client
    pins = {key: {'path': str(path), 'sha256': sha(path)} for key, path in artifacts.items()}
    output.mkdir(mode=0o755, parents=True, exist_ok=False);os.chown(output, account.pw_uid, account.pw_gid)
    admin_env = dict(os.environ, HOME=account.pw_dir, USER=args.admin, LOGNAME=args.admin)
    prefix = ['/usr/bin/sudo', '-u', args.admin, '--']
    processes, files = [], []
    receipt = {'schema': 1, 'status': 'preparing', 'pins': pins, 'variants': variants,
               'repeats': args.repeats, 'runs': [], 'runtimes_retained': [], 'cleanup': {}}
    fixture_dir = Path('/tmp') / ('iff-' + secrets.token_hex(4))
    manifest_path, fixture = fixture_dir / 'fixture.json', None
    ws_deadline = None
    awake_proc = None
    def interrupted(signum, frame):
        del signum, frame
        raise KeyboardInterrupt('comparison interrupted; restoring only its disposable fixture')
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):signal.signal(signum, interrupted)

    def command(argv, label, admin=False, timeout=20):
        argv = [str(x) for x in argv]
        proc = subprocess.Popen((prefix if admin else []) + argv, env=admin_env, cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:stdout, stderr = proc.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL);stdout, stderr = proc.communicate(timeout=3)
        save(output / (label + '.command.json'), {'argv': argv, 'admin': admin, 'returncode': proc.returncode,
                                                'interrupted_or_timed_out': timed_out})
        (output / (label + '.stdout')).write_text(stdout)
        (output / (label + '.stderr')).write_text(stderr)
        if proc.returncode or timed_out:
            raise RuntimeError(f'{label} failed ({proc.returncode}); inspect retained stdout/stderr')
        return stdout

    def launch(argv, label):
        log = (output / (label + '.log')).open('w');files.append(log)
        proc = subprocess.Popen(prefix + [str(x) for x in argv], cwd=root, env=admin_env,
                                stdout=log, stderr=log, start_new_session=True)
        processes.append(proc);return proc, output / (label + '.log')

    def wait_ready(proc, path, marker, timeout=10):
        until = time.monotonic() + timeout
        while time.monotonic() < until and proc.poll() is None:
            if path.exists() and marker in path.read_text():return
            time.sleep(.04)
        raise RuntimeError(f'{path.name} did not become ready; retain its log')

    def check_restored(label):
        code = ('import json,runpy,sys; b=runpy.run_path(sys.argv[1]); '
                'n=b["NativeReadback"](); f=json.load(open(sys.argv[2])); '
                'ok=n.restored(f); print(json.dumps({"independently_verified":ok})); sys.exit(0 if ok else 1)')
        command([sys.executable, '-c', code, bench, manifest_path], label, admin=True)

    def private_runtime(variant):
        runtime = Path(tempfile.mkdtemp(prefix='ifp-', dir='/tmp'))
        os.chmod(runtime, 0o700);os.chown(runtime, account.pw_uid, account.pw_gid)
        receipt['runtimes_retained'].append(str(runtime));save(output / 'receipt.json', receipt)
        payload_directory = runtime
        if variant == 'windowserver':
            # Existing guest policy permits executable GPU bundle mappings and
            # temporary socket writes at different paths. No sandbox edits.
            bundles = Path('/Library/GPUBundles')
            if not bundles.exists():
                bundles.mkdir(mode=0o755)
                receipt['gpu_bundles_directory_created'] = True
            payload_directory = Path(tempfile.mkdtemp(prefix='InfinifyPerf-', dir=str(bundles)))
            os.chmod(payload_directory, 0o700)
            os.chown(payload_directory, account.pw_uid, account.pw_gid)
            receipt.setdefault('payload_directories_retained', []).append(str(payload_directory))
            save(output / 'receipt.json', receipt)
        payload = payload_directory / 'payload-arm64e.dylib'
        command(['/bin/cp', payloads[variant], payload], 'copy-' + variant, admin=True)
        command(['/bin/chmod', '0500', payload], 'mode-' + variant, admin=True)
        if sha(payload) != pins[variant + '_payload']['sha256']:
            raise RuntimeError('private runtime payload differs from pinned artifact')
        return runtime, payload

    try:
        # Balanced process-owned assertions only: keep this disposable guest
        # awake while measuring, without changing any power/display preference.
        awake_argv = ['/usr/bin/caffeinate', '-d', '-i', '-u', '-w', str(os.getpid())]
        awake_proc, _ = launch(awake_argv, 'display-activity')
        receipt['display_activity_assertion'] = {'argv': awake_argv, 'pid': awake_proc.pid,
                                                'settings_changed': False, 'ended': False}
        awake_until = time.monotonic() + 6;attempt = 0
        while True:
            attempt += 1
            env = json.loads(command([sys.executable, script, '--environment-only'],
                                     f'environment-{attempt:02d}', admin=True))
            receipt['display_state'] = env
            if (env['active_display_count'] > 0
                    and env['awake_active_display_count'] == env['active_display_count']):break
            if awake_proc.poll() is not None or time.monotonic() >= awake_until:
                raise RuntimeError('no awake active guest display after temporary activity assertion')
            time.sleep(.1)
        env['common_pins'] = pins;save(output / 'environment.json', env)
        command([sys.executable, bench, 'trace', '--hz', '60', '--seconds', '2', '--pan-points', args.pan_points,
                 '--kind', args.trace_kind, '--output', output / 'trace.json'], 'trace', admin=True)
        supervisor, fixture_log = launch([sys.executable, bench, 'fixture', '--live-owned-fixture',
            '--host', host, '--payload', fixture_payload, '--windows', args.windows, '--size', '480x320',
            '--hold-seconds', '300', '--output', fixture_dir], 'fixture')
        wait_ready(supervisor, fixture_log, 'fixture_manifest')
        fixture = json.loads(manifest_path.read_text());receipt['fixture_manifest'] = str(manifest_path)
        save(output / 'fixture.json', fixture);receipt['trace_sha256'] = sha(output / 'trace.json')
        if fixture['uid'] != account.pw_uid or fixture['host_sha256'] != pins['fixture']['sha256']:
            raise RuntimeError('fixture supervisor produced an unexpected user/executable')
        nonce = fixture['host_nonce_file'];check_restored('initial-restoration')
        endpoints = {}
        for variant in variants:
            if variant == 'windowserver':continue
            identity = json.loads(command([dock_loader, '--dock-identity'], 'dock-identity-' + variant))
            if identity['uid'] != account.pw_uid:raise RuntimeError('Dock belongs to another login user')
            runtime, payload = private_runtime(variant)
            command([dock_loader, '--inject-dock', payload, runtime, '--nonce-file', nonce,
                     '--only-pid', fixture['pid'], '--expected-dock', identity['pid'], identity['birth_sec'],
                     identity['birth_usec']], 'load-' + variant)
            endpoints[variant] = (runtime, identity['pid'], identity['uid'])
        if 'windowserver' in variants:
            identity = json.loads(command([ws_loader, '--preflight'], 'windowserver-preflight'))
            runtime, payload = private_runtime('windowserver');ws_deadline = time.monotonic() + 60
            command([ws_loader, '--inject-windowserver', payload, runtime, '--fixture', manifest_path,
                     '--nonce-file', nonce, '--lifetime-ms', '60000', '--expected-server', identity['server_pid'],
                     identity['server_birth_sec'], identity['server_birth_usec']], 'load-windowserver')
            endpoints['windowserver'] = (runtime, identity['server_pid'], identity['server_uid'])
        receipt['status'] = 'measuring';save(output / 'receipt.json', receipt)
        for repeat in range(args.repeats):
            round_reports = []
            for variant in variants if repeat % 2 == 0 else reversed(variants):
                if ws_deadline and time.monotonic() + 9 >= ws_deadline:
                    raise RuntimeError('insufficient WindowServer lifetime remains for another full run/restoration')
                label = f'{repeat + 1:02d}-{variant}';run_dir = output / label;raw = output / (label + '.pixels.jsonl')
                pixel_proc, pixel_log = launch([observer, manifest_path, raw, '60', '10'], label + '-observer')
                try:
                    wait_ready(pixel_proc, pixel_log, 'READY fixture-only display observer', timeout=8)
                    if ws_deadline and time.monotonic() + 6 >= ws_deadline:
                        raise RuntimeError('observer startup exhausted the remaining full-run/restoration budget')
                    runtime, pid, uid = endpoints[variant]
                    argv = [sys.executable, bench, 'run', '--live-owned-fixture', '--runtime', runtime,
                            '--nonce-file', nonce, '--server-pid', pid, '--server-uid', uid,
                            '--fixture-manifest', manifest_path, '--trace', output / 'trace.json',
                            '--variant', variant, '--output', run_dir, '--sample-hz', '120',
                            '--environment', output / 'environment.json']
                    for key, path in artifacts.items():argv += ['--artifact', key + '=' + str(path)]
                    if variant == 'windowserver':argv += ['--mailbox-client', mailbox_client]
                    command(argv, label + '-run', admin=True)
                finally:
                    if pixel_proc.poll() is None:os.killpg(pixel_proc.pid, signal.SIGTERM)
                    pixel_proc.wait(timeout=5)
                check_restored(label + '-restoration')
                report = json.loads((run_dir / 'run.json').read_text())
                if report['status'] != 'measured_control_path' or not report['restoration']['independently_verified']:
                    raise RuntimeError('run failed or independent restoration was not established')
                command([sys.executable, bench, 'decode-pixels', '--run-dir', run_dir,
                         '--fixture-manifest', manifest_path, '--raw-pixels', raw,
                         '--output', run_dir / 'decoded-pixels.jsonl'], label + '-decode', admin=True)
                round_reports.append(run_dir / 'run.json');receipt['runs'].append(str(run_dir / 'run.json'))
                save(output / 'receipt.json', receipt)
            if len(round_reports) > 1:
                command([sys.executable, bench, 'compare', *round_reports, '--output',
                         output / f'comparison-{repeat + 1:02d}.json'], f'compare-{repeat + 1:02d}', admin=True)
        receipt['status'] = 'measured'
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        receipt['status'] = 'failed';receipt['error'] = f'{type(error).__name__}: {error}'
    finally:
        if fixture:
            try:
                check_restored('final-restoration');receipt['cleanup']['independent_restoration'] = True
            except Exception as error:
                receipt['cleanup']['independent_restoration'] = False;receipt['cleanup']['error'] = str(error)
                receipt['status'] = 'failed'
            try:os.kill(fixture['supervisor_pid'], signal.SIGTERM)
            except ProcessLookupError:pass
        if awake_proc and awake_proc.poll() is None:
            try:os.killpg(awake_proc.pid, signal.SIGTERM)
            except ProcessLookupError:pass
        for proc in reversed(processes):
            if proc.poll() is None:
                try:
                    if not fixture:os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=6)
                except (subprocess.TimeoutExpired, ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL);proc.wait(timeout=3)
        for log in files:log.close()
        if awake_proc:receipt['display_activity_assertion']['ended'] = awake_proc.poll() is not None
        cleanup = fixture_dir / 'cleanup.json'
        try:
            fixture_cleanup = json.loads(cleanup.read_text())
            if not isinstance(fixture_cleanup, dict):
                raise ValueError('fixture cleanup receipt is not an object')
            receipt['cleanup']['fixture'] = fixture_cleanup
            if (fixture_cleanup.get('terminated') is not True
                    or fixture_cleanup.get('originals_verified_before_exit') is not True):
                receipt['status'] = 'failed'
        except (OSError, ValueError) as error:
            receipt['cleanup']['fixture_receipt_error'] = str(error)
            receipt['status'] = 'failed'
        save(output / 'receipt.json', receipt)
        print(json.dumps({'receipt': str(output / 'receipt.json'), 'status': receipt['status']}))
    return 0 if receipt['status'] == 'measured' else 1


if __name__ == '__main__':
    try:raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(f'NOT MEASURED: {error}', file=sys.stderr);raise SystemExit(1)
