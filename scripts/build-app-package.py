#!/usr/bin/env python3
"""Stage, verify, and atomically publish the macOS application bundle."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def run(args: list[str], *, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def source_state(root: Path) -> dict[str, object]:
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
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
    ).decode("utf-8", errors="replace")
    dirty_paths = [line[3:] for line in status.splitlines() if line]
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


def snapshot(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    write_json(args.output, source_state(root))


def copy_resources(root: Path, app: Path) -> None:
    resources = app / "Contents/Resources"
    launch_agents = app / "Contents/Library/LaunchAgents"
    resources.mkdir(parents=True, exist_ok=True)
    launch_agents.mkdir(parents=True, exist_ok=True)
    for source, destination in (
        ("native/desktop/Info.plist", app / "Contents/Info.plist"),
        ("native/families/YABAI-NOTICE.txt", resources / "YABAI-NOTICE.txt"),
        ("LICENSE", resources / "LICENSE"),
        ("NOTICE", resources / "NOTICE"),
        (
            "native/desktop/com.marengox.infinify.agent.plist",
            launch_agents / "com.marengox.infinify.agent.plist",
        ),
    ):
        shutil.copy2(root / source, destination)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


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
    app_dir = args.app_dir.absolute()
    destination_app = app_dir / "Infinify.app"
    destination_manifest = app_dir / "BUILD.json"
    staged_manifest = staged_app.parent / "BUILD.json"

    before = json.loads(args.snapshot.read_text(encoding="utf-8"))
    copy_resources(root, staged_app)
    current = source_state(root)
    if current != before:
        raise RuntimeError("source files or Git state changed during the build; refusing to publish")

    executable = staged_app / "Contents/MacOS/Infinify"
    identity = os.environ.get("INFINIFY_SIGN_IDENTITY") or "-"
    subprocess.run(["codesign", "--force", "--sign", identity, str(staged_app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(staged_app)], check=True)
    if source_state(root) != before:
        raise RuntimeError("source files or Git state changed during signing; refusing to publish")

    manifest = {
        "schema_version": 1,
        "git_commit": before["commit"],
        "built_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "dirty": before["dirty"],
        "dirty_paths": before["dirty_paths"],
        "executable": "Infinify.app/Contents/MacOS/Infinify",
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "source_fingerprint_sha256": before["source_fingerprint_sha256"],
        "source_file_count": before["source_file_count"],
        "source_sha256": before["source_sha256"],
    }
    write_json(staged_manifest, manifest)

    app_dir.mkdir(parents=True, exist_ok=True)
    if app_dir.is_symlink():
        raise RuntimeError(f"refusing to publish through an app directory symlink: {app_dir}")
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
    publish_parser.add_argument("--app-dir", type=Path, required=True)
    publish_parser.set_defaults(function=publish)

    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(f"build-app-package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    main()
