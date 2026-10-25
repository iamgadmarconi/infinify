// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IF_WINDOWSERVER_PROTOTYPE_H
#define IF_WINDOWSERVER_PROTOTYPE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "../privileged/protocol2.h"
#include "kernel-process-identity.h"

#define IFWSP_CONFIG_MAGIC "IFWSP03"
#define IFWSP_CONFIG_VERSION 3u
#define IFWSP_MAX_WINDOWS 16u
#define IFWSP_MAX_LIFETIME_MS 60000u

// This experimental format is deliberately independent of production enrollment.
// It authorizes only the exact disposable process and explicit native window list.
struct ifwsp_window {
    struct dw2_identity identity;
    int32_t owner;
    uint32_t reserved;
    double original_transform[6];
    double original_bounds[4];
    double original_screen_rect[4];
};

struct ifwsp_config {
    char magic[8];
    uint32_t version, size, controller_uid, fixture_uid;
    int32_t server_pid, fixture_pid;
    uint64_t server_birth_sec, server_birth_usec, fixture_birth_sec, fixture_birth_usec;
    struct ifwsp_kernel_process_identity fixture_kernel_identity;
    struct ifwsp_kernel_process_identity server_kernel_identity;
    uint8_t boot_uuid[16],payload_sha256[32];
    uint64_t runtime_dev,runtime_ino,request_dev,request_ino,reply_dev,reply_ino;
    uint32_t lifetime_ms, window_count;
    char nonce[64];
    char runtime[104];
    struct ifwsp_window windows[IFWSP_MAX_WINDOWS];
};

// Server ABI adapter. This interface must never call an SLS/CGS client stub.
// bind performs symbol/image/code pin checks only. call serializes access on the
// real server execution context. No mutation is allowed on an unresolved ABI.
struct ifwsp_abi {
    bool verified;
    const char *reason;
    const char *image_uuid;
};

struct ifwsp_abi ifwsp_bind_server_abi(void);
bool ifwsp_server_call(const struct ifwsp_config *config, void (*operation)(void *), void *context);
bool ifwsp_server_restore_call(const struct ifwsp_config *config, void (*operation)(void *), void *context);
bool ifwsp_server_inspect(uint32_t wid, int32_t *owner, int32_t *pid,
                          double transform[6], double bounds[4], double screen_rect[4]);
bool ifwsp_server_transform(uint32_t wid, const double transform[6]);
bool ifwsp_server_transform_many(uint32_t count, const uint32_t *wids,
                                 const double (*transforms)[6]);
bool ifwsp_server_original_restored(uint32_t wid);

#endif
