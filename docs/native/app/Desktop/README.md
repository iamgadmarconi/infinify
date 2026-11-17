# Desktop module

How the shell captures windows and draws them to its panels: capture streams, export snapshots, drawables and saves (code in `native/app/Desktop`, chiefly `LiveSource` and the capture, rendering and session categories of `Desktop`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Press admission

`DWPressAdmission` owns session/annotated press classification, native title and
traffic-light admission, Fill refusal pairs, native drag takeover and title click
slop. `DWPressPairing` is its private physical-pair implementation; `DWNativeInput`
only installs taps and applies its pass/drop result. `DesktopView` hands AppKit
presses as raw events, and title motion/release bookkeeping, to the same module; resize execution
and controller gesture updates remain with their existing hosts.

Its internal seams accept `DWPressNativeLookup` (the real WindowServer/AX adapter,
`DWPressNativeAdapter`, including physical button state, clocks and the existing
native takeover/reposition effects) and `DWPressSceneLookup` (renderer-ordered hits, mouse
bindings and unchanged JSON controller calls, `DWPressSceneAdapter`). Missing
evidence refuses admission; a swallowed down keeps its tail even after logical
cancellation. Session admission precedes annotated admission on the main thread.
Chrome retention, the 0.5 s title lifetime, 1 s green lifetime and the one-entry
on-demand title cache live in admission, not the AX lookup. The 0.2 s periodic
refresh runs only for the hovered window while the pointer is in its reported
title/caption/toolbar/button regions, expanded by 8 native points (at least 4
display points), or a conservative resize-edge ring. The ring contains the
controller's 8-canvas-point exterior and 5-native/3-display-point interior bands.
Missing, failed, incomplete or invalidated maps keep the entire hovered window
hot. An old map defines where to *refresh*, never where to claim a chrome press.
Focused windows are no longer refreshed merely for being focused.

Motion primes the hovered window with the existing 0.1/0.2 s throttles; a changed
hover target or the first motion after a 0.2 s rest bypasses the read throttle.
Existing frame/title/family observations, focus and display notifications prime
asynchronously too; observation batches coalesce stationary-hover re-resolution
to one main-queue callback instead of one WindowServer query per window.
The existing listen-only navigation tap observes qualifying
key-downs when ListenEvent access was already granted: Command/Control chords,
Escape and physical function keys F1–F20 only (integer CGEvent flags/key-code
checks, with no NSEvent conversion for plain typing). One read is requested 50 ms after the first key
of a burst and one 250 ms after its last key, coalesced with any in-flight read.
Plain typing schedules no reads; periodic band refresh remains independent.

A complete, settled last good map can refuse a point outside that band without
AX or WindowServer queries **inside the refusal**. It must still be the published
map for the same identity, controller generation, native bounds, chrome revision
and native session, with no read in flight, request outstanding or key burst owed.
The settled-content return precedes `decorationDragMiss`, so its debug miss line
is no longer printed; formats of the lines still printed are unchanged.
This is negative evidence only: it cannot authorize a canvas-owned press. All
other title/green checks retain their lifetimes, geometry/identity checks and
synchronous stale-map fallback. That fallback has a nominal 150 ms AX deadline
(20 ms per-message limit), plus owner WindowServer queries outside that deadline;
a failed/expired title read refuses chrome and leaves the native path available.
A synchronous fallback makes scheduling conservative until a complete scheduled
read publishes again. Failed/incomplete asynchronous reads retain cached maps
under the unchanged 0.5 s/exact-geometry rule.

Consequently there is no periodic chrome AX/WindowServer work with the pointer
parked in known content or outside managed windows; resting on chrome still
costs up to five reads/second. A silent layout change turning last-known content
into chrome under a stationary pointer now sends a subsequent press native
instead of recovering through the synchronous read. No freshness claim is made
for such unnotified changes. This scheduling change has compile-only verification;
live title drags/border resizes below zoom 1 after 1/5/60 s rests, focused and
unfocused, remain required for TextEdit, Finder and Chrome (Find bar on/off).

`LiveSource` still carries published chrome observations and their source-revision
tokens so discovery can invalidate them. Its native-drag ownership record remains
a published per-window fact, written/reset by admission and read by visibility,
navigation, Fill, rendering and tracking through an immutable dictionary view.
Display-topology handling asks admission to stamp the existing
`topology_changed`/`stable_since` facts without copying or replacing that record.
Session reset immediately invalidates its watch timer before dropping the record.
Neither change is new live proof.

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

`LiveSource` keeps `contentPointSize` with the retained pixels' `contentRect`:
ScreenCaptureKit's `ContentRect` size divided by `ContentScale` (the pixel crop
also includes `ScaleFactor`). Identical samples still skip installation when
point-size jitter is below 0.01 pt on each axis, the crop and buffer size match,
and no dirty rectangles are reported, unless a forced or restarted frame needs
installation. `clearSample` and full-buffer `installPixels:` reset
`contentPointSize` to zero.

`INFINIFY_DEBUG_FAMILIES=1` logs up to 4096 child-capture lifecycle records:
creation, first frame, configuration, retirement and fixed failure codes. These
opt-in records contain numeric identities, density and cadence, without titles
or image content.

Screenshot exports (`window --id`, `all`, viewport and region) prepare separate
one-shot images without changing the camera, focus, window placement or live-stream
configuration. Native export first copies the untransformed WindowServer backing
surface on a read-only worker (`DWNativeCopyWindowImage`); this avoids
ScreenCaptureKit's display lookup for windows parked outside every display and
keeps source detail independent of camera zoom. All native windows first use
the same legacy `CGWindowListCreateImage` entry point, resolved by name at runtime.
Its ABI is recorded from the SDK's `CoreGraphics/CGWindow.h:271-274`; although
unavailable at compile time in current SDKs, it may still be present at runtime.
Missing symbols or NULL images fall back to the existing ScreenCaptureKit path.
Transparent or uniform images retry on the worker for at most one second and
are skipped if still empty. An off-viewport window is captured as last drawn by
its application; applications may redraw asynchronously after their state changes.
This can lag application state: one guest TextEdit probe still showed its old body
immediately after an off-viewport text change; a later follow-up showed the new
digits, but the change-to-repaint latency was not measured. There is no repaint-
latency guarantee; timed TextEdit and browser checks remain for the final live test.
No snapshot is requested without existing Screen Recording access, and export
does not call a permission-request API. The legacy API's permission behavior on
a normally launched installation and on Retina still requires live verification.


A failed live root is omitted with its entire attached family, including its
chrome, rather than aborting other windows. Minimized windows are skipped, not
drawn from an earlier frame. The CLI prints one sanitized line per skipped root
to stderr (including the logical id, PID and title). Successful replies may carry
`Ok.Screenshot.warnings`; stdout remains the PNG path, JSON or PNG bytes as
requested. Export fails clearly if none of the requested live windows produced
pixels. Stand-in-only window or canvas exports still succeed without warnings:
stand-ins are canvas drawings, not live capture requests. Closed-window stand-ins
and the controller's whole-canvas framing remain unchanged, so a skipped root
does not shrink the `all` image.

Preparation is asynchronous. A two-second capture deadline discards incomplete
families and finishes with any complete, revalidated families. Native identities,
bindings, root/member bounds and family membership are checked before composition;
late capture completions cannot install pixels. One-shot images are released
after composition. Offscreen Metal composition and readback still run on main;
PNG compression and file writing use a serial utility worker holding an immutable
image. Backing-surface raster dimensions come from WindowServer, not the current
display's backing scale; requested export dimensions remain canvas units times
`--scale`.

The release app compiles its native C/Objective-C adapters with `-O2`, alongside
the optimized Rust release library. An active frame driver holds a balanced
`NSActivityUserInitiatedAllowingIdleSystemSleep` activity, ending it when that
driver stops. This declares ongoing requested frame work between input events
and prevents App Nap deferral while allowing idle system and display sleep,
under [Apple's activity guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).

In desktop mode, `openPanels` with no AppKit screens returns before navigation,
resize, native input and window discovery, keeping `sessionAwaitingCanvas` set so
the loaded scene is not saved without outputs. `screensChanged:` and `returned`
reopen the panels when a display returns. Keys follow the panels: system-owned
keys (the session key filter of `DWHotKeys`: Command-Tab, Mission Control, the
stand-in Return and the native window controls) are taken only while a canvas
panel exists. A launch that has never opened a panel registers no key at all
until one opens. A canvas that had panels and then lost every display at runtime
keeps Infinify's own chords only (`-[DWHotKeys start:NO]`: Carbon hot keys other
than the system-owned ones, the Control-Option-Escape exit chord and the tap
watch), so quit keeps working; the full set returns with the panels.
`canvasKeysOffered` records that a panel opened, and is reset when the canvas
closes. A config reload while only own keys run restarts them in the same mode.
With `INFINIFY_DEBUG`, `{"DebugInput":{}}` reports `keys` (`running`, `panels`,
`system_filter`, `carbon_registered`, `exit_chord`, `quit`, `actions`), and
stderr has `debug: keys started ...` and `debug: keys stopped` lines. These are
registration state, not a delivered key press.

`INFINIFY_DEBUG_HIDE_SCREENS` is a debug-only seam for that path. It is read
once, at the process's first `openPanels`, and never without `INFINIFY_DEBUG`.
`N` hides AppKit's screens from `openPanels` (and from the screen-change
comparison with `panelScreens`) for N seconds after that first call;
`A-B[,C-D...]` (at most four increasing windows, 0 <= A < B <= 3600 s) hides them
in each window. Every window boundary processes a screen change as AppKit's
notification would, so a window starting after 0 is a runtime loss of every
display and its end their return. A malformed value is ignored with one debug
line. Nothing else (the native presenter, pointer code, windowed runs) sees the
hidden list. `tests/e2e/zero-screen-keys.sh --live-guest` uses it.

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
request; the worker time-slices large source audits, timestamps each source
when read and leaves any unread tail queued for the next slice, while the main
consumer rejects late deliveries (> 100 ms after completion) or individual
samples older than 100 ms and revalidates scope, identity, prior bounds and
event/resize tokens before applying results.
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
