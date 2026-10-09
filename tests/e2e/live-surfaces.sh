#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-surfaces.sh
python3 - "${1:-target/surfaces/evidence}" <<'PY'
import json, os, pathlib, signal, subprocess, sys, tempfile, time

base = pathlib.Path(sys.argv[1]).resolve()
base.mkdir(parents=True, exist_ok=True)
run = pathlib.Path(tempfile.mkdtemp(prefix='run-', dir=base))
binary = pathlib.Path('target/surfaces/surfaces').resolve()
results = {'evidence': str(run), 'checks': [], 'scope': 'cooperative_layers_only', 'input_proven': False}

def load(path):
    return json.loads(path.read_text())

def gone(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True

def await_file(path, child, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return load(path)
        assert child.poll() is None, ('early exit', child.returncode, str(path))
        time.sleep(.03)
    raise AssertionError(('missing receipt', str(path)))

def launch(name, mode='--host', duration=10):
    directory = run / name
    directory.mkdir()
    child = subprocess.Popen([str(binary), mode, str(directory), str(duration)])
    return directory, child

children = []
try:
    directory, child = launch('pixels', duration=6)
    children.append(child)
    assert child.wait(timeout=15) == 0
    receipt = load(directory / 'receipt.json')
    assert receipt['screen_capture_preflight'], 'Pixel verification needs existing screen capture access; no prompt was requested'
    assert receipt['source_reaped'] and receipt['source_exit_status'] == 0
    assert gone(receipt['host_pid']) and gone(receipt['source_pid'])
    assert not receipt['arbitrary_app_window_hosting_proven'] and not receipt['input_proven']
    assert receipt['permission_requests'] == receipt['unrelated_window_mutation_calls'] == 0
    frames = receipt['frames']
    assert len(frames) >= 4, receipt
    phases = [set(), set()]
    for frame in frames:
        assert [frame['width'], frame['height']] == [800, 360]
        current = []
        for index, view in enumerate(frame['views']):
            expected_marker = ([80,90,50,40], [490,80,75,60])[index]
            expected_panel = ([200,120,100,80], [670,125,90,120])[index]
            assert view['green_bounds'] == expected_marker, view
            assert view['changing_bounds'] == expected_panel, view
            assert view['green_pixels'] >= (1990,4490)[index], view
            assert view['colored_pixels_outside_clip'] == 0, view
            minimum = (7980,10780)[index]
            if view['red_pixels'] >= minimum and view['blue_pixels'] == 0:
                phase = 'red'
            elif view['blue_pixels'] >= minimum and view['red_pixels'] == 0:
                phase = 'blue'
            else:
                raise AssertionError(('incomplete live panel', view))
            phases[index].add(phase)
            current.append(phase)
        assert current[0] == current[1], ('copies differ in same captured frame', frame)
    assert phases == [{'red','blue'}, {'red','blue'}], phases
    results['checks'].append('two live remote copies: red and blue observed in both; distinct exact pan/zoom geometry; actual right-edge clipping')
    results['checks'].append('host deadline: own window closed and source reaped')

    for sig in (signal.SIGTERM, signal.SIGINT):
        directory, child = launch(sig.name)
        children.append(child)
        ready = await_file(directory / 'source.json', child)
        time.sleep(.4)
        child.send_signal(sig)
        assert child.wait(timeout=5) == 0
        receipt = load(directory / 'receipt.json')
        assert receipt['signal'] == sig and receipt['exit_reason'] == 'signal', receipt
        assert receipt['source_reaped'] and receipt['source_exit_status'] == 0, receipt
        assert gone(ready['pid']) and gone(child.pid)
        assert load(directory / 'source-exit.json')['reason'] == 'signal'
        results['checks'].append(f'{sig.name}: host exited, exact source reaped')

    directory, child = launch('source-deadline', mode='--source', duration=1)
    children.append(child)
    assert child.wait(timeout=5) == 0
    assert load(directory / 'source-exit.json')['reason'] == 'deadline'
    results['checks'].append('source has its own bounded deadline')

    directory, child = launch('host-SIGKILL')
    children.append(child)
    ready = await_file(directory / 'source.json', child)
    child.kill()
    assert child.wait(timeout=5) == -signal.SIGKILL
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and (not (directory / 'source-exit.json').exists() or not gone(ready['pid'])):
        time.sleep(.05)
    assert load(directory / 'source-exit.json')['reason'] == 'parent_exit'
    assert gone(ready['pid']), 'source remained after parent SIGKILL'
    results['checks'].append('host SIGKILL: source detected parent loss and exited')
    results['passed'] = True
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    (run / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
PY
