# Cooperative live surfaces experiment

This fixture demonstrates **two simultaneous live presentations of one cooperative
native Core Animation scene across processes**, with different camera transforms
and clipping. It does not acquire an arbitrary application's NSWindow surface,
route input, or implement the persistent desktop canvas.

```sh
./scripts/build-surfaces.sh
./tests/e2e/live-surfaces.sh
./tests/e2e/live-surfaces.sh --live-owned-fixture
```

The test launcher builds only by default; `--live-owned-fixture` explicitly opts
into the live E2E. The E2E creates unique evidence directories under `target/surfaces/evidence` (or
the first argument), opens one disposable borderless host window for six seconds,
and tests shorter lifecycle cases. It never requests permissions or changes user
settings. Pixel verification requires existing screen-capture access: without it,
the host still records capabilities but the E2E fails rather than claiming proof.
Only the exact host PID/window ID is passed to ScreenCaptureKit's desktop-independent
window capture. No desktop pixels, other application windows, native transform
setters, input events, or window injections are used. The test does briefly place
its own window in front; existing window geometry is not modified.

For an explicit bounded manual run, create an empty evidence directory and run
`target/surfaces/surfaces --host DIRECTORY SECONDS` (1–30 seconds). Never reuse an
existing run directory. Source context IDs and process IDs are transient fixture
observations, not persistent window identities or an authorization interface.

## What runs

The host starts a separate source process. The source exports a private `CAContext`
ID and updates a red/blue layer every second. The host creates two `CALayerHost`
objects bound to that same ID. Each sits in its own clipping layer. Source content
is 400×300; cameras use top-left world coordinates:

| Camera | Viewport | Pan | Zoom |
|---|---|---|---|
| A | (20,20), 400×300 | (0,0) | 1.0 |
| B | (460,20), 300×300 | (40,30) | 1.5 |

Zoom 1.5 deliberately exercises the private API's scaling capability. It is
independent of the canvas reducer's current maximum zoom 1.0 and does not change
that product policy. These are two camera viewports in one physical host window;
separate displays, refresh rates, color profiles, and hot-plug are untested.

ScreenCaptureKit is used **only to verify the host window's rendered pixels**, not
as the presentation transport. Captures are asynchronous, so source heartbeat
metadata can lead a captured frame around a color transition. Assertions therefore
use observed pixels, require both colors over time in both copies, and compare the
two copies within each captured frame; heartbeat phase is not proof of presentation.

## Verified run

`evidence/verified/run-w9_4wioe/verification.json` records the focused E2E pass on
arm64 macOS 27.2 (26B5091g), SDK 27.0, minimum deployment target 26.0, in the
coordinator's SIP-enabled host configuration. No SIP changes were made. Runtime
on macOS 26 is untested. `pixels/receipt.json` contains six captures and measurements;
the adjacent PNGs contain only the disposable host window.

- Both copies visibly alternated red and blue in the six captures.
- Green marker bounds: A `(80,90,50,40)`, B `(490,80,75,60)`.
- Changing panel bounds: A `(200,120,100,80)`, B `(670,125,90,120)`.
  B's uncut width is 150 pixels; the viewport clips it to 90 pixels.
- No detected colored pixels escaped either clip.
- Host deadline, SIGTERM, and SIGINT closed the host and reaped its source.
- Standalone source deadline passed. After host SIGKILL, the source detected
  parent loss and exited; the E2E confirmed its PID no longer existed.

The source also has a deadline and parent-PID check. Host signal handlers set a
flag consumed on the run loop; cleanup terminates and reaps only its `NSTask`
child. A two-second cleanup fallback kills that exact child if necessary. Abrupt
host death requires no restoration of unrelated windows: the only host window is
owned by the terminating process. Native context/host existence and successful
API calls alone never pass the pixel test.

## Remaining boundary

This proves a reusable cooperative surface can appear twice. A normal third-party
NSWindow does not voluntarily export a CAContext ID. Obtaining a usable foreign
context or substituting a live per-window capture transport remains unproven.
SkyLight context-getter symbols without a verified ABI are not invoked here.
Input, focus, popups, editable controls, native occlusion, performance/latency,
protected content, and lifecycle recovery across app relaunches are untested.

## Provenance

New GPL-3.0-or-later implementation. Private ABI declarations were checked against
[Chromium remote_layer_api.h](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/base/cocoa/remote_layer_api.h),
observed blob `8a11a77f1a502b601015793738ec690b74932b11` (2026-10-09). Chromium's file is
BSD licensed; its implementation was not copied. The system SDK provides AppKit,
Core Animation, and ScreenCaptureKit declarations. Private APIs may change between
OS versions; this probe is evidence for this host, not a compatibility guarantee.
