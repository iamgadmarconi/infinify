# SPDX-License-Identifier: GPL-3.0-or-later
"""What the live scoped scenarios share: asking the app's IPC socket, waiting for a
condition, and turning SIGTERM/SIGHUP into a normal exit so that their cleanup runs."""
import json
import signal
import socket
import time


def ask(sock, request, timeout=4):
    """One IPC request; the `Ok` payload of its one-line reply."""
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(str(sock))
        connection.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data)
    assert 'Ok' in reply, reply
    return reply['Ok']


def until(read, passed, seconds=8, interval=.05):
    """`read()` until `passed(value)`; the last value is the assertion message on timeout."""
    deadline = time.monotonic() + seconds
    while True:
        value = read()
        if passed(value):
            return value
        assert time.monotonic() < deadline, value
        time.sleep(interval)


def exit_on_signals():
    def interrupted(number, _frame):
        raise SystemExit(128 + number)

    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
