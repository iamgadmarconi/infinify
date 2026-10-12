#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Isolated regression for concurrent app-bundle publication."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
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
        write(repo / ".gitignore", "/target/\n")
        write(repo / "scripts/native-desktop-launcher.sh", "#!/bin/sh\nexit 0\n")
        (repo / "scripts/native-desktop-launcher.sh").chmod(0o755)
        run(["git", "init", "--quiet"], cwd=repo)
        run(["git", "config", "user.name", "Packaging Test"], cwd=repo)
        run(["git", "config", "user.email", "packaging-test@example.invalid"], cwd=repo)
        run(["git", "config", "commit.gpgsign", "false"], cwd=repo)
        run(["git", "add", "."], cwd=repo)
        run(["git", "commit", "--quiet", "-m", "packaging test sources"], cwd=repo)

        # Porcelain puts untracked paths last, then moves them into path order
        # on staging. Source bytes and the package's dirty-path set stay equal.
        write(repo / "LICENSE", "license with attribution correction\n")
        write(repo / "A-new-source.txt", "new source\n")
        ordering = []
        for label in ("untracked", "staged"):
            if label == "staged":
                run(["git", "add", "A-new-source.txt"], cwd=repo)
            path = base / f"source-{label}.json"
            run([sys.executable, str(PACKAGE), "snapshot", "--root", str(repo), "--output", str(path)], cwd=ROOT)
            ordering.append(json.loads(path.read_text()))
        assert ordering[0] == ordering[1], "staging unchanged source changed package provenance"

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

                if "--verify" in sys.argv:
                    raise SystemExit(0)

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
            executable.chmod(0o755)
            privileged = stage / "privileged"
            privileged.mkdir()
            for filename in ("doctor", "loader-arm64e", "payload-arm64e.dylib"):
                artifact = privileged / filename
                artifact.write_bytes(f"{label}-{filename}-test-binary".encode())
                artifact.chmod(0o755)
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
                        "--privileged-dir",
                        str(privileged),
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
        if not (publish_dir / "BUILD.json").is_file():
            raise AssertionError(f"publishers exited without BUILD.json: {results}")
        manifest = json.loads((publish_dir / "BUILD.json").read_text(encoding="utf-8"))
        actual_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
        if manifest["executable_sha256"] != actual_hash:
            raise AssertionError("published BUILD.json does not describe the published executable")
        if executable.read_bytes() not in (b"first-binary|codesigned", b"second-binary|codesigned"):
            raise AssertionError("the published executable is incomplete or mixed")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state["maximum"] != 1 or state["active"] != 0:
            raise AssertionError(f"publication transactions overlapped in codesign: {state}")

        test_env = os.environ.copy()
        test_env["PATH"] = f"{fake_bin}{os.pathsep}{test_env.get('PATH', '')}"
        manifest_path = publish_dir / "BUILD.json"
        if manifest["schema_version"] != 2:
            raise AssertionError("published BUILD.json did not use schema 2")
        run(
            [sys.executable, str(PACKAGE), "validate-bundle", "--bundle", str(publish_dir / "Infinify.app")],
            cwd=ROOT,
            env=test_env,
        )
        repository_bundle = repo / "target/app/Infinify.app"
        repository_bundle.parent.mkdir(parents=True)
        shutil.copytree(publish_dir / "Infinify.app", repository_bundle)
        repository_manifest = repo / "target/app/BUILD.json"
        shutil.copy2(manifest_path, repository_manifest)
        run(
            [
                sys.executable,
                str(PACKAGE),
                "verify-source",
                "--root",
                str(repo),
                "--bundle",
                str(repository_bundle),
            ],
            cwd=ROOT,
            env=test_env,
        )
        changed_pre_sign_copy = base / "changed-pre-sign-copy.app"
        shutil.copytree(repository_bundle, changed_pre_sign_copy)
        changed_executable = changed_pre_sign_copy / "Contents/MacOS/Infinify"
        changed_executable.write_bytes(changed_executable.read_bytes() + b"changed-before-resign")
        rejected = subprocess.run(
            [
                sys.executable,
                str(PACKAGE),
                "verify-source",
                "--root",
                str(repo),
                "--bundle",
                str(changed_pre_sign_copy),
            ],
            cwd=ROOT,
            env=test_env,
            capture_output=True,
            text=True,
        )
        if rejected.returncode == 0:
            raise AssertionError("source verifier accepted a different app executable with the same helper manifest")
        native_manifest_path = publish_dir / "Infinify.app/Contents/Resources/NativeDesktop/manifest.plist"
        native_manifest = plistlib.loads(native_manifest_path.read_bytes())
        if hashlib.sha256(native_manifest_path.read_bytes()).hexdigest() != manifest["native_manifest_sha256"]:
            raise AssertionError("BUILD.json native manifest digest does not match the packaged plist")
        for name, entry in native_manifest["artifacts"].items():
            artifact = publish_dir / "Infinify.app" / entry["path"]
            if hashlib.sha256(artifact.read_bytes()).hexdigest() != entry["sha256"]:
                raise AssertionError(f"native manifest does not bind packaged {name} bytes")
        if hashlib.sha256((publish_dir / "Infinify.app/Contents/Resources/NativeDesktop/payload-arm64e.dylib").read_bytes()).hexdigest() != manifest["native_payload_sha256"]:
            raise AssertionError("BUILD.json native payload digest does not match the packaged payload")

        damaged_bundle = base / "damaged.app"
        shutil.copytree(publish_dir / "Infinify.app", damaged_bundle)
        damaged_payload = damaged_bundle / "Contents/Resources/NativeDesktop/payload-arm64e.dylib"
        damaged_payload.write_bytes(damaged_payload.read_bytes() + b"tamper")
        rejected = subprocess.run(
            [sys.executable, str(PACKAGE), "validate-bundle", "--bundle", str(damaged_bundle)],
            cwd=ROOT,
            env=test_env,
            capture_output=True,
            text=True,
        )
        if rejected.returncode == 0:
            raise AssertionError("bundle validator accepted payload bytes that differ from the manifest")

        legacy_path = base / "legacy-BUILD.json"
        legacy = dict(manifest, schema_version=1)
        legacy_path.write_text(json.dumps(legacy), encoding="utf-8")
        rejected = subprocess.run(
            [sys.executable, str(PACKAGE), "verify-source", "--root", str(repo), "--build-manifest", str(legacy_path)],
            cwd=ROOT,
            env=test_env,
            capture_output=True,
            text=True,
        )
        if rejected.returncode == 0:
            raise AssertionError("source verifier accepted legacy BUILD.json schema 1")

        if list(publish_root.glob(".infinify-backup.*")):
            raise AssertionError("a completed publication left a backup directory behind")
        print("PASS: concurrent publishers serialized; schema 2 binds the signed bundle and rejects tampered or legacy manifests")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError, RuntimeError, AssertionError) as error:
        print(f"test-build-app-package: {error}", file=sys.stderr)
        raise SystemExit(1)
