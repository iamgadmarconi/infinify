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
/* Independent owned copy; NULL for NULL input or panic. Access the source
 * exclusively during this call. The copy may move to a worker thread, with
 * serialized access and exactly one destroy, independently of the source. */
DriftDesktop *driftwm_desktop_clone(const DriftDesktop *controller);
/* NULL is a no-op; live handles must be destroyed exactly once. */
void driftwm_desktop_destroy(DriftDesktop *controller);
/* One native readback observation. owner=0 means no optional logical owner. */
typedef struct DriftDesktopObservation {
    uint64_t window;
    int64_t birth_sec;
    double x, y, width, height;
    int32_t pid, birth_usec;
    uint32_t wid, owner, buffer_width, buffer_height;
} DriftDesktopObservation;
/* Allocation-free read-only query; 1 means Observe changes no source/world state
 * and needs no gesture/structural settlement. 0 means use the ordinary request
 * path (also for NULL, invalid input or panic). Serialize handle access. Caller
 * still freshly validates native PID/birth/window/owner and geometry. */
uint8_t driftwm_desktop_observation_current(const DriftDesktop *, const DriftDesktopObservation *);
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
/* `Infinify msg` IPC client; argv holds the arguments after "msg". Needs no handle.
 * Returns the process exit status: 0, or non-zero after an error on stderr. */
int32_t driftwm_desktop_msg(int32_t argc, const char *const *argv);
#ifdef __cplusplus
}
#endif
#endif
