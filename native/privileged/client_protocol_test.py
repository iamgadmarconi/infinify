#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the C v2 client against a local fake peer; creates no native windows."""
from pathlib import Path
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
PRIVILEGED = ROOT / "native" / "privileged"
HEADER = struct.Struct("<IHHQ")
HELLO = struct.Struct("<4sHH64s16s")
HELLO_REPLY = struct.Struct("<7Ii16s")
FRAME_REPLY = struct.Struct("<4IQ")
RESTORE_REPLY = struct.Struct("<4I")
RESTORE_RESULT = struct.Struct("<iIQQIi")
HELLO_TYPE, FRAME, HEARTBEAT, RESTORE_ALL, REPLY = 1, 2, 3, 4, 0x8000
NONCE = "7" * 64
TOKEN = b"\x13" * 16


def recv_exact(connection, length):
    data = bytearray()
    while len(data) < length:
        chunk = connection.recv(length - len(data))
        if not chunk:
            raise EOFError("peer closed")
        data.extend(chunk)
    return bytes(data)


def recv_message(connection):
    length, kind, flags, seq = HEADER.unpack(recv_exact(connection, HEADER.size))
    return kind, flags, seq, recv_exact(connection, length)


def send_message(connection, kind, seq, body=b""):
    connection.sendall(HEADER.pack(len(body), kind | REPLY, 0, seq) + body)


class FakePeer:
    def __init__(self, mode, runtime):
        self.mode = mode
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(runtime / "v2.sock"))
        self.listener.listen(4)
        self.listener.settimeout(5)
        self.error = None
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.connections = []
        self.thread.start()

    def handshake(self, connection, expected_role):
        kind, flags, seq, body = recv_message(connection)
        if kind != HELLO_TYPE or flags or seq or len(body) != HELLO.size:
            raise AssertionError((kind, flags, seq, len(body)))
        magic, version, role, nonce, _ = HELLO.unpack(body)
        if magic != b"DWv2" or version != 2 or role != expected_role or nonce != NONCE.encode():
            raise AssertionError((magic, version, role, nonce))
        reply = HELLO_REPLY.pack(0, 2000, 16, 8 + 16 * 80, 0, 3, 0, os.getpid(), TOKEN)
        send_message(connection, HELLO_TYPE, 0, reply)

    def serve(self):
        try:
            control, _ = self.listener.accept()
            self.connections.append(control)
            self.handshake(control, 1)
            beat, _ = self.listener.accept()
            self.connections.append(beat)
            self.handshake(beat, 2)
            threading.Thread(target=self.serve_heartbeats, args=(beat,), daemon=True).start()
            self.serve_control(control)
        except EOFError:
            pass
        except (OSError, AssertionError, struct.error) as error:
            self.error = error
        finally:
            self.listener.close()

    def serve_heartbeats(self, connection):
        try:
            while True:
                kind, flags, seq, body = recv_message(connection)
                if kind != HEARTBEAT or flags or len(body):
                    raise AssertionError((kind, flags, len(body)))
                send_message(connection, HEARTBEAT, seq, struct.pack("<4I", 0, 2000, 0, 0))
        except (EOFError, OSError):
            return
        except AssertionError as error:
            self.error = error

    def serve_control(self, connection):
        try:
            if self.mode == "coalesced_apply":
                first = recv_message(connection)
                second = recv_message(connection)
                if first[0] != FRAME or second[0] != FRAME or first[3][:8] != struct.pack("<II", 1, 0) or second[3][:8] != struct.pack("<II", 2, 0):
                    raise AssertionError((first, second))
                statuses = b"\x00\x00"
                body = FRAME_REPLY.pack(0, 2, 1, 0, 1) + statuses
                send_message(connection, FRAME, second[2], body)
                while recv_exact(connection, 1):
                    pass
            elif self.mode in ("bad_sequence", "bad_count"):
                message = recv_message(connection)
                if message[0] != FRAME:
                    raise AssertionError(message)
                seq = message[2] + (1 if self.mode == "bad_sequence" else 0)
                count = 0 if self.mode == "bad_count" else 1
                body = FRAME_REPLY.pack(0, count, 0, 0, 1) + (b"\x00" * count)
                send_message(connection, FRAME, seq, body)
                while recv_exact(connection, 1):
                    pass
            elif self.mode in ("restore_pending", "restore_undurable", "bad_restore_summary"):
                frame = recv_message(connection)
                request = recv_message(connection)
                if frame[0] != FRAME or request[0] != RESTORE_ALL or request[3]:
                    raise AssertionError((frame, request))
                # The frame release reply must arrive before RESTORE_ALL's summary.
                send_message(connection, FRAME, frame[2], FRAME_REPLY.pack(1, 0, 0, 0, 0))
                pending = 0 if self.mode == "bad_restore_summary" else 1
                persisted = 0 if self.mode == "restore_undurable" else 1
                summary = RESTORE_REPLY.pack(1, pending, persisted, 0)
                result = RESTORE_RESULT.pack(123, 456, 1700000000, 123456, 2, -1)
                send_message(connection, RESTORE_ALL, request[2], summary + result)
                while recv_exact(connection, 1):
                    pass
            else:
                raise AssertionError(self.mode)
        except (EOFError, OSError):
            return
        except (AssertionError, struct.error) as error:
            self.error = error

    def close(self):
        for connection in self.connections:
            try:
                connection.close()
            except OSError:
                pass
        self.listener.close()
        self.thread.join(timeout=2)


HARNESS = r'''#include "dwclient.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static _Atomic int lost_reason;
static _Atomic uint64_t result_seq;
static _Atomic uint32_t result_count;
static void frame_result(void *context, uint64_t seq, const uint8_t *status, uint32_t count) {
    (void)context;
    for (uint32_t i=0;i<count;i++) if (status[i]!=DW2_APPLIED) atomic_store(&lost_reason, 90);
    atomic_store(&result_count,count);atomic_store(&result_seq,seq);
}
static void lost(void *context, int reason) { (void)context;atomic_store(&lost_reason,reason); }
static int wait_written(dw_client *client, uint64_t expected) {
    for (int i=0;i<1000;i++) {
        struct dw_client_stats stats;dw_client_stats(client,&stats);
        if (stats.written>=expected) return 1;
        if (atomic_load(&lost_reason)) return 0;
        usleep(1000);
    }
    return 0;
}
static int wait_lost(void) {
    for (int i=0;i<1000;i++) { if (atomic_load(&lost_reason)) return 1;usleep(1000); }
    return 0;
}
static int wait_applied(dw_client *client) {
    for (int i=0;i<1000;i++) {
        struct dw_client_stats stats;dw_client_stats(client,&stats);
        if (stats.applied) return 1;
        if (atomic_load(&lost_reason)) return 0;
        usleep(1000);
    }
    return 0;
}
static int wait_callback(uint64_t seq, uint32_t count) {
    for (int i=0;i<1000;i++) {
        if (atomic_load(&result_seq)==seq && atomic_load(&result_count)==count) return 1;
        usleep(1000);
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc!=4) return 2;
    struct dw_client_callbacks callbacks={.frame_result=frame_result,.lost=lost};
    dw_client *client=NULL;struct dw_client_info info={0};
    if (dw_client_open(argv[1],argv[2],&callbacks,3000,&client,&info)!=DW_CLIENT_OK) return 10;
    struct dw2_record records[2]={{0}};uint64_t first=0,second=0;
    if (!strcmp(argv[3],"coalesced_apply")) {
        if (dw_client_submit_frame(client,records,1,&first)!=DW_CLIENT_OK || !wait_written(client,1)) return 11;
        if (dw_client_submit_frame(client,records,2,&second)!=DW_CLIENT_OK || !wait_written(client,2) || !wait_applied(client)
            || !wait_callback(second,2)) return 12;
        struct dw_client_stats stats;dw_client_stats(client,&stats);
        int ok=stats.superseded==1 && stats.applied==1 && stats.last_applied_seq==second
            && atomic_load(&result_seq)==second && atomic_load(&result_count)==2;
        dw_client_close(client);return ok ? 0 : 13;
    }
    if (!strcmp(argv[3],"bad_sequence") || !strcmp(argv[3],"bad_count")) {
        if (dw_client_submit_frame(client,records,1,&first)!=DW_CLIENT_OK || !wait_written(client,1) || !wait_lost()) return 20;
        int ok=atomic_load(&lost_reason)==DW_LOST_PROTOCOL;
        dw_client_close(client);return ok ? 0 : 21;
    }
    if (!strcmp(argv[3],"restore_pending") || !strcmp(argv[3],"restore_undurable") || !strcmp(argv[3],"bad_restore_summary")) {
        if (dw_client_submit_frame(client,records,1,&first)!=DW_CLIENT_OK || !wait_written(client,1)) return 30;
        struct dw2_restore_result results[2]={{0}};uint32_t count=91,pending=92,persisted=93;
        int result=dw_client_restore_all(client,2000,results,2,&count,&pending,&persisted);
        if (!strcmp(argv[3],"restore_pending")) {
            int ok=result==DW_CLIENT_OK && count==1 && pending==1 && persisted==1
                && results[0].id.pid==123 && results[0].id.wid==456 && results[0].outcome==DW2_PENDING;
            dw_client_close(client);return ok ? 0 : 31;
        }
        if (!strcmp(argv[3],"restore_undurable")) {
            int ok=result==DW_CLIENT_UNDURABLE && count==1 && pending==1 && persisted==0
                && results[0].id.pid==123 && results[0].id.wid==456 && results[0].outcome==DW2_PENDING;
            dw_client_close(client);return ok ? 0 : 32;
        }
        int ok=result==DW_CLIENT_INVALID && count==91 && pending==92 && persisted==93;
        dw_client_close(client);return ok ? 0 : 33;
    }
    dw_client_close(client);return 3;
}
'''


def main():
    compiler = os.environ.get("CC", "clang")
    with tempfile.TemporaryDirectory(prefix="dw2-client-", dir="/tmp") as temporary:
        temp = Path(temporary)
        harness = temp / "client.c"
        executable = temp / "client-test"
        harness.write_text(HARNESS)
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I", str(PRIVILEGED), str(PRIVILEGED / "dwclient.c"), str(harness), "-o", str(executable)], check=True)
        for mode in ("coalesced_apply", "bad_sequence", "bad_count", "restore_pending", "restore_undurable", "bad_restore_summary"):
            with tempfile.TemporaryDirectory(prefix="dw2-run-", dir="/tmp") as runtime_dir:
                runtime = Path(runtime_dir)
                peer = FakePeer(mode, runtime)
                try:
                    run = subprocess.run([str(executable), str(runtime), NONCE, mode], capture_output=True, text=True, timeout=8)
                    peer.thread.join(timeout=2)
                    if run.returncode:
                        raise AssertionError(f"{mode}: client exit {run.returncode}; stdout={run.stdout!r}; stderr={run.stderr!r}")
                    if peer.error:
                        raise AssertionError(f"{mode}: fake peer failed: {peer.error!r}")
                finally:
                    peer.close()
            print(f"PASS {mode}")


if __name__ == "__main__":
    main()
