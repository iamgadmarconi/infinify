# SPDX-License-Identifier: GPL-3.0-or-later
"""Opt-in owned native focus gate. Python owns and reaps all three children."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--live-owned-focus', action='store_true')
parser.add_argument('--scenario', choices=['normal', 'signal', 'controller-death', 'deadline', 'partial-down-controller-death', 'bounds-before-readback', 'bounds-after-guard'], default='normal')
parser.add_argument('--evidence', default='target/focus/evidence')
args = parser.parse_args()
if not args.live_owned_focus:
    parser.error('live activation is disabled; explicit --live-owned-focus is required')

probe = Path('target/focus/probe').resolve()
fixture = Path('target/focus/fixture').resolve()
def load(path):
    return json.loads(path.read_text())

def wait_for(path, child, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return load(path)
        if child.poll() is not None:
            raise RuntimeError(f'child exited before {path.name}: {child.returncode}')
        time.sleep(.025)
    raise TimeoutError(path.name)

# Read-only before creating ordinary windows. Do not request missing permissions.
doctor = json.loads(subprocess.check_output([probe, '--doctor'], timeout=3))
if not all(doctor[k] for k in ['ax_trusted', 'listen_granted', 'private_ax_symbol']):
    raise SystemExit('Required pre-existing AX/listen access or exact AX identity symbol unavailable')
if doctor['idle_seconds'] < 3:
    raise SystemExit('Desktop active: no fixture launched (requires three idle seconds)')
base = Path(args.evidence).resolve()
base.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix='run-', dir=base))
os.chmod(run, 0o700)
private = run / 'private.json'
private.write_text(json.dumps({'key': secrets.token_hex(32), 'tag': secrets.randbits(51) + 1, 'prior': doctor['prior'], 'scenario': args.scenario}))
os.chmod(private, 0o600)
children = []
fixtures = []
handles = []
result = {'passed': False, 'scenario': args.scenario, 'live_focus_attempted': True, 'cleanup': []}

def launch(binary, *arguments):
    log = open(run / f'{binary.name}-{len(children)}.log', 'wb')
    handles.append(log)
    child = subprocess.Popen([binary, *arguments], stdout=log, stderr=subprocess.STDOUT)
    children.append(child)
    return child

def interrupted(signum, frame):
    raise InterruptedError(f'supervisor signal {signum}')
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)

try:
    for name in ('A', 'B'):
        child = launch(fixture, '--owned-fixture', str(run), name)
        fixtures.append((name, child))
        state = wait_for(run / f'{name}.json', child)
        assert state['pid'] == child.pid and len(state['windows']) == 2
        assert len({w['window'] for w in state['windows']}) == 2
    controller = launch(probe, '--run-owned', str(run))
    # proc birth comes from the fixture's read-only helper mode, never guessed.
    # ps does not expose the microsecond identity used by the adapter.
    birth_data = json.loads(subprocess.check_output([probe, '--birth', str(controller.pid)], timeout=2))
    command = run / 'controller.tmp'
    command.write_text(json.dumps({'pid': controller.pid, 'birth': birth_data}))
    command.replace(run / 'controller.json')
    if args.scenario in ('signal', 'controller-death', 'deadline', 'partial-down-controller-death'):
        checkpoint = wait_for(run / 'checkpoint.json', controller, seconds=12)
        if args.scenario == 'partial-down-controller-death':
            assert checkpoint['partial_down_native_tracking']
            assert len(checkpoint['sent']) == 1 and checkpoint['sent'][0]['type'] == 1
        if args.scenario == 'signal':
            controller.send_signal(signal.SIGINT)
        elif args.scenario in ('controller-death', 'partial-down-controller-death'):
            controller.kill()
    status = controller.wait(timeout=20)
    result['controller_status'] = status
    if args.scenario == 'normal':
        proof = load(run / 'probe.json')
        assert status == 0 and proof['passed'], proof.get('guard_failure')
        assert len(proof['steps']) == 6 and all(proof['invalid_identity_rejection'])
        assert all(s['native_key_window'] and s['event_target_mapping'] and s['controls_proven'] for s in proof['steps'])
        assert proof['pointer_unchanged'] and not proof['foreign_input'] and not proof['tap_lost']
    elif args.scenario in ('controller-death', 'partial-down-controller-death'):
        assert status == -signal.SIGKILL
        if args.scenario == 'partial-down-controller-death':
            # Require independent fixture watchdog completion before any teardown signal.
            for name, child in fixtures:
                assert child.wait(timeout=3) == 0
            receipt = load(run / 'A-exit.json')
            assert receipt['native_tracking_entered'] and receipt['tracking_watchdog_wake']
            assert receipt['teardown_releases_accepted'] == 1 and receipt['foreign_events'] == 0
    elif args.scenario.startswith('bounds-'):
        proof = load(run / 'probe.json')
        assert status == 2 and not proof['passed'] and proof['bounds_race_rejected']
        assert proof['race_window_moved'] and proof['race_controls_and_events_unchanged'] and proof['sent'] == []
        assert not proof['foreign_input'] and not proof['tap_lost'] and proof['pointer_unchanged']
    else:
        proof = load(run / 'probe.json')
        assert status == 2 and not proof['passed']
        if args.scenario == 'signal':
            assert proof['signal'] == signal.SIGINT
        else:
            assert proof['guard_failure'] == 'deadline'
    result['gate_expected_outcome'] = True
except BaseException as exc:
    result['error'] = f'{type(exc).__name__}: {exc}'
finally:
    # Stop handling repeated termination only while bounded cleanup runs.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        result['cleanup'].append({'pid': child.pid, 'reaped': child.poll() is not None, 'status': child.returncode})
    restores = []
    for name, child in fixtures:
        path = run / f'{name}-exit.json'
        receipt = load(path) if path.exists() else {}
        restores.append(bool(receipt.get('controls_restored')) and child.returncode == 0)
    result['all_owned_controls_restored'] = len(restores) == 2 and all(restores)
    result['passed'] = bool(result.get('gate_expected_outcome')) and result['all_owned_controls_restored'] and all(c['reaped'] for c in result['cleanup'])
    private.unlink(missing_ok=True)  # HMAC key never retained in evidence.
    for handle in handles:
        handle.close()
    sources = sorted(Path('native/focus').glob('*')) + [Path('scripts/build-focus.sh'), Path('tests/e2e/native-focus.sh')]
    result['source_sha256'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
    (run / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'run': str(run), **result}, indent=2))
raise SystemExit(0 if result['passed'] else 1)
