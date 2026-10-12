// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PRIVILEGED_PROTOCOL_H
#define DW_PRIVILEGED_PROTOCOL_H
#include <stdint.h>
// Fixture entrypoints for the sole binary protocol v2 server. Wire schema: protocol2.h.
// Dock starts only with an explicit private loader sidecar. Fixture entrypoints
// admit only their caller's listed NSWindows (at most 16). allowlistJSON is an
// optional array of exact {pid,birth_sec,birth_usec} process instances.
// v2OnMainQueue: 0 own queue, 1 main queue, negative for the build's default.
int dw_privileged_fixture_start_windows(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, const char *allowlistJSON, int v2OnMainQueue);
// Same finite owned-window scope, with FIXTURE_FAMILY advertised for the
// desktop's native parent/child path. The caller created every listed window.
int dw_privileged_fixture_start_family_windows(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, const char *allowlistJSON, int v2OnMainQueue);
#endif
