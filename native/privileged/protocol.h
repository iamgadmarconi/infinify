// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_PROTOCOL_H
#define DW_PRIVILEGED_PROTOCOL_H
#include <stdint.h>
#define DW_PROTOCOL_VERSION 1
#define DW_MAX_PACKET 4096
#define DW_LEASE_MS 2000
// Same-machine JSON-lines protocol. Exact schema and lifecycle: README.md.
// Dock starts only with an explicit private loader sidecar. Fixture host uses
// this entrypoint to enroll only its own NSWindow.
int dw_privileged_fixture_start(const char *directory, const char *nonce, uint32_t wid);
#endif
