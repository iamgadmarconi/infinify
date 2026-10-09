# SPDX-License-Identifier: GPL-3.0-or-later
"""Only owned child fixtures; no activation, input injection or permissions prompts."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

base = Path(sys.argv[1]).resolve()
base.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix="run-", dir=base))
fixture = Path("target/resize/fixture").resolve()
probe = Path("target/resize/probe").resolve()
checks = []
children = []
result = {"passed": False, "checks": checks}


def load(path):
    return json.loads(path.read_text())


def launch(name):
    folder = run / name
    folder.mkdir()
    child = subprocess.Popen([str(fixture), str(folder), str(os.getpid())])
    children.append(child)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if (folder / "ready.json").exists():
            assert load(folder / "ready.json")["pid"] == child.pid
            return folder, child
        assert child.poll() is None, "fixture exited before ready"
        time.sleep(.02)
    raise AssertionError("fixture startup timed out")


def stop(folder, child, sig=signal.SIGTERM):
    child.send_signal(sig)
    assert child.wait(timeout=5) == 0
    receipt = load(folder / "exit.json")
    assert receipt["restoration_passed"]
    assert receipt["restored"] == receipt["original"]
    assert receipt["before_restore"][1:] == receipt["original"][1:]
    return receipt


try:
    folder, child = launch("resize")
    completed = subprocess.run([str(probe), str(folder / "ready.json")], capture_output=True, timeout=20)
    (folder / "probe.json").write_bytes(completed.stdout)
    if completed.stderr:
        (folder / "probe-error.txt").write_bytes(completed.stderr)
    receipt = stop(folder, child)
    assert completed.returncode == 0, completed.stderr.decode()
    proof = load(folder / "probe.json")
    assert proof["passed"]
    assert receipt["before_restore"][0][2:] == receipt["original"][0][2:], "adapter failed to restore size"
    assert receipt["before_restore"][0][:2] != receipt["original"][0][:2], "fixture relocation did not occur"
    checks.extend(["external AX and CG readback prove selected resize and minimum constraint", "non-settable decoy and ignored setter rejected", "wrong owner, stale birth, stale window and invalid sizes rejected without mutation", "same-title decoys unchanged; relocated identity resized; snapshot size restored before full fixture cleanup"])
    folder, child = launch("unresponsive")
    (folder / "block").touch()
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not (folder / "blocking.json").exists():
            time.sleep(.01)
        assert (folder / "blocking.json").exists()
        started = time.monotonic()
        completed = subprocess.run([str(probe), str(folder / "ready.json"), "--expect-unavailable"], capture_output=True, timeout=4)
        elapsed = time.monotonic() - started
        (folder / "probe.json").write_bytes(completed.stdout)
        assert completed.returncode == 0, completed.stderr.decode()
        assert elapsed < 3, elapsed
    finally:
        stop(folder, child)
    checks.append("unresponsive owned source times out without mutation in under three seconds")
    folder, child = launch("interrupt")
    stop(folder, child, signal.SIGINT)
    checks.append("SIGINT fixture restoration and child reap")
    # Hard-kill only the owned controller; fixture's parent watchdog restores and exits.
    folder = run / "parent-exit"
    folder.mkdir()
    supervisor = subprocess.Popen([sys.executable, "-c", "import subprocess,sys,time,os; subprocess.Popen([sys.argv[1],sys.argv[2],str(os.getpid())]); time.sleep(30)", str(fixture), str(folder)])
    children.append(supervisor)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not (folder / "ready.json").exists():
        time.sleep(.02)
    assert (folder / "ready.json").exists()
    abandoned = subprocess.run([str(probe), str(folder / "ready.json"), "--resize-once"], capture_output=True, timeout=5)
    (folder / "abandoned-resize.json").write_bytes(abandoned.stdout)
    assert abandoned.returncode == 0, abandoned.stderr.decode()
    supervisor.kill()
    assert supervisor.wait(timeout=3) == -signal.SIGKILL
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not (folder / "exit.json").exists():
        time.sleep(.02)
    orphan = load(folder / "exit.json")
    assert orphan["reason"] == "parent_exit" and orphan["restoration_passed"]
    assert orphan["before_restore"][0] != orphan["original"][0]
    assert orphan["before_restore"][1:] == orphan["original"][1:]
    orphan_pid = load(folder / "ready.json")["pid"]
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(orphan_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(.02)
    else:
        raise AssertionError("orphan fixture did not exit")
    checks.append("controller SIGKILL after an unrestored resize triggers owned fixture restoration and exit")
    result["passed"] = True
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    # PID/window IDs are disposable identity evidence, not credentials. No nonce/token is used.
    result["credentials_written"] = False
    sources = sorted(p for p in Path("native/resize").glob("*") if p.is_file()) + [Path("scripts/build-resize.sh"), Path("tests/e2e/native-resize.sh")]
    result["source_sha256"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (run / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"run": str(run), **result}, indent=2))
