#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The IPC server's v0.21.0 limits and the screenshot writer's temp-and-rename, headless.

The headless binary serves the production socket module and writes real PNGs of
synthetic pixels. Nothing here starts the desktop app, touches another process's
window or leaves anything outside a mkdtemp directory.
"""
import json
import os
from pathlib import Path
import resource
import select
import socket
import subprocess
import sys
import tempfile
import time


def check(ok, why):
    if not ok:
        raise AssertionError(why)


binary = Path(sys.argv[1]).resolve()
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
wanted = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
check(wanted >= 2500, "this host lets a process hold 2500 descriptors")
# 1024 connections need a descriptor each, on both ends; the app raises its own
# limit at launch (main.m), the headless binary does not, so it is given one here.
resource.setrlimit(resource.RLIMIT_NOFILE, (wanted, hard))


def raise_limit():
    resource.setrlimit(resource.RLIMIT_NOFILE, (wanted, hard))


def exchange(path, payload, timeout=5):
    """Send `payload`, return everything the server writes until it hangs up or goes quiet."""
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        client.sendall(payload)
        data = b""
        try:
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        return data


with tempfile.TemporaryDirectory(prefix="iflim.", dir="/tmp") as directory:
    root = Path(directory).resolve()
    sock = root / "s"
    env = dict(os.environ, TMPDIR=str(root))
    server = subprocess.Popen([str(binary), "serve", str(sock), str(root)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                              preexec_fn=raise_limit)
    try:
        ready, _, _ = select.select([server.stdout], [], [], 5)
        check(ready and server.stdout.readline() == b"READY\n", "headless server starts")

        # A request line is bounded at 1 MiB, not the 64 KiB it was.
        state = b'"State"'
        reply = exchange(sock, state + b" " * (200 * 1024) + b"\n")
        check(reply.startswith(b'{"Ok":{"State"'), f"a 200 KiB request line is served: {reply[:80]!r}")
        reply = exchange(sock, state + b" " * (900 * 1024) + b"\n")
        check(reply.startswith(b'{"Ok":{"State"'), "a 900 KiB request line is served")
        reply = exchange(sock, state + b" " * (1024 * 1024 + 16) + b"\n")
        check(reply == b"", "a line past 1 MiB is hung up on without a reply")
        # Only the bytes just read decide whether a request is complete: a long
        # partial line trickled in small writes is not rescanned from its start,
        # and still completes.
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(sock))
            client.sendall(state)
            for _ in range(64):
                client.sendall(b" " * 4096)
            client.sendall(b"\n")
            check(client.recv(64).startswith(b'{"Ok":{"State"'), "a partial line completes later")
        print("PASS: request lines up to 1 MiB are served and longer ones hung up on", flush=True)

        # 1024 connections are served at once; one past it is told why and closed.
        held = []
        try:
            for index in range(1024):
                client = socket.socket(socket.AF_UNIX)
                client.settimeout(5)
                for attempt in range(200):
                    try:
                        client.connect(str(sock))
                        break
                    except ConnectionRefusedError:
                        # The listen queue (128) is full until the server's turn.
                        time.sleep(0.005)
                else:
                    raise AssertionError(f"connection {index} was never accepted")
                held.append(client)
            # The server accepts them on its own queue; give it the turn.
            time.sleep(0.5)
            past = socket.socket(socket.AF_UNIX)
            past.settimeout(5)
            past.connect(str(sock))
            line = b""
            while b"\n" not in line:
                chunk = past.recv(256)
                if not chunk:
                    break
                line += chunk
            check(line == b'{"Err":"1024 IPC connections are already open"}\n', f"refusal line: {line!r}")
            check(past.recv(16) == b"", "the refused connection is closed")
            past.close()
            # A held connection still works, and room made by closing one is taken.
            held[0].sendall(b'"State"\n')
            check(held[0].recv(64).startswith(b'{"Ok":{"State"'), "a connection under the cap is served")
            held.pop().close()
            deadline = time.time() + 5
            reply = b""
            while time.time() < deadline and not reply.startswith(b'{"Ok"'):
                reply = exchange(sock, b'"State"\n')
                if reply.startswith(b'{"Err"'):
                    time.sleep(0.1)
            check(reply.startswith(b'{"Ok":{"State"'), f"a freed slot is reused: {reply[:80]!r}")
        finally:
            for client in held:
                client.close()
        print("PASS: 1024 connections served, the next one refused with a line and closed", flush=True)

        # The screenshot is written beside its target and renamed into place.
        def shot(path):
            result = subprocess.run([str(binary), "msg", "--socket", str(sock), "--json",
                                     "screenshot", "region", "0", "0", "2", "3", "-o", str(path)],
                                    capture_output=True, env=env, timeout=10)
            return result, json.loads(result.stdout)

        victim = root / "victim.png"
        victim.write_bytes(b"not to be written through a link")
        link = root / "link.png"
        link.symlink_to(victim)
        result, reply = shot(link)
        check(result.returncode == 0 and "Ok" in reply, f"screenshot to a symlink: {reply}")
        check(victim.read_bytes() == b"not to be written through a link", "the link's target is untouched")
        check(not link.is_symlink() and link.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n",
              "the symbolic link is replaced by the new file")

        final_directory = root / "final-is-directory.png"
        final_directory.mkdir()
        (final_directory / "keep").write_bytes(b"keep child")
        result, reply = shot(final_directory)
        check(result.returncode == 1 and reply["Err"].startswith(f"cannot write {final_directory}: "),
              f"a directory at the target reports a write failure: {reply}")
        leftovers = sorted(p.name for p in root.iterdir() if p.name.startswith("."))
        check(leftovers == [], f"a failed write leaves no temporary behind: {leftovers}")

        existing = root / "existing.png"
        existing.write_bytes(b"old")
        result, reply = shot(existing)
        check(result.returncode == 0 and existing.read_bytes()[:4] == b"\x89PNG", "an existing file is replaced")
        check(sorted(p.name for p in root.iterdir() if p.name.startswith(".")) == [], "no temporary is left after a write")
        print("PASS: screenshots are written beside the target and renamed into place", flush=True)
    finally:
        server.terminate()
        try:
            stdout, stderr = server.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            stdout, stderr = server.communicate()
            raise AssertionError("headless server failed to stop")
        check(server.returncode == 0, f"server exit {server.returncode}: {stderr.decode(errors='replace')}")
