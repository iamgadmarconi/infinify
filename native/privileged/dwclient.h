// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_CLIENT_H
#define DW_PRIVILEGED_CLIENT_H
#include <stddef.h>
#include <stdint.h>
#include "protocol2.h"
// Client of the transform helper's protocol v2 (README.md "Protocol v2"), for the
// shell to link. Plain C and pthreads. No call here waits on the helper beyond its
// stated bound, whatever the helper does: a frame is handed to a writer thread and
// the call returns; the lease is kept by a heartbeat thread on a second connection.
typedef struct dw_client dw_client;
enum { DW_CLIENT_OK=0, DW_CLIENT_LOST=-1, DW_CLIENT_TIMEOUT=-2, DW_CLIENT_REFUSED=-3, DW_CLIENT_INVALID=-4, DW_CLIENT_NO_V2=-5 };
enum { DW_LOST_EOF=1, DW_LOST_WRITE_TIMEOUT=2, DW_LOST_HEARTBEAT=3, DW_LOST_PROTOCOL=4 };
struct dw_client_info { uint32_t lease_ms, max_records, caps, scope, queue; int32_t server_pid; };
// submitted = dropped_local + written (+ at most one still waiting to be written);
// written = applied + superseded + discarded (+ those not yet answered).
struct dw_client_stats {
    uint64_t submitted, written, dropped_local, applied, superseded, discarded, records_applied, records_failed,
             heartbeats_sent, heartbeats_acked, last_applied_seq;
};
// Both run on a library thread and must not call dw_client_close.
struct dw_client_callbacks {
    void *context;
    // The helper applied frame seq; status holds one DW2_* record status per record.
    void (*frame_result)(void *context, uint64_t seq, const uint8_t *status, uint32_t count);
    // Called once. The helper is gone or not answering: it restores everything it
    // held as soon as it is able to, and every later call returns DW_CLIENT_LOST.
    void (*lost)(void *context, int reason);
};
// Connects both connections and starts the threads. Waits at most timeout_ms,
// retrying while another session holds the helper. DW_CLIENT_REFUSED: the helper
// answered and said no (wrong nonce or version). DW_CLIENT_NO_V2: nothing answered
// and the runtime has v1's helper.sock but no v2.sock, so a helper is there whose
// protocol v2 did not start. DW_CLIENT_TIMEOUT: nothing answered, for any other
// reason (no helper yet; or a v2.sock left by a dead one). DW_CLIENT_INVALID: bad
// arguments, or memory or a thread could not be had. nonce64 is 64 hexadecimal
// characters.
int dw_client_open(const char *runtime, const char *nonce64, const struct dw_client_callbacks *callbacks,
                   uint32_t timeout_ms, dw_client **out, struct dw_client_info *info);
// Never touches a socket: copies the records and returns. A frame not yet written
// when the next one arrives is replaced by it (dropped_local).
int dw_client_submit_frame(dw_client *client, const struct dw2_record *records, uint32_t count, uint64_t *seq);
// The raw probe reply (struct dw2_probe_reply, table entries, fixture identities).
int dw_client_probe(dw_client *client, uint32_t timeout_ms, void *reply, size_t capacity, size_t *length);
// Reads the helper's exact process scope before any frame is submitted. Fails on
// unsupported capability, malformed/duplicate identities, or insufficient space.
// Count is written only on success. This does not enroll or mutate any window.
int dw_client_enrollment(dw_client *client, uint32_t timeout_ms, struct dw2_process *processes,
                         uint32_t capacity, uint32_t *count);
// Asks the helper to put every window back. A frame submitted and not yet written
// is dropped. On DW_CLIENT_TIMEOUT the request may still be carried out.
int dw_client_restore_all(dw_client *client, uint32_t timeout_ms, struct dw2_restore_result *results,
                          uint32_t capacity, uint32_t *count, uint32_t *pending);
void dw_client_stats(dw_client *client, struct dw_client_stats *stats);
// Closes both connections, which makes the helper restore everything, and joins
// the threads (bounded: each is woken by the shutdown).
void dw_client_close(dw_client *client);
#endif
