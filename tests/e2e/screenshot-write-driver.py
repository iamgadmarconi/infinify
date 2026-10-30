#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real msg/socket/controller/writer path with synthetic pixels; no desktop app."""
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile


def check(ok, why):
    if not ok:
        raise AssertionError(why)


binary = Path(sys.argv[1]).resolve()

# The production ownership module is headless. Every child is inert and bounded;
# scenes are sentinel bytes, so refusal cannot quietly load/save or modify them.
with tempfile.TemporaryDirectory(prefix="ifown.", dir="/tmp") as directory:
    root = Path(directory).resolve()
    scene = root / "scene.json"
    scene.write_bytes(b"preserve scene bytes")
    sock = root / "socket"
    children = []

    def claim(socket_path=sock, state_path=scene, mode="once"):
        return subprocess.run([str(binary), "ownership", mode, str(socket_path), str(state_path)],
                              capture_output=True, timeout=5)

    def hold(socket_path=sock, state_path=scene, mode="hold"):
        child = subprocess.Popen([str(binary), "ownership", mode, str(socket_path), str(state_path)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(child)
        ready, _, _ = select.select([child.stdout], [], [], 5)
        check(ready and child.stdout.readline() == b"OWNED\n", "ownership acquired before waiting")
        return child

    def release(child):
        child.stdin.close()
        child.stdin = None
        out, err = child.communicate(timeout=5)
        check(child.returncode == 0, f"ownership child exit: {out!r} {err!r}")

    try:
        owner = hold()
        result = claim()
        check(result.returncode == 0 and result.stdout == b"DUPLICATE\n", "duplicate clean exit")
        check(claim(root / "other-socket").stdout == b"DUPLICATE\n", "same scene, different socket refused")
        check(claim(state_path=root / "other-scene").stdout == b"DUPLICATE\n", "same socket, different scene refused")
        check(claim(root / "independent-socket", root / "independent-scene").stdout == b"OWNED\n", "separate scene and socket permitted")
        alias = root / "parent-alias"
        alias.symlink_to(root, target_is_directory=True)
        check(claim(alias / sock.name, alias / scene.name).stdout == b"DUPLICATE\n", "canonical parent aliases share ownership")
        lock = root / "scene.json.infinify-lock"
        inode = lock.stat().st_ino
        check(claim(root / "other-socket", lock).returncode == 73, "scene cannot replace a held lock inode")
        check(claim(root / "SOCKET.INFINIFY-LOCK", root / "other-scene").returncode == 73, "reserved lock namespace is case insensitive")
        check(lock.stat().st_ino == inode, "reserved-path refusal preserves held lock inode")
        release(owner)
        check(claim().stdout == b"OWNED\n" and lock.stat().st_ino == inode, "release reuses persistent lock inode")

        owner = hold(mode="exec")
        owner.stdin.write(b"x")
        owner.stdin.flush()
        import time
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            result = claim()
            if result.stdout == b"OWNED\n":
                break
            time.sleep(.02)
        check(result.stdout == b"OWNED\n" and owner.poll() is None, "CLOEXEC releases ownership while exec child remains alive")
        release(owner)

        symlink = root / "linked-scene"
        symlink.symlink_to(scene)
        check(claim(state_path=symlink).returncode == 73, "leaf scene symlink refused as error")
        hardlink = root / "hard-scene"
        os.link(scene, hardlink)
        check(claim().returncode == 73, "hard-linked scene refused as error")
        hardlink.unlink()
        lock.chmod(0o666)
        check(claim().returncode == 73, "unsafe existing lock is an error")
        lock.chmod(0o600)
        lock.unlink()
        lock.symlink_to(scene)
        check(claim().returncode == 73, "lock symlink refused without touching target")
        lock.unlink()
        check(scene.read_bytes() == b"preserve scene bytes", "ownership never writes scene contents")
        print("PASS: production run ownership duplicate/state/socket isolation, alias, exec release and unsafe-path guards", flush=True)
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)

with tempfile.TemporaryDirectory(prefix="ifshot.", dir="/tmp") as directory:
    root = Path(directory).resolve()
    sock = root / "s"
    env = dict(os.environ, TMPDIR=str(root))
    server = subprocess.Popen([str(binary), "serve", str(sock), str(root)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        ready, _, _ = select.select([server.stdout], [], [], 5)
        check(ready and server.stdout.readline() == b"READY\n", "headless server starts")
        live = subprocess.run([str(binary), "ownership", "once", str(sock), str(root / "scene")], capture_output=True, timeout=5)
        check(live.returncode == 0 and live.stdout == b"DUPLICATE\n" and b"already answers" in live.stderr,
              "live socket without leases refuses before controller admission")

        def shot(path, raw=False):
            args = [str(binary), "msg", "--socket", str(sock)]
            if not raw:
                args.append("--json")
            result = subprocess.run(args + ["screenshot", "region", "0", "0", "2", "3", "-o", str(path)],
                                    capture_output=True, env=env, timeout=5)
            if raw:
                return result
            reply = json.loads(result.stdout)
            print(json.dumps({"path": str(path), "exit": result.returncode, "reply": reply}), flush=True)
            return result, reply

        existing = root / "existing.png"
        existing.write_bytes(b"old content is replaced and truncated" * 100)
        result, reply = shot(existing)
        check(result.returncode == 0 and reply == {"Ok": {"Screenshot": {"path": str(existing), "width": 2, "height": 3}}},
              "existing directory and overwrite retain the screenshot reply")
        png = existing.read_bytes()
        check(png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (2, 3), "actual PNG has the requested dimensions")
        check(len(png) < 3600, "existing file was truncated")

        nested = root / "new parent" / "one" / "two" / "shot.png"
        result, reply = shot(nested)
        check(result.returncode == 0 and reply == {"Ok": {"Screenshot": {"path": str(nested), "width": 2, "height": 3}}},
              "missing nested parent directories are created")
        check(nested.is_file() and nested.read_bytes() == png, "nested output is the same PNG, not a directory")
        check(sorted(str(p.relative_to(root / "new parent")) for p in (root / "new parent").rglob("*")) ==
              ["one", "one/two", "one/two/shot.png"], "only requested parent directories and file are created")

        blocker = root / "parent-is-file"
        blocker.write_bytes(b"keep parent")
        result, reply = shot(blocker / "child.png")
        check(result.returncode == 1 and reply["Err"].startswith(f"cannot create {blocker}: "), "a non-directory parent reports create failure")
        check(blocker.read_bytes() == b"keep parent", "non-directory parent is preserved")

        final_directory = root / "final-is-directory.png"
        final_directory.mkdir()
        (final_directory / "keep").write_bytes(b"keep child")
        result, reply = shot(final_directory)
        check(result.returncode == 1 and reply["Err"].startswith(f"cannot write {final_directory}: "), "directory at final filename reports write failure")
        check((final_directory / "keep").read_bytes() == b"keep child", "final directory contents are preserved")

        before = set(root.iterdir())
        result = shot("-", raw=True)
        check(result.returncode == 0 and result.stdout == png, "stdout capture remains byte-for-byte identical")
        check(set(root.iterdir()) == before, "stdout client removes its temporary file")
        check(not result.stderr, "successful stdout capture is quiet")
        print("PASS: screenshot parent directories, overwrite, error paths and stdout through production msg/socket/controller/writer; synthetic pixels only", flush=True)
    finally:
        server.terminate()
        try:
            stdout, stderr = server.communicate(timeout=5)
        except subprocess.TimeoutExpired as err:
            server.kill()
            stdout, stderr = server.communicate()
            raise AssertionError("headless server failed to stop") from err
        check(server.returncode == 0, f"server exit {server.returncode}: {stderr.decode(errors='replace')}")
        check(not sock.exists(), "headless server removes its socket")
