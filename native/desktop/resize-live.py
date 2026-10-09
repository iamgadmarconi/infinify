#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit bounded supervisor; never invoke from the default headless test path."""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
EDGES = ('top_left', 'top', 'top_right', 'right', 'bottom_right', 'bottom', 'bottom_left', 'left')
NORMAL = tuple(f'{e}-{a}' for e in EDGES for a in ('grow', 'shrink', 'clamp')) + ('static',)
ABNORMAL = {'sigint': signal.SIGINT, 'sigterm': signal.SIGTERM, 'controller-death': signal.SIGKILL}


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def run(scenario, directory):
    directory.mkdir(mode=0o700)
    interrupted = False
    # Keep the native entry's empty-directory admission invariant. The private
    # anonymous log is published only after the controller has exited/reaped.
    log = tempfile.TemporaryFile()
    proc = subprocess.Popen([str(APP), '--owned-resize-probe', str(directory), scenario],
                            stdout=subprocess.DEVNULL, stderr=log)
    start = time.monotonic()
    signalled = False
    timed_out = False
    restoration_readback = {}
    try:
        while proc.poll() is None:
            checkpoint = read(directory / 'signal-ready.json')
            if scenario in ABNORMAL and checkpoint.get('pid') == proc.pid and not signalled:
                # Popen still owns this unreaped direct child; no arbitrary PID enrolment.
                proc.send_signal(ABNORMAL[scenario])
                signalled = True
            if time.monotonic() - start > 29:
                timed_out = True
                proc.terminate()  # no fixture hard-kill / fabricated restoration proof
                break
            time.sleep(.04)
    except KeyboardInterrupt:
        interrupted = True
        proc.send_signal(signal.SIGINT)
    finally:
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()  # only our unreaped controller child; this run remains failed
            proc.wait()
        # Watchdog deadline is 25 seconds from controller start. Give the fixture
        # its own cleanup interval; do not kill it to manufacture an exit receipt.
        end = start + 29
        cleanup = {}
        first_check = True
        while first_check or time.monotonic() < end:
            first_check = False
            if scenario == 'controller-death' and (directory / 'restored.json').exists() and not restoration_readback.get('independent_restoration'):
                try:
                    readback = subprocess.run([str(APP), '--owned-resize-check-restoration', str(directory)],
                                              text=True, capture_output=True, timeout=2)
                    restoration_readback = json.loads(readback.stdout)
                except (subprocess.TimeoutExpired, ValueError, OSError) as error:
                    restoration_readback = {'error': type(error).__name__}
                if restoration_readback.get('independent_restoration'):
                    (directory / 'close').touch()
            try:
                check = subprocess.run([str(APP), '--owned-resize-check-cleanup', str(directory)],
                                       text=True, capture_output=True, timeout=2)
                cleanup = json.loads(check.stdout)
            except (subprocess.TimeoutExpired, ValueError, OSError) as error:
                cleanup = {'error': type(error).__name__}
                timed_out = True
            if cleanup.get('fixture_process_and_windows_gone'):
                break
            if not (directory / 'identity.json').exists() and proc.poll() is not None:
                break
            time.sleep(.1)
        log.seek(0)
        (directory / 'stderr.txt').write_bytes(log.read())
        log.close()
        # A killed controller cannot suppress its screenshots or scrub its lease.
        if interrupted or scenario in ABNORMAL or timed_out:
            for name in ('before.png', 'after.png'):
                (directory / name).unlink(missing_ok=True)
        for name in ('lease.json', 'intent.json', 'ready.json'):
            (directory / name).unlink(missing_ok=True)
    native = read(directory / 'receipt.json')
    fixture = read(directory / 'fixture-exit.json')
    restoration = read(directory / 'restored.json')
    clean = (cleanup.get('fixture_process_and_windows_gone') is True
             and fixture.get('restored') is True and fixture.get('contaminated') is False
             and fixture.get('closed_owned_windows') is True
             and restoration.get('transform_unchanged') is True)
    pixels = None
    if scenario in NORMAL and proc.returncode == 0 and native.get('native_passed'):
        verified = subprocess.run([sys.executable, str(ROOT / 'native/desktop/resize-verify.py'),
                                   str(directory)], check=False)
        pixels = verified.returncode == 0
    abnormal = scenario in ABNORMAL
    restored_independently = (restoration_readback.get('independent_restoration') is True
                              if scenario == 'controller-death' else native.get('restoration_independently_verified') is True)
    passed = not interrupted and not timed_out and clean and restored_independently and (
        signalled and proc.returncode == (-signal.SIGKILL if scenario == 'controller-death' else 2)
        if abnormal else proc.returncode == 0 and native.get('native_passed') and
        (native.get('family_refused') if scenario == 'family' else pixels is True))
    result = {'scenario': scenario, 'passed': bool(passed), 'controller_exit': proc.returncode,
              'cleanup': cleanup, 'fixture_receipt': fixture, 'timed_out': timed_out,
              'interrupted': interrupted, 'abnormal_signal_sent': signalled,
              'pixels_passed': pixels, 'native_rendering_proved': bool(passed and not abnormal and pixels),
              'restoration_independently_verified': restored_independently,
              'supervisor_restoration_readback': restoration_readback,
              'cleanup_proved': clean,
              'restoration_status': 'independent AX/CG + transform verified' if restored_independently else 'UNPROVED; fixture receipt and disappearance are insufficient'}
    inputs = list((ROOT / 'native/desktop').glob('*.m')) + list((ROOT / 'native/desktop').glob('*.h'))
    inputs += [ROOT / 'native/captured-windows/captured.m', ROOT / 'native/resize/resize.m',
               ROOT / 'native/desktop/resize-verify.py', Path(__file__), ROOT / 'scripts/build-app.sh',
               ROOT / 'native/resize/resize.h', ROOT / 'native/families/window-server-family.h']
    result['build_attestation'] = read(ROOT / 'target/resize/native-probe-headless.json')
    result['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted(set(inputs))}
    (directory / 'supervisor.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'directory': str(directory), **result}, indent=2))
    return bool(passed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-owned-fixture', action='store_true', required=True)
    parser.add_argument('--scenario', choices=NORMAL + tuple(ABNORMAL) + ('family', 'matrix'), default='right-shrink')
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    attestation = read(ROOT / 'target/resize/native-probe-headless.json')
    try:
        matching = attestation.get('native_runtime') == 'UNRUN' and bool(attestation.get('source_sha256'))
        matching &= hashlib.sha256(APP.read_bytes()).hexdigest() == attestation.get('executable_sha256')
        matching &= all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected
                        for name, expected in attestation.get('source_sha256', {}).items())
    except OSError:
        matching = False
    if not matching:
        parser.error('current signed app/source attestation missing or stale; run the default safe harness first')
    base = args.directory or Path(tempfile.mkdtemp(prefix='infinify-resize-'))
    base = base.resolve()
    if args.directory:
        base.mkdir(mode=0o700, parents=False, exist_ok=True)
        if list(base.iterdir()):
            parser.error('evidence directory must be empty')
    scenarios = NORMAL + ('family',) + tuple(ABNORMAL) if args.scenario == 'matrix' else (args.scenario,)
    all_passed = True
    for scenario in scenarios:
        if not run(scenario, base / scenario):
            all_passed = False
            break  # no subsequent native work after a failed/interrupted session
    return 0 if all_passed else 2


if __name__ == '__main__':
    raise SystemExit(main())
