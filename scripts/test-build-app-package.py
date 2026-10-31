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

        write(repo / "native/app/Resources/Info.plist", "plist\n")
        write(repo / "native/app/Resources/YABAI-NOTICE.txt", "upstream notice\n")
        write(repo / "native/app/Resources/SUNLIGHT-NOTICE.txt", "sunlight notice\n")
        write(repo / "LICENSE", "license\n")
        write(repo / "NOTICE", "notice\n")
        write(repo / "native/app/Resources/com.marengox.infinify.agent.plist", "agent\n")
        write(repo / "native/dock-helper/Daemon/com.marengox.infinify.loader.plist", "daemon\n")
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

                log = os.environ.get("PACKAGE_TEST_CODESIGN_LOG")
                if log:
                    with open(log, "a", encoding="utf-8") as handle:
                        handle.write(json.dumps(sys.argv[1:]) + "\\n")

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
                        target = Path(sys.argv[-1])
                        if target.is_file():
                            # A nested artifact signed on its own (the launch daemon, with an identity).
                            target.write_bytes(target.read_bytes() + b"|team-signed")
                        else:
                            executable = target / "Contents/MacOS/Infinify"
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
        adhoc_log = base / "codesign-adhoc.log"
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
            # The launch daemon carries the digests of the loader and payload it was built for.
            daemon = privileged / "loadd"
            daemon.write_bytes(
                b"daemon:"
                + hashlib.sha256((privileged / "loader-arm64e").read_bytes()).hexdigest().encode()
                + b":"
                + hashlib.sha256((privileged / "payload-arm64e.dylib").read_bytes()).hexdigest().encode()
            )
            daemon.chmod(0o755)
            if label == "first":
                stage_privileged_template = privileged
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
            env["PACKAGE_TEST_CODESIGN_LOG"] = str(adhoc_log)
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

        # An ad-hoc build is signed exactly as it always was: no hardened runtime, no entitlements.
        adhoc_calls = [json.loads(line) for line in adhoc_log.read_text(encoding="utf-8").splitlines()]
        if len(adhoc_calls) != 2 or any(call[:3] != ["--force", "--sign", "-"] or len(call) != 4 for call in adhoc_calls):
            raise AssertionError(f"an ad-hoc build is not signed as before: {adhoc_calls}")

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

        for resource, expected in (
            ("LICENSE", "license with attribution correction\n"),
            ("NOTICE", "notice\n"),
            ("SUNLIGHT-NOTICE.txt", "sunlight notice\n"),
            ("YABAI-NOTICE.txt", "upstream notice\n"),
        ):
            packaged = publish_dir / "Infinify.app/Contents/Resources" / resource
            if not packaged.is_file() or packaged.read_text(encoding="utf-8") != expected:
                raise AssertionError(f"the published bundle does not carry {resource}")

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

        if (publish_dir / "Infinify.app/Contents/Library/LaunchDaemons").exists():
            raise AssertionError("an ad-hoc build carries a launch daemon property list launchd would not run")
        daemon_artifact = publish_dir / "Infinify.app/Contents/Resources/NativeDesktop/loadd"
        if not daemon_artifact.is_file() or "daemon" not in native_manifest["artifacts"]:
            raise AssertionError("the launch daemon binary is not bound by the native manifest")

        mismatched_bundle = base / "mismatched-daemon.app"
        shutil.copytree(publish_dir / "Infinify.app", mismatched_bundle)
        mismatched_daemon = mismatched_bundle / "Contents/Resources/NativeDesktop/loadd"
        mismatched_daemon.write_bytes(b"a daemon built for other bytes")
        mismatched_manifest_path = mismatched_bundle / "Contents/Resources/NativeDesktop/manifest.plist"
        mismatched_manifest = plistlib.loads(mismatched_manifest_path.read_bytes())
        mismatched_manifest["artifacts"]["daemon"]["sha256"] = hashlib.sha256(mismatched_daemon.read_bytes()).hexdigest()
        mismatched_manifest_path.write_bytes(plistlib.dumps(mismatched_manifest, fmt=plistlib.FMT_XML, sort_keys=True))
        rejected = subprocess.run(
            [sys.executable, str(PACKAGE), "validate-bundle", "--bundle", str(mismatched_bundle)],
            cwd=ROOT,
            env=test_env,
            capture_output=True,
            text=True,
        )
        if rejected.returncode == 0:
            raise AssertionError("bundle validator accepted a launch daemon built for other loader and payload bytes")

        # With an identity, the bundle carries the daemon's property list and the daemon is signed on its own first.
        signed_stage = base / "signed-stage"
        signed_app = signed_stage / "Infinify.app"
        (signed_app / "Contents/MacOS").mkdir(parents=True)
        (signed_app / "Contents/MacOS/Infinify").write_bytes(b"signed-binary")
        (signed_app / "Contents/MacOS/Infinify").chmod(0o755)
        signed_privileged = signed_stage / "privileged"
        shutil.copytree(stage_privileged_template, signed_privileged)
        signed_snapshot = signed_stage / "source-before.json"
        run([sys.executable, str(PACKAGE), "snapshot", "--root", str(repo), "--output", str(signed_snapshot)], cwd=ROOT)
        signed_log = base / "codesign-signed.log"
        signed_env = dict(
            test_env,
            PACKAGE_TEST_CODESIGN_STATE=str(state_path),
            PACKAGE_TEST_CODESIGN_LOG=str(signed_log),
            INFINIFY_SIGN_IDENTITY="Test Identity",
        )
        run(
            [
                sys.executable, str(PACKAGE), "publish", "--root", str(repo), "--snapshot", str(signed_snapshot),
                "--staged-app", str(signed_app), "--privileged-dir", str(signed_privileged),
                "--app-dir", str(base / "signed-publish"),
            ],
            cwd=ROOT,
            env=signed_env,
        )
        # With an identity, the daemon and the bundle (whose executable is the daemon's one XPC caller) are signed with the hardened
        # runtime, and nothing is signed with an entitlement that gives the hardening back.
        signed_calls = [json.loads(line) for line in signed_log.read_text(encoding="utf-8").splitlines()]
        if len(signed_calls) != 2:
            raise AssertionError(f"an identity build did not sign exactly the daemon and the bundle: {signed_calls}")
        for call in signed_calls:
            if call[:5] != ["--force", "--sign", "Test Identity", "--options", "runtime"]:
                raise AssertionError(f"an identity build signed without the hardened runtime: {call}")
            if "--deep" in call or any("get-task-allow" in part or "disable-library-validation" in part for part in call):
                raise AssertionError(f"an identity build signed with a flag that weakens the hardened runtime: {call}")
        if "--identifier" not in signed_calls[0] or signed_calls[0][-1].endswith(".app"):
            raise AssertionError(f"the first signing step is not the daemon: {signed_calls[0]}")
        if not signed_calls[1][-1].endswith("Infinify.app"):
            raise AssertionError(f"the second signing step is not the bundle: {signed_calls[1]}")
        signed_bundle = base / "signed-publish/Infinify.app"
        if not (signed_bundle / "Contents/Library/LaunchDaemons/com.marengox.infinify.loader.plist").is_file():
            raise AssertionError("a build signed with an identity carries no launch daemon property list")
        signed_daemon = signed_bundle / "Contents/Resources/NativeDesktop/loadd"
        signed_manifest = plistlib.loads((signed_bundle / "Contents/Resources/NativeDesktop/manifest.plist").read_bytes())
        if not signed_daemon.read_bytes().endswith(b"|team-signed"):
            raise AssertionError("the launch daemon was not signed with the build identity")
        if hashlib.sha256(signed_daemon.read_bytes()).hexdigest() != signed_manifest["artifacts"]["daemon"]["sha256"]:
            raise AssertionError("the manifest binds the launch daemon before it was signed")
        if any("--timestamp" in call for call in signed_calls):
            raise AssertionError(f"a development build was timestamped, which needs the network: {signed_calls}")

        # A release build (INFINIFY_VERSION and INFINIFY_BUILD_NUMBER) carries that version and is timestamped for notarization.
        write(
            repo / "native/app/Resources/Info.plist",
            plistlib.dumps({"CFBundleIdentifier": "com.marengox.infinify", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}).decode(),
        )
        release_stage = base / "release-stage"
        release_app = release_stage / "Infinify.app"
        (release_app / "Contents/MacOS").mkdir(parents=True)
        (release_app / "Contents/MacOS/Infinify").write_bytes(b"release-binary")
        (release_app / "Contents/MacOS/Infinify").chmod(0o755)
        release_privileged = release_stage / "privileged"
        shutil.copytree(stage_privileged_template, release_privileged)
        release_snapshot = release_stage / "source-before.json"
        run([sys.executable, str(PACKAGE), "snapshot", "--root", str(repo), "--output", str(release_snapshot)], cwd=ROOT)
        release_log = base / "codesign-release.log"
        release_env = dict(signed_env, PACKAGE_TEST_CODESIGN_LOG=str(release_log), INFINIFY_VERSION="0.2.0", INFINIFY_BUILD_NUMBER="42")
        release_publish = [
            sys.executable, str(PACKAGE), "publish", "--root", str(repo), "--snapshot", str(release_snapshot),
            "--staged-app", str(release_app), "--privileged-dir", str(release_privileged),
            "--app-dir", str(base / "release-publish"),
        ]
        run(release_publish, cwd=ROOT, env=release_env)
        release_calls = [json.loads(line) for line in release_log.read_text(encoding="utf-8").splitlines()]
        if len(release_calls) != 2 or any(call[:6] != ["--force", "--sign", "Test Identity", "--options", "runtime", "--timestamp"] for call in release_calls):
            raise AssertionError(f"a release build was not signed with the hardened runtime and a timestamp: {release_calls}")
        release_info = plistlib.loads((base / "release-publish/Infinify.app/Contents/Info.plist").read_bytes())
        if (release_info.get("CFBundleShortVersionString"), release_info.get("CFBundleVersion")) != ("0.2.0", "42"):
            raise AssertionError(f"a release build does not carry its version: {release_info}")
        if release_info.get("CFBundleIdentifier") != "com.marengox.infinify":
            raise AssertionError("stamping the version lost the rest of Info.plist")
        for bad_version, bad_build in (("0.2", "42"), ("0.2.0", ""), ("v0.2.0", "42"), ("0.2.0", "0")):
            rejected = subprocess.run(
                release_publish[:-1] + [str(base / "rejected-release-publish")],
                cwd=ROOT,
                env=dict(release_env, INFINIFY_VERSION=bad_version, INFINIFY_BUILD_NUMBER=bad_build),
                capture_output=True,
                text=True,
            )
            if rejected.returncode == 0 or (base / "rejected-release-publish/Infinify.app").exists():
                raise AssertionError(f"a release build accepted version {bad_version!r} build {bad_build!r}")

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
        raise SystemExit(1) from None
