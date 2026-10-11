#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Isolated regression for concurrent app-bundle publication."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "scripts/build-app-package.py"


def run(args: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(args, cwd=cwd, env=env, check=True)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="infinify-package-lock-test-") as temp:
        base = Path(temp)
        repo = base / "source"
        publish_root = base / "publish"
        fake_bin = base / "bin"
        state_path = base / "codesign-state.json"
        repo.mkdir()
        publish_root.mkdir()
        fake_bin.mkdir()

        write(repo / "native/desktop/Info.plist", "plist\n")
        write(repo / "native/families/YABAI-NOTICE.txt", "upstream notice\n")
        write(repo / "LICENSE", "license\n")
        write(repo / "NOTICE", "notice\n")
        write(repo / "native/desktop/com.marengox.infinify.agent.plist", "agent\n")
        run(["git", "init", "--quiet"], cwd=repo)
        run(["git", "config", "user.name", "Packaging Test"], cwd=repo)
        run(["git", "config", "user.email", "packaging-test@example.invalid"], cwd=repo)
        run(["git", "add", "."], cwd=repo)
        run(["git", "commit", "--quiet", "-m", "packaging test sources"], cwd=repo)

        fake_codesign = fake_bin / "codesign"
        write(
            fake_codesign,
            "#!/usr/bin/env python3\n"
            + textwrap.dedent(
                """\
                import fcntl
                import json
                import os
                from pathlib import Path
                import sys
                import time

                state_path = Path(os.environ["PACKAGE_TEST_CODESIGN_STATE"])
                with state_path.open("a+", encoding="utf-8") as state:
                    fcntl.flock(state, fcntl.LOCK_EX)
                    state.seek(0)
                    data = json.loads(state.read() or "{}")
                    data["active"] = data.get("active", 0) + 1
                    data["maximum"] = max(data.get("maximum", 0), data["active"])
                    state.seek(0)
                    state.truncate()
                    json.dump(data, state)
                    state.flush()
                    fcntl.flock(state, fcntl.LOCK_UN)

                try:
                    time.sleep(0.15)
                    if "--force" in sys.argv:
                        executable = Path(sys.argv[-1]) / "Contents/MacOS/Infinify"
                        executable.write_bytes(executable.read_bytes() + b"|codesigned")
                finally:
                    with state_path.open("r+", encoding="utf-8") as state:
                        fcntl.flock(state, fcntl.LOCK_EX)
                        data = json.loads(state.read() or "{}")
                        data["active"] -= 1
                        state.seek(0)
                        state.truncate()
                        json.dump(data, state)
                        state.flush()
                        fcntl.flock(state, fcntl.LOCK_UN)
                """
            ),
        )
        fake_codesign.chmod(0o755)

        publish_dir = publish_root / "app"
        children: list[subprocess.Popen[str]] = []
        for label in ("first", "second"):
            stage = publish_root / f"stage-{label}"
            app = stage / "Infinify.app"
            executable = app / "Contents/MacOS/Infinify"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(f"{label}-binary".encode())
            snapshot = stage / "source-before.json"
            run(
                [
                    sys.executable,
                    str(PACKAGE),
                    "snapshot",
                    "--root",
                    str(repo),
                    "--output",
                    str(snapshot),
                ],
                cwd=ROOT,
            )
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
            env["PACKAGE_TEST_CODESIGN_STATE"] = str(state_path)
            children.append(
                subprocess.Popen(
                    [
                        sys.executable,
                        str(PACKAGE),
                        "publish",
                        "--root",
                        str(repo),
                        "--snapshot",
                        str(snapshot),
                        "--staged-app",
                        str(app),
                        "--app-dir",
                        str(publish_dir),
                    ],
                    cwd=ROOT,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
            )

        results = [child.communicate(timeout=30) + (child.returncode,) for child in children]
        for stdout, stderr, returncode in results:
            if returncode:
                raise RuntimeError(f"publisher failed ({returncode})\n{stdout}{stderr}")

        executable = publish_dir / "Infinify.app/Contents/MacOS/Infinify"
        manifest = json.loads((publish_dir / "BUILD.json").read_text(encoding="utf-8"))
        actual_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
        if manifest["executable_sha256"] != actual_hash:
            raise AssertionError("published BUILD.json does not describe the published executable")
        if executable.read_bytes() not in (b"first-binary|codesigned", b"second-binary|codesigned"):
            raise AssertionError("the published executable is incomplete or mixed")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state["maximum"] != 1 or state["active"] != 0:
            raise AssertionError(f"publication transactions overlapped in codesign: {state}")
        if list(publish_root.glob(".infinify-backup.*")):
            raise AssertionError("a completed publication left a backup directory behind")
        print("PASS: concurrent publishers serialized and the final manifest matches the signed bundle")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError, RuntimeError, AssertionError) as error:
        print(f"test-build-app-package: {error}", file=sys.stderr)
        raise SystemExit(1)
