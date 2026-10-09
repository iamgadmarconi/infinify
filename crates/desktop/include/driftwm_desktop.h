/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DRIFTWM_DESKTOP_H
#define DRIFTWM_DESKTOP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Opaque handle. Serialize access per handle; distinct handles are independent. */
typedef struct DriftDesktop DriftDesktop;
DriftDesktop *driftwm_desktop_create(void);
/* NULL is a no-op; live handles must be destroyed exactly once. */
void driftwm_desktop_destroy(DriftDesktop *controller);
/* Readable UTF-8 bytes, length <= 1 MiB; need not be NUL terminated.
 * Handle and byte storage must remain valid throughout the call.
 * Returns allocated NUL-terminated JSON, or NULL on response-construction panic.
 * {"version":1,"ok":true,"data":...} or {"version":1,"ok":false,"error":"..."}.
 * Calls perform logical controller operations only, never native input delivery.
 * Caller MUST revalidate source PID/birth/window/owner around event delivery.
 * Invalid/dangling non-NULL pointers and concurrent access are caller errors.
 */
char *driftwm_desktop_request(DriftDesktop *, const uint8_t *bytes, size_t len);
/* Free only unmodified returned response pointers, exactly once; NULL is safe. */
void driftwm_desktop_response_free(char *response);
#ifdef __cplusplus
}
#endif
#endif
