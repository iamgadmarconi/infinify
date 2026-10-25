// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IFWSP_MAILBOX_CLIENT_H
#define IFWSP_MAILBOX_CLIENT_H

#include <stdint.h>
#include <sys/types.h>
#include "../privileged/protocol2.h"

typedef struct ifwsp_mailbox_client ifwsp_mailbox_client;

// Return zero or a positive errno value. No settings, native windows or peer
// process memory are changed by this transport. All file descriptors/mappings
// stay pinned to the opened inodes until close; no per-message file reopening.
// The nonce is exactly 64 lowercase ASCII hexadecimal characters, never logged.
// Open performs a DWv2 HELLO on role 1 (control) or role 2 (heartbeat). The latter
// requires the 16-byte session token returned by the control HELLO.
int ifwsp_mb_open(const char *runtime,const char nonce[64],pid_t server_pid,
                 uid_t server_uid,uint16_t role,const uint8_t token[16],
                 struct dw2_hello_reply *hello,ifwsp_mailbox_client **out);

// One sender and one receiver may use a handle concurrently. Multiple senders,
// multiple receivers, and concurrent close are unsupported. Neither operation
// acknowledges application or visible presentation: replies retain DWv2 meaning.
int ifwsp_mb_send(ifwsp_mailbox_client *client,uint16_t type,uint64_t seq,
                 const void *body,uint32_t length);
int ifwsp_mb_recv(ifwsp_mailbox_client *client,uint16_t *type,uint64_t *seq,
                 void *body,uint32_t capacity,uint32_t *length,uint32_t timeout_ms);

// Publish a close and interrupt bounded IO waits without unmapping. Safe while
// the handle has an active sender/receiver; join those threads before close.
void ifwsp_mb_shutdown(ifwsp_mailbox_client *client);

// Publish this lane's close epoch before unmapping it. Indices never reset.
// Call only after the sender and receiver have stopped using this handle.
void ifwsp_mb_close(ifwsp_mailbox_client *client);

#endif
