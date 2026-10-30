# Compositor mode module

How the shell presents real windows through the Dock helper and what it does with pointer motion below `interact_min` (code in `native/app/CompositorMode`). Beside this file are [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md), the design and known limits of compositor mode, and [NATIVE-DRAG-ROUTING.md](NATIVE-DRAG-ROUTING.md), why a captured picture cannot receive a drag. The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Native presentation through a cooperative helper

`--native-helper RUNTIME_DIR NONCE_FILE` selects native presentation with
`--windowed --only-pid HELPER_PID` for a cooperative helper. The one scoped process
must be the process hosting it. An allowlist helper may instead serve the exact
finite process instances named by `--only-pid`: the negotiated read-only
`ENROLLMENT` report must match every PID and birth timestamp, with no extra
process. Helpers with unrestricted same-user scope, or allowlists they cannot
report, are refused before any canvas opens. This prepares the client for broader
native support; no third-party application or Dock injection has been validated.
The client checks the helper's reported PID against the Unix socket's kernel
peer PID, bounds every negotiated frame/body/lease value, and requires the two
connections to describe the same server and session token. A partial heartbeat
reply cannot keep the control connection alive beyond its lease.
The nonce file must be an absolute path to a
regular file owned by this user, mode 0600, containing the helper's 64 hex
characters (an optional final newline is accepted). A symlink is refused.
Nothing is injected or loaded, and no system setting is changed. Invalid
arguments exit 64; a refused helper or scope exits 69 before opening the canvas.

The `--native-helper RUNTIME_DIR NONCE_FILE` pair may be repeated for up to four
explicit helpers. Each grouped helper must support the authenticated enrollment
audit. Its process instances must be a subset of `--only-pid`, and the helpers'
disjoint union must match that scope exactly. Repeated runtimes, overlapping
processes, extra processes and missing scope members are refused before the
canvas or IPC socket opens. Frames and release records route to the owning
helper; no helper gains another process's windows. Losing one helper ends native
presentation immediately and drains the other sessions to restore their windows.
Debug counters remain available per helper; summed counters do not imply a shared
sequence, refresh boundary or optical synchronization across processes.

`./tests/e2e/scoped-native.sh` is read-only by default. Its explicit
`--live-owned-fixture` mode starts disposable fixtures, checks startup refusals,
adoption, focus, pan, zoom, move, resize, alpha, parking, continuous movement,
quit, client SIGKILL, a stalled main thread, helper loss and the default overlay
path. An independent WindowServer connection checks transforms and alpha before
and after recovery; a second disposable process checks that the scope excludes
its windows. Children are removed on every exit.

Under `--only-pid`, the scoped native tests also set `INFINIFY_DEBUG_TEST_PANEL=1` and, with native presentation, `INFINIFY_DEBUG_NATIVE_PANEL=1` (and `INFINIFY_DEBUG_NATIVE_VIEWS=2` with `--debug-pointer` to split the one test panel into two views): the test's canvas panel then stays visible at the floating level, ignores mouse events outside native presentation and keeps ordinary canvas input for its replica destinations inside it. These switches are read in `Desktop+Rendering.m` only with `--only-pid`; none is set in a normal run.

The whole-desktop form of this presentation, compositor mode of the Dock helper, is described in [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md): one independent view per display, the arrival veil, dragging, resizing and context menus of a transformed window, drags between windows, popups, session and sleep, quit and restore, and its known limits.

## Pick-mode motion

One behaviour of the shell; the long form is in
[POINTER.md](../../../crates/desktop/POINTER.md#motion-below-interact_min-compositor-mode-2026-10-30).

**Motion below `[zoom] interact_min` reaches no application in compositor mode.** `-[Desktop nativeInput:event:]` answers YES for a
mouse-moved packet over a managed native window that is a pick target (`-pickMotionAt:window:`, which is `DWPickMotion` in
`DWControllerHit.h` over the last render's output list and the window's placement: no controller call per packet), after the canvas
has had the motion, and `DWNativeInput` then drops it. Regressions:
`DWControllerHitTests.m` (`tests/e2e/controller-hit.sh`) and `DWNativeInputTests.m` (`tests/e2e/native-input-policy.sh`).
Not shown: a physical device, an application's cursor shape over a target, the canvas's own hover and edge pan during the same motion.
