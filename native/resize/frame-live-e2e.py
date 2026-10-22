# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded real-AX frame restoration on one explicitly spawned AppKit fixture."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def load(path):
    return json.loads(path.read_text())


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] != "--live-owned-fixture":
        raise SystemExit("Usage: frame-live-e2e.py --live-owned-fixture [evidence-directory]")
    base = Path(sys.argv[2] if len(sys.argv) == 3 else ROOT / "target/resize/frame-live-evidence").resolve()
    base.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    fixture = ROOT / "target/resize/fixture"
    probe = ROOT / "target/resize/frame-live-probe"
    result = {"passed": False, "fixture_launched": False, "children_reaped": False,
              "settings_changed": False, "permission_requested": False, "optical_proof": False,
              "third_party_acceptance": False}
    child = None

    def interrupted(signum, _frame):
        raise InterruptedError(f"signal {signum}")

    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}

    def check(stage):
        completed = subprocess.run([str(probe), "--check"], capture_output=True, timeout=4)
        (run / f"{stage}.json").write_bytes(completed.stdout)
        (run / f"{stage}.stderr").write_bytes(completed.stderr)
        metadata = json.loads(completed.stdout)
        result.setdefault("preflight_checks", {})[stage] = {"exit_code": completed.returncode, "metadata": metadata}
        session = metadata.get("session", {})
        accepted = (completed.returncode == 0 and metadata.get("preflight_passed") is True
                    and metadata.get("accessibility_trusted") is True
                    and session.get("no_known_session_blocker") is True)
        if not accepted:
            reasons = list(session.get("blockers", []))
            if metadata.get("accessibility_trusted") is not True:
                reasons.append("existing_accessibility_authority_unavailable")
            result["blocked_stage"] = stage
            result["blocked"] = "; ".join(reasons) or "invalid_or_failed_preflight"
        return accepted

    try:
        if not check("preflight"):
            return 2
        child = subprocess.Popen([str(fixture), str(run), str(os.getpid())], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result["fixture_launched"] = True
        result["fixture_pid"] = child.pid
        deadline = time.monotonic() + 5
        while not (run / "ready.json").exists():
            assert child.poll() is None, "fixture exited before readiness"
            assert time.monotonic() < deadline, "fixture readiness timed out"
            time.sleep(.02)
        assert load(run / "ready.json")["pid"] == child.pid
        if not check("pre-mutation-preflight"):
            return 2
        completed = subprocess.run([str(probe), str(run / "ready.json"), str(child.pid)], capture_output=True, timeout=18)
        (run / "probe.json").write_bytes(completed.stdout)
        (run / "probe.stderr").write_bytes(completed.stderr)
        assert completed.returncode == 0, completed.stderr.decode() or completed.stdout.decode()
        proof = load(run / "probe.json")
        assert proof["passed"] and proof["independent_restoration_passed"]
        result["passed"] = True
    except Exception as error:
        result["failure"] = str(error)
    finally:
        # Ignore repeated termination only while the owned child restores its
        # original frames. The fixture also restores on parent death/deadline.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        if child:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Reap the fixture after allowing its 30-second watchdog to
                # execute; needing this fallback is still a failed scenario.
                result["passed"] = False
                result["failure"] = "fixture failed to finish bounded restoration after SIGTERM"
                result["watchdog_wait_required"] = True
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
                    result["forced_cleanup"] = True
                    result["failure"] = "fixture exceeded its restoration watchdog; forced termination, restoration unverified"
            result["children_reaped"] = child.poll() is not None
            if (run / "exit.json").exists():
                receipt = load(run / "exit.json")
                result["fixture_cleanup_passed"] = receipt["restoration_passed"] and receipt["restored"] == receipt["original"]
                result["fixture_before_cleanup_matches_original"] = receipt["before_restore"] == receipt["original"]
                result["passed"] &= result["fixture_cleanup_passed"] and result["fixture_before_cleanup_matches_original"]
            else:
                result["passed"] = False
                result["fixture_cleanup_passed"] = False
        else:
            result["children_reaped"] = True
        result["passed"] &= result["children_reaped"]
        result["environment"] = {
            "macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
            "build": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
            "architecture": subprocess.check_output(["uname", "-m"], text=True).strip(),
            "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        }
        files = [Path(__file__).resolve(), fixture, probe, ROOT / "native/resize/frame-live-probe.m",
                 ROOT / "native/resize/fixture.m", ROOT / "native/resize/resize.h", ROOT / "native/resize/resize.m",
                 ROOT / "tests/e2e/native-frame-restore-live.sh"]
        result["sha256"] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        (run / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"run": str(run), **result}, indent=2))
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
