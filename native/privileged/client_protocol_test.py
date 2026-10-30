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

ROOT = Path(__file__).resolve().parents[2]
PRIVILEGED = ROOT / "native" / "privileged"
HEADER = struct.Struct("<IHHQ")
HELLO = struct.Struct("<4sHH64s16s")
HELLO_REPLY = struct.Struct("<7Ii16s")
FRAME_REPLY = struct.Struct("<4IQ")
RESTORE_REPLY = struct.Struct("<4I")
RESTORE_RESULT = struct.Struct("<iIQQIi")
SPACE_RECORD = struct.Struct("<iIQQ6dfIQ")
VEIL_REQUEST = struct.Struct("<II")
VEIL_REPLY = struct.Struct("<II")
HELLO_TYPE, FRAME, HEARTBEAT, RESTORE_ALL, FRAME_SPACE, VEIL, REPLY = 1, 2, 3, 4, 8, 9, 0x8000
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
        self.space = mode.startswith("space_") and mode != "space_no_cap"
        self.space |= mode == "plain_bad_opcode"
        self.pinned = "pinned" in mode and not mode.endswith("no_cap")
        self.veil = mode.startswith("veil_") and mode != "veil_no_cap"
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
        record_size = 88 if self.space and self.mode != "space_bad_max_body" else 80
        reply = HELLO_REPLY.pack(0, 2000, 16, 8 + 16 * record_size, (32 if self.space else 0) | (64 if self.pinned else 0) | (128 if self.veil else 0), 3, 0, os.getpid(), TOKEN)
        send_message(connection, HELLO_TYPE, 0, reply)

    def serve(self):
        try:
            control, _ = self.listener.accept()
            self.connections.append(control)
            self.handshake(control, 1)
            if self.mode == "space_bad_max_body":
                while recv_exact(control, 1):
                    pass
                return
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
            if "pinned" in self.mode or self.mode == "plain_pin_status":
                kind = FRAME_SPACE if self.space else FRAME
                message = recv_message(connection)
                has_pin = not self.mode.endswith("no_cap") and self.mode != "plain_pin_status"
                self.check_frame(message, kind, 1, pinned=has_pin)
                status = 11 if self.mode == "pinned_bad_space_status" else 12 if self.mode in ("pinned_status", "plain_pin_status") else 0
                send_message(connection, kind, message[2], FRAME_REPLY.pack(0, 1, 0, 0, 1) + bytes([status]))
                if self.mode.endswith("apply"):
                    message = recv_message(connection)
                    self.check_frame(message, kind, 1)
                    send_message(connection, kind, message[2], FRAME_REPLY.pack(0, 1, 0, 0, 2) + b"\x00")
                while recv_exact(connection, 1):
                    pass
            elif self.mode.startswith("veil_"):
                # The request is a mode and a zero; a helper without the capability is never sent one.
                for mode in ((1, 0), (0, 0)) if self.mode == "veil_apply" else () if self.mode == "veil_no_cap" else ((1, 0),):
                    kind, flags, seq, body = recv_message(connection)
                    if kind != VEIL or flags or not seq or body != VEIL_REQUEST.pack(*mode):
                        raise AssertionError((kind, flags, seq, body, mode))
                    status, timeout = {"veil_refused": (1, 1000), "veil_bad_status": (5, 1000), "veil_bad_timeout": (0, 0)}.get(self.mode, (0, 1000))
                    reply = VEIL_REPLY.pack(status, timeout) + (b"\x00" if self.mode == "veil_bad_length" else b"")
                    send_message(connection, VEIL, seq, reply)
                while recv_exact(connection, 1):
                    pass
            elif self.mode in ("coalesced_apply", "space_coalesced_apply", "space_coalesced_plain"):
                first = recv_message(connection)
                second = recv_message(connection)
                self.check_frame(first, FRAME_SPACE if self.mode == "space_coalesced_plain" else FRAME, 1)
                self.check_frame(second, FRAME_SPACE if self.mode == "space_coalesced_apply" else FRAME, 2)
                statuses = b"\x00\x00"
                body = FRAME_REPLY.pack(0, 2, 1, 0, 1) + statuses
                send_message(connection, second[0], second[2], body)
                while recv_exact(connection, 1):
                    pass
            elif self.mode in ("bad_sequence", "bad_count", "space_bad_sequence", "space_bad_count",
                               "space_bad_opcode", "space_bad_dropped_opcode", "plain_bad_opcode",
                               "space_bad_status", "plain_space_status", "space_status", "space_no_cap"):
                message = recv_message(connection)
                kind = FRAME_SPACE if self.space and self.mode != "plain_bad_opcode" else FRAME
                self.check_frame(message, kind, 1)
                seq = message[2] + (1 if self.mode.endswith("bad_sequence") else 0)
                dropped = self.mode == "space_bad_dropped_opcode"
                count = 0 if self.mode.endswith("bad_count") or dropped else 1
                status = 12 if self.mode == "space_bad_status" else 11 if self.mode in ("space_status", "plain_space_status") else 0
                body = FRAME_REPLY.pack(1 if dropped else 0, count, 0, 0, 1) + bytes([status] * count)
                if self.mode in ("space_bad_opcode", "space_bad_dropped_opcode"):
                    kind = FRAME
                elif self.mode == "plain_bad_opcode":
                    kind = FRAME_SPACE
                send_message(connection, kind, seq, body)
                while recv_exact(connection, 1):
                    pass
            elif self.mode in ("restore_pending", "restore_undurable", "bad_restore_summary", "space_restore_pending"):
                frame = recv_message(connection)
                request = recv_message(connection)
                self.check_frame(frame, FRAME_SPACE if self.space else FRAME, 1)
                if request[0] != RESTORE_ALL or request[3]:
                    raise AssertionError((frame, request))
                # The frame release reply must arrive before RESTORE_ALL's summary.
                send_message(connection, frame[0], frame[2], FRAME_REPLY.pack(1, 0, 0, 0, 0))
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

    def check_frame(self, message, kind, count, pinned=False):
        expected = struct.pack("<II", count, 0)
        for index in range(count):
            if kind == FRAME_SPACE:
                expected += SPACE_RECORD.pack(123, 456 + index, 1700000000, 123456,
                                              1, 0, 0, 1, 10, 20, 1, 1 | (4 if pinned else 0), 101 if index else 0)
            else:
                expected += bytes(76) + struct.pack("<I", 4 if pinned else 0)
        if message[0] != kind or message[1] or not message[2] or message[3] != expected:
            raise AssertionError((message, kind, count))

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
static uint8_t expected_status;
static void frame_result(void *context, uint64_t seq, const uint8_t *status, uint32_t count) {
    (void)context;
    for (uint32_t i=0;i<count;i++) if (status[i]!=expected_status) atomic_store(&lost_reason, 90);
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
    int opened=dw_client_open(argv[1],argv[2],&callbacks,3000,&client,&info);
    if (!strcmp(argv[3],"space_bad_max_body")) return opened==DW_CLIENT_REFUSED && !client ? 0 : 50;
    if (opened!=DW_CLIENT_OK) return 10;
    struct dw2_record records[2]={{0}};uint64_t first=0,second=0;
    struct dw2_space_record spaces[2]={0};
    for (int i=0;i<2;i++) {
        spaces[i].record=(struct dw2_record){.id={123,456+i,1700000000,123456},.m={1,0,0,1,10,20},.alpha=1,.flags=DW2_RECORD_HAS_ALPHA};
        spaces[i].target_space=i ? 101 : 0;
    }
    int spaceMode=!strncmp(argv[3],"space_",6) && strcmp(argv[3],"space_no_cap");
    if ((spaceMode || !strcmp(argv[3],"plain_bad_opcode")) != !!(info.caps&DW2_CAP_SPACE)) return 51;
    if (!strncmp(argv[3],"veil_",5)) {
        uint32_t held=0;int hasCap=(info.caps&DW2_CAP_VEIL)!=0;
        if (!strcmp(argv[3],"veil_no_cap")) {
            // Without the capability nothing is asked, so a peer that would answer is never sent a request.
            if (hasCap) return 70;
            if (dw_client_veil(client,2000,true,&held)!=DW_CLIENT_INVALID || held) return 71;
            dw_client_close(client);return 0;
        }
        if (!hasCap) return 72;
        int result=dw_client_veil(client,2000,true,&held);
        if (!strcmp(argv[3],"veil_apply")) {
            // Asked on, then off; the helper's own bound comes back with an acceptance.
            if (result!=DW_CLIENT_OK || held!=DW2_VEIL_TIMEOUT_MS) return 73;
            held=0;if (dw_client_veil(client,2000,false,&held)!=DW_CLIENT_OK || held!=DW2_VEIL_TIMEOUT_MS) return 74;
        } else if (!strcmp(argv[3],"veil_refused")) {
            if (result!=DW_CLIENT_REFUSED || held) return 75;
        } else {
            // An answer outside the contract is not an acceptance, and says nothing of the bound.
            if (result!=DW_CLIENT_INVALID || held) return 76;
        }
        if (atomic_load(&lost_reason)) return 77;
        dw_client_close(client);return 0;
    }
    if (strstr(argv[3],"pinned") || !strcmp(argv[3],"plain_pin_status")) {
        int noCap=strstr(argv[3],"no_cap")!=NULL;
        int bad=!strcmp(argv[3],"plain_pin_status") || !strcmp(argv[3],"pinned_bad_space_status");
        if (!strcmp(argv[3],"pinned_status")) expected_status=DW2_SUBLEVEL;
        if (strcmp(argv[3],"plain_pin_status")) { records[0].flags|=DW2_RECORD_PINNED;spaces[0].record.flags|=DW2_RECORD_PINNED; }
        if (noCap) {
            uint64_t unchanged=99;
            int submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&unchanged) : dw_client_submit_frame(client,records,1,&unchanged);
            struct dw_client_stats stats;dw_client_stats(client,&stats);
            if (submitted!=DW_CLIENT_INVALID || unchanged!=99 || stats.submitted || stats.written) return 60;
            records[0].flags&=~DW2_RECORD_PINNED;spaces[0].record.flags&=~DW2_RECORD_PINNED;
        }
        int submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&first) : dw_client_submit_frame(client,records,1,&first);
        if (submitted!=DW_CLIENT_OK) return 61;
        if (bad) { int ok=wait_lost() && atomic_load(&lost_reason)==DW_LOST_PROTOCOL;dw_client_close(client);return ok ? 0 : 62; }
        if (!wait_callback(first,1) || atomic_load(&lost_reason)) return 63;
        if (strstr(argv[3],"apply")) {
            records[0].flags&=~DW2_RECORD_PINNED;spaces[0].record.flags&=~DW2_RECORD_PINNED;
            submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&second) : dw_client_submit_frame(client,records,1,&second);
            if (submitted!=DW_CLIENT_OK || !wait_callback(second,1) || atomic_load(&lost_reason)) return 64;
        }
        dw_client_close(client);return 0;
    }
    if (!strcmp(argv[3],"coalesced_apply") || !strcmp(argv[3],"space_coalesced_apply") || !strcmp(argv[3],"space_coalesced_plain")) {
        int submitted=!strcmp(argv[3],"space_coalesced_plain") ? dw_client_submit_space_frame(client,spaces,1,&first)
            : dw_client_submit_frame(client,records,1,&first);
        if (submitted!=DW_CLIENT_OK || !wait_written(client,1)) return 11;
        submitted=!strcmp(argv[3],"space_coalesced_apply") ? dw_client_submit_space_frame(client,spaces,2,&second)
            : dw_client_submit_frame(client,records,2,&second);
        if (submitted!=DW_CLIENT_OK || !wait_written(client,2) || !wait_applied(client)
            || !wait_callback(second,2)) return 12;
        struct dw_client_stats stats;dw_client_stats(client,&stats);
        int ok=stats.superseded==1 && stats.applied==1 && stats.last_applied_seq==second
            && atomic_load(&result_seq)==second && atomic_load(&result_count)==2;
        dw_client_close(client);return ok ? 0 : 13;
    }
    if (!strcmp(argv[3],"space_no_cap") || !strcmp(argv[3],"space_status")) {
        if (!spaceMode) {
            uint64_t unchanged=99;
            if (dw_client_submit_space_frame(client,spaces,2,&unchanged)!=DW_CLIENT_INVALID || unchanged!=99
                || dw_client_submit_space_frame(client,NULL,0,&unchanged)!=DW_CLIENT_INVALID || unchanged!=99) return 52;
            struct dw_client_stats stats;dw_client_stats(client,&stats);
            if (stats.submitted || stats.written) return 53;
        } else expected_status=DW2_SPACE;
        int submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&first) : dw_client_submit_frame(client,records,1,&first);
        if (submitted!=DW_CLIENT_OK || !wait_written(client,1) || !wait_applied(client) || !wait_callback(first,1)) return 54;
        struct dw_client_stats stats;dw_client_stats(client,&stats);
        int ok=!atomic_load(&lost_reason) && stats.submitted==1 && stats.applied==1
            && stats.records_failed==(spaceMode ? 1 : 0) && stats.records_applied==(spaceMode ? 0 : 1);
        dw_client_close(client);return ok ? 0 : 55;
    }
    if ((strstr(argv[3],"bad_") && strcmp(argv[3],"bad_restore_summary")) || !strcmp(argv[3],"plain_space_status")) {
        int submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&first) : dw_client_submit_frame(client,records,1,&first);
        if (submitted!=DW_CLIENT_OK || !wait_lost()) return 20;
        int ok=atomic_load(&lost_reason)==DW_LOST_PROTOCOL;
        dw_client_close(client);return ok ? 0 : 21;
    }
    if (!strcmp(argv[3],"restore_pending") || !strcmp(argv[3],"restore_undurable") || !strcmp(argv[3],"bad_restore_summary") || !strcmp(argv[3],"space_restore_pending")) {
        int submitted=spaceMode ? dw_client_submit_space_frame(client,spaces,1,&first) : dw_client_submit_frame(client,records,1,&first);
        if (submitted!=DW_CLIENT_OK || !wait_written(client,1)) return 30;
        struct dw2_restore_result results[2]={{0}};uint32_t count=91,pending=92,persisted=93;
        int result=dw_client_restore_all(client,2000,results,2,&count,&pending,&persisted);
        if (!strcmp(argv[3],"restore_pending") || !strcmp(argv[3],"space_restore_pending")) {
            struct dw_client_stats stats;dw_client_stats(client,&stats);
            int ok=result==DW_CLIENT_OK && count==1 && pending==1 && persisted==1
                && results[0].id.pid==123 && results[0].id.wid==456 && results[0].outcome==DW2_PENDING
                && stats.discarded==1 && !atomic_load(&result_seq);
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
        for mode in ("coalesced_apply", "bad_sequence", "bad_count", "restore_pending", "restore_undurable", "bad_restore_summary",
                     "space_coalesced_apply", "space_coalesced_plain", "space_no_cap", "space_bad_max_body",
                     "space_bad_sequence", "space_bad_count", "space_bad_opcode", "space_bad_dropped_opcode",
                     "plain_bad_opcode", "space_bad_status", "plain_space_status", "space_status", "space_restore_pending",
                     "pinned_apply", "space_pinned_apply", "pinned_no_cap", "space_pinned_no_cap",
                     "pinned_status", "plain_pin_status", "pinned_bad_space_status",
                     "veil_apply", "veil_refused", "veil_no_cap", "veil_bad_status", "veil_bad_timeout", "veil_bad_length"):
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
