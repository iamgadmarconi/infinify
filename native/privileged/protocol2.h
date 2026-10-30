// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_PROTOCOL2_H
#define DW_PRIVILEGED_PROTOCOL2_H
#include <stdint.h>
// The sole helper protocol: binary v2, little-endian, on RUNTIME/v2.sock.
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
#define DW2_MAX_PROCESSES 1024
#define DW2_REPLY 0x8000
// How long the helper keeps a veiled window invisible without a frame or a RESTORE
// record for it before it releases the window itself (VEIL below).
#define DW2_VEIL_TIMEOUT_MS 1000
// How long the helper keeps the placement it gave, at the announcement, to a child window of a placed root (a menu, a popover, a sheet)
// without a frame naming it, before it releases the window itself (VEIL below, payload-v2.m v2ArrivalPlace).
#define DW2_ARRIVAL_TIMEOUT_MS 500

enum { DW2_HELLO=1, DW2_FRAME=2, DW2_HEARTBEAT=3, DW2_RESTORE_ALL=4, DW2_PROBE=5, DW2_ENROLLMENT=6, DW2_INSPECT=7, DW2_FRAME_SPACE=8, DW2_VEIL=9 };
enum { DW2_ROLE_CONTROL=1, DW2_ROLE_HEARTBEAT=2 };
enum { DW2_HELLO_OK=0, DW2_HELLO_AUTH=1, DW2_HELLO_VERSION=2, DW2_HELLO_BUSY=3, DW2_HELLO_TOKEN=4, DW2_HELLO_MALFORMED=5 };
enum { DW2_CAP_ALPHA=1, DW2_CAP_RESTORE_WINDOW=2, DW2_CAP_ENROLLMENT=4, DW2_CAP_FIXTURE_FAMILY=8, DW2_CAP_INSPECT=16, DW2_CAP_SPACE=32, DW2_CAP_PINNED=64,
       DW2_CAP_VEIL=128 };
// FIXTURE_FAMILY asks a client to exercise native root/child presentation on
// the host's finite, explicitly created window list. It expands no process or
// window authority and says nothing about third-party family compositing.
enum { DW2_SCOPE_COOPERATIVE=1, DW2_SCOPE_ALLOWLIST=2, DW2_SCOPE_SAME_USER=3 };
enum { DW2_QUEUE_OWN=0, DW2_QUEUE_MAIN=1 };
enum { DW2_RECORD_HAS_ALPHA=1, DW2_RECORD_RESTORE=2, DW2_RECORD_PINNED=4 };
// PINNED is negotiated by CAP_PINNED and uses the existing record layout. It
// requests the floating sublevel, without activation or changing the base level.
// The first request journals the exact original sublevel. Later frames without
// PINNED restore that original if touched; untouched windows receive no write.
// The client must apply one policy to every member of its audited native family.
// RESTORE is negotiated by CAP_RESTORE_WINDOW and stands alone: m and alpha are
// ignored. It restores the journalled original for this identity, then removes
// the entry. A pending restore stays journalled and is retried independently.
// APPLIED: fresh native property readbacks equal the request and final identity
// is current. Status-bearing scalar/list setters must also return 0 when called;
// transaction submission and Space moves have no trustworthy setter status and
// cannot substitute for readback. A previously verified unchanged property may
// omit its setter only after fresh readback. NOT_APPLIED: a reported set failure
// or differing/unavailable readback; the window stays journalled because it may
// have been changed. None of these receipts proves optical presentation/input.
enum { DW2_APPLIED=0, DW2_SCOPE=1, DW2_IDENTITY=2, DW2_MATRIX=3, DW2_ALPHA=4, DW2_SNAPSHOT=5, DW2_JOURNAL=6,
       DW2_NOT_APPLIED=7, DW2_RESTORE_PENDING=8, DW2_TABLE_FULL=9, DW2_MALFORMED=10, DW2_SPACE=11, DW2_SUBLEVEL=12 };
// SUBLEVEL refuses a pin request when the optional sublevel API is unavailable.
// SPACE refuses unsupported, invalid, non-singleton or non-current Space
// admission. An attempted but unconfirmed move is NOT_APPLIED instead.
// VEIL is negotiated by CAP_VEIL, offered only by a same-user (desktop) helper that can
// read and write alpha and hear the window server announce a window. Mode 1 asks the
// helper to hold every ordinary window an application opens afterwards at alpha 0, from
// the moment the window server announces it, until a frame places it or the window is
// released; mode 0 ends that and releases what is still held. A veiled window is an
// ordinary table entry, journalled with its original alpha before the write. It is
// released by its own RESTORE record, by RESTORE_ALL, by the end of the session, or
// DW2_VEIL_TIMEOUT_MS after it was veiled. A frame record for it applies the transform
// first and then the record's alpha, or the original alpha when the record has none.
// The reply is DW2_APPLIED or, for a helper that cannot, DW2_SCOPE, and the timeout.
// While it is on, a window that opens as a child of a window the shell has placed also gets that root's placement at once, and the same
// ways out. The helper never veils a window of the requesting client's own process. Veiling ends
// with the session. The idea, and the window server announcement it rests on, are adapted
// from Sunlight (MIT); exact source provenance is in payload-v2.m.
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
// FRAME_SPACE is negotiated by CAP_SPACE. Zero target_space leaves membership
// unchanged. Legacy FRAME and dw2_record retain their exact original layout.
struct dw2_space_record { struct dw2_record record; uint64_t target_space; };
struct dw2_frame { uint32_t count, reserved; }; // then count records of the opcode's type
struct dw2_frame_reply { uint32_t disposition, count, superseded, reserved; uint64_t frames_applied; }; // then count status bytes
struct dw2_heartbeat_reply { uint32_t status, lease_ms, held, restoring; };
struct dw2_veil { uint32_t mode, reserved; };
struct dw2_veil_reply { uint32_t status, timeout_ms; };
struct dw2_restore_result { struct dw2_identity id; uint32_t outcome; int32_t set_status; };
struct dw2_restore_reply { uint32_t count, pending, journal_persisted, reserved; }; // then count results
struct dw2_probe_entry { struct dw2_identity id; uint32_t state; float alpha; double transform[6], screen_rect[4]; };
struct dw2_probe_reply { uint32_t scope, caps, queue, lease_ms; int32_t server_pid; uint32_t held, restoring, journal_pending;
                         uint64_t frames_received, frames_applied, frames_superseded, journal_writes;
                         uint32_t table_count, fixture_count; }; // then table entries, then fixture identities
// Read-only scope audit, negotiated by CAP_ENROLLMENT. A process instance, never
// a window lookup or an enrollment request. SAME_USER has no finite process list.
struct dw2_process { int32_t pid; uint32_t reserved; uint64_t birth_sec, birth_usec; };
struct dw2_enrollment_reply { uint32_t scope, count; int32_t server_pid; uint32_t reserved; }; // then count processes
// Read-only, negotiated by CAP_INSPECT. Request body is one dw2_identity.
// On refusal only id and status are populated; owner and all geometry are zero.
// No table enrollment, mutation, journal write or visual evidence is implied.
struct dw2_inspect_reply { struct dw2_identity id; uint32_t status; int32_t owner;
                          double transform[6], bounds[4], screen_rect[4]; };

_Static_assert(sizeof(struct dw2_header)==16,"header");
_Static_assert(sizeof(struct dw2_hello)==88,"hello");
_Static_assert(sizeof(struct dw2_hello_reply)==48,"hello reply");
_Static_assert(sizeof(struct dw2_identity)==24,"identity");
_Static_assert(sizeof(struct dw2_record)==80,"record");
_Static_assert(sizeof(struct dw2_space_record)==88,"Space record");
_Static_assert(sizeof(struct dw2_frame)==8,"frame");
_Static_assert(sizeof(struct dw2_frame_reply)==24,"frame reply");
_Static_assert(sizeof(struct dw2_heartbeat_reply)==16,"heartbeat reply");
_Static_assert(sizeof(struct dw2_veil)==8,"veil request");
_Static_assert(sizeof(struct dw2_veil_reply)==8,"veil reply");
_Static_assert(sizeof(struct dw2_restore_result)==32,"restore result");
_Static_assert(sizeof(struct dw2_restore_reply)==16,"restore reply");
_Static_assert(sizeof(struct dw2_probe_entry)==112,"probe entry");
_Static_assert(sizeof(struct dw2_probe_reply)==72,"probe reply");
_Static_assert(sizeof(struct dw2_process)==24,"process instance");
_Static_assert(sizeof(struct dw2_enrollment_reply)==16,"enrollment reply");
_Static_assert(sizeof(struct dw2_inspect_reply)==144,"inspect reply");
_Static_assert(sizeof(struct dw2_enrollment_reply)+DW2_MAX_PROCESSES*sizeof(struct dw2_process)<=DW2_MAX_BODY,"largest enrollment fits");
_Static_assert(sizeof(struct dw2_frame)+DW2_MAX_RECORDS*sizeof(struct dw2_record)<=DW2_MAX_BODY,"largest frame fits");
_Static_assert(sizeof(struct dw2_frame)+DW2_MAX_RECORDS*sizeof(struct dw2_space_record)<=DW2_MAX_BODY,"largest Space frame fits");
_Static_assert(sizeof(struct dw2_probe_reply)+DW2_MAX_TABLE*sizeof(struct dw2_probe_entry)+16*sizeof(struct dw2_identity)<=DW2_MAX_BODY,"largest probe fits");
#endif
