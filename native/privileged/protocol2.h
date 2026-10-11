// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_PROTOCOL2_H
#define DW_PRIVILEGED_PROTOCOL2_H
#include <stdint.h>
// Protocol v2: binary, little-endian, on RUNTIME/v2.sock beside v1's helper.sock.
// Semantics and lifecycle: README.md "Protocol v2". Every struct here is laid out
// without padding and is sent as it lies in memory on arm64.
#define DW2_SOCKET "v2.sock"
#define DW2_MAGIC "DWv2"
#define DW2_VERSION 2
#define DW2_LEASE_MS 2000
#define DW2_MAX_BODY 131072
#define DW2_MAX_RECORDS 1024
#define DW2_MAX_TABLE 1024
#define DW2_MAX_CONNECTIONS 8
#define DW2_REPLY 0x8000

enum { DW2_HELLO=1, DW2_FRAME=2, DW2_HEARTBEAT=3, DW2_RESTORE_ALL=4, DW2_PROBE=5 };
enum { DW2_ROLE_CONTROL=1, DW2_ROLE_HEARTBEAT=2 };
enum { DW2_HELLO_OK=0, DW2_HELLO_AUTH=1, DW2_HELLO_VERSION=2, DW2_HELLO_BUSY=3, DW2_HELLO_TOKEN=4, DW2_HELLO_MALFORMED=5 };
enum { DW2_CAP_ALPHA=1 };
enum { DW2_SCOPE_COOPERATIVE=1, DW2_SCOPE_ALLOWLIST=2, DW2_SCOPE_SAME_USER=3 };
enum { DW2_QUEUE_OWN=0, DW2_QUEUE_MAIN=1 };
enum { DW2_RECORD_HAS_ALPHA=1 };
// APPLIED: the set returned 0 and the readback equals the request. NOT_APPLIED: the
// set failed or read back differently; the window stays in the table because it may
// have been changed.
enum { DW2_APPLIED=0, DW2_SCOPE=1, DW2_IDENTITY=2, DW2_MATRIX=3, DW2_ALPHA=4, DW2_SNAPSHOT=5, DW2_JOURNAL=6,
       DW2_NOT_APPLIED=7, DW2_RESTORE_PENDING=8, DW2_BUSY_V1=9, DW2_TABLE_FULL=10, DW2_MALFORMED=11 };
enum { DW2_FRAME_APPLIED=0, DW2_FRAME_DROPPED=1 };
enum { DW2_RESTORED=0, DW2_GONE=1, DW2_PENDING=2 };
enum { DW2_HELD=0, DW2_RESTORING=1 };

// length counts body bytes only. A reply carries type|DW2_REPLY and the request's seq.
struct dw2_header { uint32_t length; uint16_t type, flags; uint64_t seq; };
struct dw2_hello { char magic[4]; uint16_t version, role; char nonce[64]; uint8_t token[16]; };
struct dw2_hello_reply { uint32_t status, lease_ms, max_records, max_body, caps, scope, queue; int32_t server_pid; uint8_t token[16]; };
// A window as the shell holds it; the helper resolves and checks the owner itself.
struct dw2_identity { int32_t pid; uint32_t wid; uint64_t birth_sec, birth_usec; };
// m is a,b,c,d,tx,ty: screen to window-local, global top-left points.
struct dw2_record { struct dw2_identity id; double m[6]; float alpha; uint32_t flags; };
struct dw2_frame { uint32_t count, reserved; };                 // then count records
struct dw2_frame_reply { uint32_t disposition, count, superseded, reserved; uint64_t frames_applied; }; // then count status bytes
struct dw2_heartbeat_reply { uint32_t status, lease_ms, held, restoring; };
struct dw2_restore_result { struct dw2_identity id; uint32_t outcome; int32_t set_status; };
struct dw2_restore_reply { uint32_t count, pending, journal_persisted, reserved; }; // then count results
struct dw2_probe_entry { struct dw2_identity id; uint32_t state; float alpha; double transform[6], screen_rect[4]; };
struct dw2_probe_reply { uint32_t scope, caps, queue, lease_ms; int32_t server_pid; uint32_t held, restoring, reserved;
                         uint64_t frames_received, frames_applied, frames_superseded, journal_writes;
                         uint32_t table_count, fixture_count; }; // then table entries, then fixture identities

_Static_assert(sizeof(struct dw2_header)==16,"header");
_Static_assert(sizeof(struct dw2_hello)==88,"hello");
_Static_assert(sizeof(struct dw2_hello_reply)==48,"hello reply");
_Static_assert(sizeof(struct dw2_identity)==24,"identity");
_Static_assert(sizeof(struct dw2_record)==80,"record");
_Static_assert(sizeof(struct dw2_frame)==8,"frame");
_Static_assert(sizeof(struct dw2_frame_reply)==24,"frame reply");
_Static_assert(sizeof(struct dw2_heartbeat_reply)==16,"heartbeat reply");
_Static_assert(sizeof(struct dw2_restore_result)==32,"restore result");
_Static_assert(sizeof(struct dw2_restore_reply)==16,"restore reply");
_Static_assert(sizeof(struct dw2_probe_entry)==112,"probe entry");
_Static_assert(sizeof(struct dw2_probe_reply)==72,"probe reply");
_Static_assert(sizeof(struct dw2_frame)+DW2_MAX_RECORDS*sizeof(struct dw2_record)<=DW2_MAX_BODY,"largest frame fits");
_Static_assert(sizeof(struct dw2_probe_reply)+DW2_MAX_TABLE*sizeof(struct dw2_probe_entry)+16*sizeof(struct dw2_identity)<=DW2_MAX_BODY,"largest probe fits");
#endif
