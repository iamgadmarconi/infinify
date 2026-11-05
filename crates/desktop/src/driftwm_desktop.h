/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DRIFTWM_DESKTOP_H
#define DRIFTWM_DESKTOP_H
#include <stddef.h>
#include <stdint.h>
/* Largest IPC request line in bytes. The shell's socket reader and the controller both enforce it. */
#define DRIFTWM_DESKTOP_MAX_REQUEST_BYTES 1048576
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
/* One controller source binding. owner=0 means no optional logical owner. */
typedef struct DriftDesktopSourceBinding {
    uint64_t generation;
    int64_t birth_sec;
    double x, y, width, height;
    int32_t pid, birth_usec;
    uint32_t wid, owner;
    uint8_t observation_known;
} DriftDesktopSourceBinding;
/* Allocation-free read-only query of the current binding of one scene window's
 * source (the snapshot's windows[].source). 1 fills the binding; 0 leaves it
 * untouched (NULL, absent window, unbound source or panic): fail closed. Grants
 * no native ownership; caller still validates native PID/birth/window/owner.
 * Serialize handle access. */
uint8_t driftwm_desktop_source_binding(const DriftDesktop *, uint64_t window, DriftDesktopSourceBinding *);
/* Allocation-free read-only query: may the shell remove a window now, given the current size
 * transaction (the snapshot's native_resize)? all_windows != 0 asks about every window and ignores
 * `window`. 1 stores the Boolean in *allowed; 0 leaves it untouched (NULL or panic) and the
 * caller must use the command path, never assume permission. No native ownership. Serialize
 * handle access. */
uint8_t driftwm_desktop_resize_removal_allowed(const DriftDesktop *, uint8_t all_windows, uint64_t window, uint8_t *allowed);
/* One output's screen rectangle (the snapshot's outputs[].screen_bounds). */
typedef struct DriftDesktopRect { double x, y, width, height; } DriftDesktopRect;
/* Allocation-free read-only queries of output screen geometry; screen-coordinate
 * lookup only, never native-window authority. output_screen_bounds: 1 fills the
 * rectangle; 0 leaves it untouched (NULL, unknown output or panic). output_count
 * and output_id_at walk the snapshot's outputs order (id_at: 1 fills the id, 0
 * for NULL, out of range or panic). Serialize handle access. */
uint8_t driftwm_desktop_output_screen_bounds(const DriftDesktop *, uint64_t output, DriftDesktopRect *);
size_t driftwm_desktop_output_count(const DriftDesktop *);
uint8_t driftwm_desktop_output_id_at(const DriftDesktop *, size_t index, uint64_t *id);
/* Readable UTF-8 bytes, length <= 1 MiB; need not be NUL terminated.
 * Handle and byte storage must remain valid throughout the call.
 * Returns allocated NUL-terminated JSON, or NULL on response-construction panic.
 * {"version":1,"ok":true,"data":...} or {"version":1,"ok":false,"error":"..."}.
 * Calls perform logical controller operations only, never native input delivery.
 * Caller MUST revalidate source PID/birth/window/owner around event delivery.
 * Invalid/dangling non-NULL pointers and concurrent access are caller errors.
 */
char *driftwm_desktop_request(DriftDesktop *, const uint8_t *bytes, size_t len);
/* Shell-owned memory of the last snapshot a reader reconstructed, for snapshot_delta. Not part of
 * any controller (a clone must not inherit it). Serialize access per cursor; free exactly once. */
typedef struct DriftDesktopSnapshotCursor DriftDesktopSnapshotCursor;
DriftDesktopSnapshotCursor *driftwm_desktop_snapshot_cursor_new(void);
/* NULL is a no-op. */
void driftwm_desktop_snapshot_cursor_free(DriftDesktopSnapshotCursor *cursor);
/* The data of a "snapshot" request as a change against the snapshot the caller holds, applied_token
 * being that snapshot's token (0: none). Read-only on the controller. Returns allocated JSON, freed
 * with driftwm_desktop_response_free; NULL only if response construction panics. On success:
 *   {"base":T,"token":N,"replace":{key:value,...},"remove":[key,...]}  when T is the cursor's token:
 *       set each replaced top-level key of the held snapshot, drop each removed key;
 *   {"token":N,"full":{...}}  otherwise: "full" is exactly the "data" of a "snapshot" request.
 * Failure (NULL arguments, controller error, panic) is {"version":1,"ok":false,"error":"..."}.
 * The cursor advances to N on every success: a caller that did not apply a reply must pass its old
 * token (or 0) and gets a full snapshot. */
char *driftwm_desktop_snapshot_delta(const DriftDesktop *controller, DriftDesktopSnapshotCursor *cursor, uint64_t applied_token);
/* Free only unmodified returned response pointers, exactly once; NULL is safe. */
void driftwm_desktop_response_free(char *response);
/* `Infinify msg` IPC client; argv holds the arguments after "msg". Needs no handle.
 * Returns the process exit status: 0, or non-zero after an error on stderr. */
int32_t driftwm_desktop_msg(int32_t argc, const char *const *argv);
#ifdef __cplusplus
}
#endif
#endif
