// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_PROTOCOL_H
#define DW_PRIVILEGED_PROTOCOL_H
#include <stdint.h>
#define DW_PROTOCOL_VERSION 1
#define DW_MAX_PACKET 4096
#define DW_LEASE_MS 2000
// Same-machine JSON-lines protocol. Exact schema and lifecycle: README.md.
// Dock starts only with an explicit private loader sidecar. Fixture host uses
// this entrypoint to enroll only its own NSWindow. allowlistJSON is an optional
// JSON array of {pid,birth_sec,birth_usec}; non-NULL pins scope to those processes
// (used to exercise the spike allowlist refusal cooperatively).
int dw_privileged_fixture_start(const char *directory, const char *nonce, uint32_t wid, const char *allowlistJSON);
// The same for several of the host's own windows (at most 16): v1 keeps the first as
// its one window, protocol v2 may name any of them. v2OnMainQueue: 0 own queue,
// 1 main queue, negative for the build's default.
int dw_privileged_fixture_start_windows(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, const char *allowlistJSON, int v2OnMainQueue);
#endif
