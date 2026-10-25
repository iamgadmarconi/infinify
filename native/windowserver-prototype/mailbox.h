// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IFWSP_MAILBOX_H
#define IFWSP_MAILBOX_H
#include "kernel-process-identity.h"
#include "../privileged/protocol2.h"
#include <stdatomic.h>
#include <sys/stat.h>

#define IFWSP_MB_MAGIC "IFWSHM1"
#define IFWSP_MB_VERSION 1u
#define IFWSP_MB_LANES 2u
#define IFWSP_MB_SLOTS 64u
#define IFWSP_MB_BODY 2048u
#define IFWSP_MB_REQUEST_FILE "requests.shm"
#define IFWSP_MB_REPLY_FILE "replies.shm"
enum { IFWSP_MB_CONTROL=0, IFWSP_MB_HEARTBEAT=1 };

// One writer per lane. The complete packet is copied before published release;
// its slot is not overwritten until the peer acknowledges consumption.
struct ifwsp_mb_packet {
    uint64_t generation;
    struct ifwsp_kernel_process_identity writer;
    struct dw2_header header;
    unsigned char body[IFWSP_MB_BODY];
};
struct ifwsp_mb_lane {
    _Alignas(64) _Atomic uint64_t published;
    // Acknowledgement of packets read from the OPPOSITE file's same lane.
    _Atomic uint64_t consumed;
    // Request file only: one C producer process/lane. Zero means unclaimed.
    _Atomic uint64_t producer_pid;
    // Request file only, monotonically increasing generation closed by client.
    _Atomic uint64_t closed_generation;
    struct ifwsp_mb_packet slots[IFWSP_MB_SLOTS];
};

// Immutable after READY release. HMAC covers bytes [0,offsetof(proof)); all
// padding is initialized to zero. Only WindowServer can write the reply file.
struct ifwsp_mb_attestation {
    char magic[8];
    uint32_t version,size;
    struct ifwsp_kernel_process_identity server;
    uint8_t boot_uuid[16],image_uuid[16],payload_sha256[32],config_sha256[32];
    uint64_t start_ns,deadline_ns;
    uint32_t lifetime_ms,max_records,max_body,reserved;
    uint8_t proof[32];
};
struct ifwsp_mailbox {
    _Alignas(64) _Atomic uint64_t ready;
    _Atomic uint64_t ended;
    // Every publication/consumption/close bumps this shared wake generation.
    // Both controller threads use atomic fetch_add, avoiding lost lane wakes.
    _Atomic uint64_t doorbell;
    // Request-only allocation; never reset across sequential sessions.
    _Atomic uint64_t next_generation;
    // Reply-only active control generation; zero after exact restoration.
    _Atomic uint64_t active_generation;
    struct ifwsp_mb_attestation attestation;
    struct ifwsp_mb_lane lane[IFWSP_MB_LANES];
};
_Static_assert(ATOMIC_LLONG_LOCK_FREE==2,"mailbox needs lock-free 64-bit atomics");
_Static_assert(_Alignof(struct ifwsp_mailbox)>=64,"mailbox word alignment");
_Static_assert(offsetof(struct ifwsp_mailbox,doorbell)%8==0,"doorbell alignment");
_Static_assert(offsetof(struct ifwsp_mb_lane,published)%8==0,"lane counter alignment");
_Static_assert(sizeof(struct dw2_frame)+16*sizeof(struct dw2_record)<=IFWSP_MB_BODY,"fixture frame fits mailbox");
_Static_assert(sizeof(struct dw2_probe_reply)+16*sizeof(struct dw2_probe_entry)<=IFWSP_MB_BODY,"fixture probe fits mailbox");
_Static_assert(sizeof(struct dw2_restore_reply)+16*sizeof(struct dw2_restore_result)<=IFWSP_MB_BODY,"fixture restoration fits mailbox");

struct ifwsp_mb_mapping {
    int directory_fd,request_fd,reply_fd;
    struct ifwsp_mailbox *own;
    const struct ifwsp_mailbox *peer;
    struct stat directory_stat,request_stat,reply_stat;
    bool server;
};

uint64_t ifwsp_mb_now_ns(void);
int ifwsp_mb_boot_uuid(uint8_t uuid[16]);
// Validates nofollow directory and both single-link regular files, exact sizes,
// mode0600 and directional owners. Keeps descriptors/mappings until unmap.
int ifwsp_mb_map(const char *runtime,uid_t controller,uid_t server,bool server_side,
                 struct ifwsp_mb_mapping *mapping);
void ifwsp_mb_unmap(struct ifwsp_mb_mapping *mapping);
void ifwsp_mb_signal(struct ifwsp_mailbox *own);
// timeout_ms=0 is nonblocking (EAGAIN). Other errors are errno-style positive.
int ifwsp_mb_push(struct ifwsp_mb_mapping *mapping,unsigned lane,
                  const struct ifwsp_mb_packet *packet,uint32_t timeout_ms);
int ifwsp_mb_pop(struct ifwsp_mb_mapping *mapping,unsigned lane,
                 struct ifwsp_mb_packet *packet,uint32_t timeout_ms);
int ifwsp_mb_peek(struct ifwsp_mb_mapping *mapping,unsigned lane,
                  struct dw2_header *header,uint64_t *generation);
int ifwsp_mb_wait(struct ifwsp_mb_mapping *mapping,uint64_t observed,uint32_t timeout_ms);
void ifwsp_mb_sign_attestation(struct ifwsp_mb_attestation *attestation,const char nonce[64]);
bool ifwsp_mb_verify_attestation(const struct ifwsp_mb_attestation *attestation,const char nonce[64]);
#endif
