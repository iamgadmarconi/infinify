# Desktop module

How the shell captures windows and draws them to its panels: capture streams, export snapshots, drawables and saves (code in `native/app/Desktop`, chiefly `LiveSource` and the capture, rendering and session categories of `Desktop`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Capture and rendering performance

Managed overlay streams capture enough pixels for their largest placement on any
output, using that output's backing scale. Density is rounded up in factors of
sqrt(2), between 1/32 and the original 2 pixels per native point. This limits
rounding overhead to twice the clamped demand's pixel area before integer-pixel rounding.
A larger placement
or native size change updates immediately; a smaller budget waits for half a
second of stable demand. Only one configuration update is outstanding per
source. Buffer resolution does not change native bounds, world rectangles,
input coordinates or crop geometry. Pinned windows retain their screen density.
Manual capture retains its original resolution rules. Requested capture cadence follows the fastest
display and is not reduced to obtain pixel savings; actual source delivery can
be slower and is measured separately.

`INFINIFY_DEBUG_FAMILIES=1` logs up to 4096 child-capture lifecycle records:
creation, first frame, configuration, retirement and fixed failure codes. These
opt-in records contain numeric identities, density and cadence, without titles
or image content.

Overlay exports request full-resolution one-shot ScreenCaptureKit samples when
the live stream has a smaller raster, including a stopped source needed by the
export. Preparation is asynchronous and returns an IPC reply after actual pixels
arrive, with a two-second deadline. The main queue remains available during
capture setup. Temporary samples leave stream budgets unchanged and are released
after composition; cancellation prevents a late callback from installing them.
No snapshot is requested without existing Screen Recording access. Offscreen
Metal composition and readback still run on main after capture finishes; PNG
compression and file writing use a serial utility worker holding an immutable
image.

The release app compiles its native C/Objective-C adapters with `-O2`, alongside
the optimized Rust release library. An active frame driver holds a balanced
`NSActivityUserInitiatedAllowingIdleSystemSleep` activity, ending it when that
driver stops. This declares ongoing requested frame work between input events
and prevents App Nap deferral while allowing idle system and display sleep,
under [Apple's activity guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).
Screen-parameter notifications retain the existing canvas panels and layers
when physical display IDs, full frames, backing scales and refresh rates are
unchanged; a genuine display change ends the old frame driver before replacing
its output layer. Desktop Metal layers acquire drawables on a private serial queue, retaining up
to two ready ones (at most the drawable pool size minus one). Acquisition publishes
the ready set under a short lock on the worker; a screen callback can consume it
before its main-queue notification runs. Each worker batch may make up to two
sequential acquisitions to replenish that bounded set without waiting for main
to handle its notification. Each acquisition drains its own autorelease pool
before the next potentially blocking call; the layer's final release still
occurs on main.
They encode the latest scene only after
acquisition; no scene descriptions wait in a queue. A
missed frame remains owed and can retry within the current refresh's remaining
budget. A size or presentation-mode change discards obsolete acquisitions.
Input and the main run loop remain available during the wait in Apple's
[nextDrawable contract](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable%28%29).
 Continuous camera
commands and scroll gestures mark the scene for a coalesced save. Configured
desktop runs copy the controller on main and serialize, atomically replace and
sync the file on a serial worker. One save may run while one pending copy waits;
a newer pending copy replaces the obsolete one. Shutdown drains earlier saves
before its final synchronous save.
Native idle reconciliation batches the on-screen list, untransformed bounds and
missing/parked source metadata on a serial read-only worker, with at most one
batch outstanding. Immutable PID/birth/WID and binding tokens accompany each
request; the main consumer rejects batches older than 100 ms and revalidates
scope, identity, prior bounds and event/resize tokens before applying results.
Discovery retains the CG list's actual window order. Failed reads retain the
source, while absence or identity changes trigger a fresh synchronous check.
Event, input and resize reads remain synchronous and fresh. Native
mode skips capture-budget snapshots, and live native windows skip canvas-element
allocation while stand-ins and one-shot exports retain their rendering paths.
Native readback also uses an allocation-free controller query before `Observe`:
an unchanged source rectangle and buffer may skip the JSON transaction only when
the current world size already matches and no gesture, pending resize, fullscreen
restoration, pin, rule-sizing or lifecycle work requires settlement. This compares
the live controller, so a gesture end, rebind or logical size change cannot leave
a stored native-bounds cache looking current. Other observations retain the
ordinary transactional path and rollback behavior.
