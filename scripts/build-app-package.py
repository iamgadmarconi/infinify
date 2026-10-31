#!/usr/bin/env python3
"""Stage, verify, and atomically publish the macOS application bundle."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from collections.abc import Iterator


BUILD_SCHEMA_VERSION = 2
NATIVE_MANIFEST_SCHEMA_VERSION = 1
NATIVE_DESKTOP_RELATIVE = Path("Contents/Resources/NativeDesktop")
NATIVE_ARTIFACTS = {
    "doctor": "doctor",
    "loader": "loader-arm64e",
    "payload": "payload-arm64e.dylib",
    "daemon": "loadd",
    "launcher": "launch.sh",
}
LAUNCH_DAEMON_PLIST = "com.marengox.infinify.loader.plist"
DAEMON_IDENTIFIER = "com.marengox.infinify.loadd"
BUILD_MANIFEST_KEYS = {
    "schema_version",
    "git_commit",
    "built_at_utc",
    "dirty",
    "dirty_paths",
    "executable",
    "executable_sha256",
    "native_manifest_sha256",
    "native_payload_sha256",
    "source_fingerprint_sha256",
    "source_file_count",
    "source_sha256",
}
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
RELEASE_VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
RELEASE_BUILD_RE = re.compile(r"[1-9][0-9]*\Z")


def release_version() -> tuple[str, str] | None:
    """The version and build number of a release build (INFINIFY_VERSION and INFINIFY_BUILD_NUMBER, which
    scripts/build-release.sh sets), or None for a development build, which keeps the source Info.plist's version."""
    version = os.environ.get("INFINIFY_VERSION") or ""
    build = os.environ.get("INFINIFY_BUILD_NUMBER") or ""
    if not version and not build:
        return None
    if not RELEASE_VERSION_RE.fullmatch(version) or not RELEASE_BUILD_RE.fullmatch(build):
        raise RuntimeError("INFINIFY_VERSION must be MAJOR.MINOR.PATCH and INFINIFY_BUILD_NUMBER a positive integer, both or neither")
    return version, build


def codesign_command(identity: str, target: Path, *, identifier: str | None = None, entitlements: Path | None = None) -> list[str]:
    """The codesign call for one signing step. A build signed with an identity gets the hardened runtime (and only the entitlements
    its binary needs, normally none), so that a process of the same user cannot inject code into a running Infinify and borrow its
    identity to ask the launch daemon for a load; the daemon refuses a caller without the flag. A release build signed with an
    identity is also timestamped, as notarization requires; a development build is not, so it signs without the network. An
    ad-hoc build ("-") is signed exactly as it always was."""
    command = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        command += ["--options", "runtime"]
        if release_version() is not None:
            command.append("--timestamp")
    if identifier is not None:
        command += ["--identifier", identifier]
    if entitlements is not None:
        command += ["--entitlements", str(entitlements)]
    return command + [str(target)]


def run(args: list[str], *, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def source_state(root: Path) -> dict[str, object]:
    git_env = os.environ.copy()
    git_env["GIT_OPTIONAL_LOCKS"] = "0"
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        env=git_env,
    ).split(b"\0")
    sources: dict[str, dict[str, object]] = {}
    for raw_path in paths:
        if not raw_path:
            continue
        relative = os.fsdecode(raw_path)
        path = root / relative
        try:
            info = path.lstat()
        except FileNotFoundError:
            sources[relative] = {"state": "deleted"}
            continue
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            content = os.fsencode(os.readlink(path))
            kind = "symlink"
        elif stat.S_ISREG(info.st_mode):
            content = path.read_bytes()
            kind = "file"
        else:
            continue
        sources[relative] = {
            "kind": kind,
            "mode": mode,
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    status = subprocess.check_output(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
        env=git_env,
    ).decode("utf-8", errors="replace")
    # Git prints untracked paths after tracked changes. Staging an unchanged
    # new source must not invalidate a package merely by reordering this list.
    dirty_paths = sorted(line[3:] for line in status.splitlines() if line)
    commit = run(["git", "rev-parse", "HEAD"], cwd=root)
    serialized_sources = json.dumps(
        sources, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return {
        "commit": commit,
        "dirty": bool(dirty_paths),
        "dirty_paths": dirty_paths,
        "source_fingerprint_sha256": hashlib.sha256(serialized_sources).hexdigest(),
        "source_file_count": len(sources),
        "source_sha256": sources,
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def regular_file_digest(path: Path, *, executable: bool = False) -> str:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise RuntimeError(f"required package file is missing: {path}") from error
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f"package file must be a regular non-symlink file: {path}")
    if executable and not info.st_mode & 0o111:
        raise RuntimeError(f"package executable is not executable: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_desktop_dir(bundle: Path) -> Path:
    return bundle / NATIVE_DESKTOP_RELATIVE


def check_bundle_path(bundle: Path, relative: Path) -> Path:
    if bundle.is_symlink():
        raise RuntimeError(f"refusing an app bundle symlink: {bundle}")
    path = bundle
    for component in relative.parts:
        path /= component
        if path.is_symlink():
            raise RuntimeError(f"refusing a symlink in the app bundle: {path}")
    return path


def create_native_manifest(bundle: Path, source: dict[str, object]) -> dict[str, object]:
    directory = native_desktop_dir(bundle)
    artifacts: dict[str, dict[str, str]] = {}
    for name, filename in NATIVE_ARTIFACTS.items():
        relative = NATIVE_DESKTOP_RELATIVE / filename
        path = check_bundle_path(bundle, relative)
        artifacts[name] = {
            "path": str(Path("Contents/Resources/NativeDesktop") / filename),
            "sha256": regular_file_digest(path, executable=True),
        }
    manifest: dict[str, object] = {
        "schema_version": NATIVE_MANIFEST_SCHEMA_VERSION,
        "git_commit": source["commit"],
        "source_fingerprint_sha256": source["source_fingerprint_sha256"],
        "artifacts": artifacts,
    }
    path = directory / "manifest.plist"
    path.write_bytes(plistlib.dumps(manifest, fmt=plistlib.FMT_XML, sort_keys=True))
    os.chmod(path, 0o644)
    return manifest


def validate_native_bundle(
    bundle: Path,
    *,
    verify_signature: bool = True,
    verify_bundle_signature: bool = True,
) -> dict[str, object]:
    bundle = bundle.absolute()
    if not bundle.is_dir() or bundle.is_symlink():
        raise RuntimeError(f"app bundle is missing or is a symlink: {bundle}")
    manifest_path = check_bundle_path(bundle, NATIVE_DESKTOP_RELATIVE / "manifest.plist")
    if not stat.S_ISREG(manifest_path.lstat().st_mode):
        raise RuntimeError(f"native manifest must be a regular file: {manifest_path}")
    try:
        manifest = plistlib.loads(manifest_path.read_bytes())
    except (plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError(f"native manifest is invalid: {manifest_path}") from error
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema_version",
        "git_commit",
        "source_fingerprint_sha256",
        "artifacts",
    }:
        raise RuntimeError("native manifest has an unknown schema")
    if type(manifest.get("schema_version")) is not int or manifest["schema_version"] != NATIVE_MANIFEST_SCHEMA_VERSION:
        raise RuntimeError("native manifest has an unsupported schema version")
    if not isinstance(manifest.get("git_commit"), str) or not manifest["git_commit"]:
        raise RuntimeError("native manifest has no source commit")
    if not isinstance(manifest.get("source_fingerprint_sha256"), str) or not SHA256_RE.fullmatch(manifest["source_fingerprint_sha256"]):
        raise RuntimeError("native manifest has an invalid source fingerprint")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(NATIVE_ARTIFACTS):
        raise RuntimeError("native manifest artifact set is incomplete or unknown")
    for name, filename in NATIVE_ARTIFACTS.items():
        entry = artifacts[name]
        expected_relative = NATIVE_DESKTOP_RELATIVE / filename
        expected_path = str(Path("Contents/Resources/NativeDesktop") / filename)
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"} or entry.get("path") != expected_path:
            raise RuntimeError(f"native manifest has an invalid path entry for {name}")
        expected_hash = entry.get("sha256")
        if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
            raise RuntimeError(f"native manifest has an invalid SHA-256 for {name}")
        artifact = check_bundle_path(bundle, expected_relative)
        if not artifact.is_file() or regular_file_digest(artifact, executable=True) != expected_hash:
            raise RuntimeError(f"native package bytes do not match the manifest: {artifact}")
        if verify_signature and name in {"doctor", "loader", "payload", "daemon"}:
            subprocess.run(["codesign", "--verify", "--strict", str(artifact)], check=True)
    # The launch daemon carries the digests of the loader and payload it will run as root and have the Dock open. A daemon built
    # for other bytes would refuse every load; this catches that at packaging, without running any artifact.
    daemon_bytes = check_bundle_path(bundle, NATIVE_DESKTOP_RELATIVE / NATIVE_ARTIFACTS["daemon"]).read_bytes()
    for name in ("loader", "payload"):
        if artifacts[name]["sha256"].encode("ascii") not in daemon_bytes:
            raise RuntimeError(f"the launch daemon was not built for this bundle's {name} bytes")
    executable = check_bundle_path(bundle, Path("Contents/MacOS/Infinify"))
    regular_file_digest(executable, executable=True)
    if verify_signature and verify_bundle_signature:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    return manifest


def build_manifest_path(root: Path) -> Path:
    return root / "target/app/BUILD.json"


def load_build_manifest(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"BUILD.json is missing or is not a regular file: {path}")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RuntimeError(f"BUILD.json is invalid: {path}") from error
    if not isinstance(manifest, dict) or set(manifest) != BUILD_MANIFEST_KEYS:
        raise RuntimeError("BUILD.json has an unknown schema")
    if type(manifest.get("schema_version")) is not int or manifest["schema_version"] != BUILD_SCHEMA_VERSION:
        raise RuntimeError("BUILD.json has an unsupported schema version")
    if manifest.get("executable") != "Infinify.app/Contents/MacOS/Infinify":
        raise RuntimeError("BUILD.json names an unexpected executable")
    for key in ("executable_sha256", "native_manifest_sha256", "native_payload_sha256", "source_fingerprint_sha256"):
        if not isinstance(manifest.get(key), str) or not SHA256_RE.fullmatch(manifest[key]):
            raise RuntimeError(f"BUILD.json has an invalid {key}")
    return manifest


def verify_source(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    manifest_path = args.build_manifest or build_manifest_path(root)
    manifest = load_build_manifest(manifest_path)
    current = source_state(root)
    for manifest_key, source_key in (
        ("git_commit", "commit"),
        ("dirty", "dirty"),
        ("dirty_paths", "dirty_paths"),
        ("source_fingerprint_sha256", "source_fingerprint_sha256"),
        ("source_file_count", "source_file_count"),
        ("source_sha256", "source_sha256"),
    ):
        if manifest.get(manifest_key) != current[source_key]:
            raise RuntimeError("BUILD.json does not describe the current Git/source state")

    built_app = args.built_app or root / "target/app/Infinify.app"
    built_executable = check_bundle_path(built_app, Path("Contents/MacOS/Infinify"))
    if regular_file_digest(built_executable, executable=True) != manifest["executable_sha256"]:
        raise RuntimeError("the built app executable differs from BUILD.json")
    built_native = validate_native_bundle(built_app)
    built_native_path = check_bundle_path(built_app, NATIVE_DESKTOP_RELATIVE / "manifest.plist")
    if hashlib.sha256(built_native_path.read_bytes()).hexdigest() != manifest["native_manifest_sha256"]:
        raise RuntimeError("the built app native manifest differs from BUILD.json")
    if built_native["git_commit"] != current["commit"] or built_native["source_fingerprint_sha256"] != current["source_fingerprint_sha256"]:
        raise RuntimeError("the built app native manifest does not describe the current source")
    built_payload = check_bundle_path(built_app, NATIVE_DESKTOP_RELATIVE / NATIVE_ARTIFACTS["payload"])
    if regular_file_digest(built_payload, executable=True) != manifest["native_payload_sha256"]:
        raise RuntimeError("the built app payload differs from BUILD.json")

    selected_app = args.bundle or built_app
    selected_native = validate_native_bundle(selected_app)
    selected_executable = check_bundle_path(selected_app, Path("Contents/MacOS/Infinify"))
    if regular_file_digest(selected_executable, executable=True) != manifest["executable_sha256"]:
        raise RuntimeError("selected app executable differs from BUILD.json")
    selected_manifest_path = check_bundle_path(selected_app, NATIVE_DESKTOP_RELATIVE / "manifest.plist")
    if hashlib.sha256(selected_manifest_path.read_bytes()).hexdigest() != manifest["native_manifest_sha256"]:
        raise RuntimeError("selected app bundle does not match this build's native manifest")
    if selected_native["git_commit"] != manifest["git_commit"] or selected_native["source_fingerprint_sha256"] != manifest["source_fingerprint_sha256"]:
        raise RuntimeError("selected app bundle does not match this build's source identity")
    print(f"Verified source-fresh native app: {selected_app}")


def validate_package(args: argparse.Namespace) -> None:
    manifest = validate_native_bundle(args.bundle)
    if args.source_fingerprint and manifest["source_fingerprint_sha256"] != args.source_fingerprint:
        raise RuntimeError("native app source fingerprint differs from the requested build")
    print(f"Verified native app package: {args.bundle}")


def snapshot(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    write_json(args.output, source_state(root))


def copy_resources(root: Path, app: Path, privileged_dir: Path) -> None:
    if privileged_dir.is_symlink() or not privileged_dir.is_dir():
        raise RuntimeError(f"private production helper directory is missing or is a symlink: {privileged_dir}")
    resources = app / "Contents/Resources"
    launch_agents = app / "Contents/Library/LaunchAgents"
    resources.mkdir(parents=True, exist_ok=True)
    launch_agents.mkdir(parents=True, exist_ok=True)
    # launchd will not run an ad-hoc daemon, and the daemon names its caller by the team that signed it: only a build signed
    # with an identity carries the daemon's property list. The daemon binary is in every build; nothing registers it.
    if (os.environ.get("INFINIFY_SIGN_IDENTITY") or "-") != "-":
        launch_daemons = app / "Contents/Library/LaunchDaemons"
        launch_daemons.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "native/dock-helper/Daemon" / LAUNCH_DAEMON_PLIST, launch_daemons / LAUNCH_DAEMON_PLIST)
    for source, destination in (
        ("native/app/Resources/Info.plist", app / "Contents/Info.plist"),
        ("native/app/Resources/YABAI-NOTICE.txt", resources / "YABAI-NOTICE.txt"),
        ("native/app/Resources/SUNLIGHT-NOTICE.txt", resources / "SUNLIGHT-NOTICE.txt"),
        ("LICENSE", resources / "LICENSE"),
        ("NOTICE", resources / "NOTICE"),
        (
            "native/app/Resources/com.marengox.infinify.agent.plist",
            launch_agents / "com.marengox.infinify.agent.plist",
        ),
    ):
        shutil.copy2(root / source, destination)
    release = release_version()
    if release is not None:
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleShortVersionString"], info["CFBundleVersion"] = release
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))

    native = native_desktop_dir(app)
    native.mkdir(parents=True, exist_ok=True)
    for name, filename in NATIVE_ARTIFACTS.items():
        if name == "launcher":
            source = root / "scripts/native-desktop-launcher.sh"
        else:
            source = privileged_dir / filename
        try:
            info = source.lstat()
        except FileNotFoundError as error:
            raise RuntimeError(f"production native artifact is missing: {source}") from error
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
            raise RuntimeError(f"production native artifact must be a regular executable: {source}")
        shutil.copy2(source, native / filename)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


@contextmanager
def publication_lock(path: Path) -> Iterator[None]:
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    fd = os.open(path, flags, 0o600)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
        ):
            raise RuntimeError(f"refusing unsafe publication lock: {path}")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def rollback(
    destination_app: Path,
    destination_manifest: Path,
    backup_app: Path,
    backup_manifest: Path,
    app_promoted: bool,
    manifest_promoted: bool,
) -> None:
    if manifest_promoted:
        remove_path(destination_manifest)
    if app_promoted:
        remove_path(destination_app)
    if backup_manifest.exists() or backup_manifest.is_symlink():
        os.replace(backup_manifest, destination_manifest)
    if backup_app.exists() or backup_app.is_symlink():
        os.replace(backup_app, destination_app)


def publish(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    staged_app = args.staged_app.absolute()
    privileged_dir = args.privileged_dir.absolute()
    app_dir = args.app_dir.absolute()
    destination_app = app_dir / "Infinify.app"
    destination_manifest = app_dir / "BUILD.json"
    staged_manifest = staged_app.parent / "BUILD.json"

    app_dir.parent.mkdir(parents=True, exist_ok=True)
    with publication_lock(app_dir.parent / ".infinify-build-app.publish.lock"):
        app_dir.mkdir(parents=True, exist_ok=True)
        if app_dir.is_symlink():
            raise RuntimeError(f"refusing to publish through an app directory symlink: {app_dir}")

        before = json.loads(args.snapshot.read_text(encoding="utf-8"))
        copy_resources(root, staged_app, privileged_dir)
        identity = os.environ.get("INFINIFY_SIGN_IDENTITY") or "-"
        if identity != "-":
            # The daemon is signed by the build's team before its bytes are bound into the manifest: the team signature is what
            # launchd runs it under and what it tells its caller's requirement from.
            subprocess.run(
                codesign_command(
                    identity,
                    staged_app / NATIVE_DESKTOP_RELATIVE / NATIVE_ARTIFACTS["daemon"],
                    identifier=DAEMON_IDENTIFIER,
                ),
                check=True,
            )
        create_native_manifest(staged_app, before)
        validate_native_bundle(staged_app, verify_bundle_signature=False)
        current = source_state(root)
        if current != before:
            raise RuntimeError("source files or Git state changed during the build; refusing to publish")

        executable = staged_app / "Contents/MacOS/Infinify"
        subprocess.run(codesign_command(identity, staged_app), check=True)
        validate_native_bundle(staged_app)
        if source_state(root) != before:
            raise RuntimeError("source files or Git state changed during signing; refusing to publish")

        native_manifest = staged_app / NATIVE_DESKTOP_RELATIVE / "manifest.plist"
        native_manifest_value = plistlib.loads(native_manifest.read_bytes())
        native_payload = staged_app / NATIVE_DESKTOP_RELATIVE / NATIVE_ARTIFACTS["payload"]

        manifest = {
            "schema_version": BUILD_SCHEMA_VERSION,
            "git_commit": before["commit"],
            "built_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "dirty": before["dirty"],
            "dirty_paths": before["dirty_paths"],
            "executable": "Infinify.app/Contents/MacOS/Infinify",
            "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "native_manifest_sha256": hashlib.sha256(native_manifest.read_bytes()).hexdigest(),
            "native_payload_sha256": hashlib.sha256(native_payload.read_bytes()).hexdigest(),
            "source_fingerprint_sha256": before["source_fingerprint_sha256"],
            "source_file_count": before["source_file_count"],
            "source_sha256": before["source_sha256"],
        }
        if native_manifest_value["git_commit"] != before["commit"] or native_manifest_value["source_fingerprint_sha256"] != before["source_fingerprint_sha256"]:
            raise RuntimeError("native app manifest does not match the build source snapshot")
        write_json(staged_manifest, manifest)

        if os.stat(staged_app.parent).st_dev != os.stat(app_dir.parent).st_dev:
            raise RuntimeError("staged app and destination are on different filesystems; atomic rename is unavailable")
        backup_dir = Path(tempfile.mkdtemp(prefix=".infinify-backup.", dir=app_dir.parent))
        backup_app = backup_dir / "Infinify.app"
        backup_manifest = backup_dir / "BUILD.json"
        app_promoted = False
        manifest_promoted = False
        committed = False

        blocked_signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
        previous_signal_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
        try:
            if destination_app.exists() or destination_app.is_symlink():
                os.replace(destination_app, backup_app)
            if destination_manifest.exists() or destination_manifest.is_symlink():
                os.replace(destination_manifest, backup_manifest)
            os.replace(staged_app, destination_app)
            app_promoted = True
            os.replace(staged_manifest, destination_manifest)
            manifest_promoted = True
            committed = True
        except BaseException:
            rollback(
                destination_app,
                destination_manifest,
                backup_app,
                backup_manifest,
                app_promoted,
                manifest_promoted,
            )
            raise
        finally:
            if committed:
                shutil.rmtree(backup_dir, ignore_errors=True)
            elif not backup_app.exists() and not backup_manifest.exists():
                shutil.rmtree(backup_dir, ignore_errors=True)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

    print(f"Published {destination_app}")
    print(f"Build manifest: {destination_manifest}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--root", type=Path, required=True)
    snapshot_parser.add_argument("--output", type=Path, required=True)
    snapshot_parser.set_defaults(function=snapshot)

    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--root", type=Path, required=True)
    publish_parser.add_argument("--snapshot", type=Path, required=True)
    publish_parser.add_argument("--staged-app", type=Path, required=True)
    publish_parser.add_argument("--privileged-dir", type=Path, required=True)
    publish_parser.add_argument("--app-dir", type=Path, required=True)
    publish_parser.set_defaults(function=publish)

    verify_parser = subparsers.add_parser("verify-source")
    verify_parser.add_argument("--root", type=Path, required=True)
    verify_parser.add_argument("--build-manifest", type=Path)
    verify_parser.add_argument("--built-app", type=Path)
    verify_parser.add_argument("--bundle", type=Path)
    verify_parser.set_defaults(function=verify_source)

    validate_parser = subparsers.add_parser("validate-bundle")
    validate_parser.add_argument("--bundle", type=Path, required=True)
    validate_parser.add_argument("--source-fingerprint")
    validate_parser.set_defaults(function=validate_package)

    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(f"build-app-package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
