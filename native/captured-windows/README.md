# Live native-window capture and routed input

This bounded experiment captures a **real AppKit NSWindow in a separate process**
once with a live ScreenCaptureKit `SCStream`, then presents the same frames twice
using independent `AVSampleBufferDisplayLayer.sampleBufferRenderer` instances.
The views have separate pan, zoom, and clipping. The original native window stays
at its normal, unchanged desktop bounds behind the covering canvas panel; it is
never parked offscreen, transformed, or replaced by a custom exported surface.

```sh
./scripts/build-captured-windows.sh
./tests/e2e/captured-windows.sh
# Focused demo lifetime regression, without keyboard or activation requests:
./tests/e2e/captured-windows.sh --live-owned-fixture --demo-input-only
mkdir -p /tmp/infinify-demo-evidence-UNIQUE
./target/captured-windows/captured-windows --demo /tmp/infinify-demo-evidence-UNIQUE 30
```

The test launcher builds only by default; live fixture execution requires
`--live-owned-fixture`. The native binary's default invocation and `--help` are read-only. `--probe EMPTY_DIRECTORY 16`
runs the bounded scripted proof. `--demo EMPTY_DIRECTORY SECONDS` accepts 1–60
seconds and opens only its own host and disposable source. Existing screen capture
and accessibility access are required; preflight failure produces a receipt and
exit status 2 without requesting access. The experiment never changes SIP,
permissions, settings, or another application's window geometry. Runtime on
macOS 26 is untested; the arm64 binary has minimum deployment target 26.0.

Demo controls:

- Normal clicks and scrolling hit the real source controls through the selected
  view. A normal click requests ordinary activation of the disposable source, so
  subsequent physical keyboard input follows normal native application focus.
- Option-drag or Option-scroll pans that camera; Command-scroll or pinch zooms
  around the pointer. Both change presentation geometry only.
- Escape closes when the disposable source has keyboard focus; timeout always
  closes. Clicking another application changes normal focus, and the fixture does
  not continually reactivate itself.

The demo is an experimental native adapter, not yet the persistent Rust desktop
shell. Camera state here is temporary. It does not acquire arbitrary user windows
or persist source identities across launches. Titlebars and window-management
moves are deliberately absent from this disposable borderless fixture.

## Verified result

`evidence/verified/run-ch8fg6_e/verification.json` is a passing focused E2E run on
arm64 macOS 27.2, SDK 27.0, under the coordinator's SIP-enabled host configuration.
No SIP change was made. `proof/receipt.json` contains the raw observations and
`sha256.json` freezes the saved evidence. Paths inside receipts identify their
original generation location under `target`; the adjacent copied PNGs are the
preserved evidence.

| Check | Result |
|---|---|
| Actual source stream | Live native NSWindow frames, including controls and changing tick/color |
| Camera A | Viewport `(20,60,480,500)`, pan `(0,0)`, zoom `0.8` |
| Camera B | Viewport `(540,60,480,500)`, pan `(70,20)`, zoom `1.2` |
| Independent host pixels | Both red and blue in both copies, matching within each of six captures |
| Green marker bounds | A `(244,148,32,32)`; B `(792,168,48,48)` |
| Clipping | No colored pixels outside either viewport; B cuts the right edge of the changing patch |
| Source geometry/occlusion | Original bounds unchanged, host precedes and fully covers source in native window list, source continues ticking |
| Public PID event route | Mouse events reach the app with window `0`; buttons/scroll fail; text is focus-dependent |
| Private PID event route | Tagged native button action, exact text hash and native scroll movement from **both** scaled views |
| Cleanup | Host deadline, SIGTERM, SIGINT, host SIGKILL parent-loss recovery; exact child reaped |

A delivered event or a successful API return is not counted as native-control
proof. Each camera attempt has its own random-derived tag. The E2E independently
checks source native action tags, expected AppKit local points, exact expected
text SHA-256, scroll offsets, and inverse camera mapping. It compares the host's
rendered pixels separately from source heartbeat metadata. `verify-png.py` also
independently decodes and checks saved PNG bytes, including CRCs, geometry, both
color phases, agreement between views, and clip boundaries; its receipt is
`proof/independent-pixels.json`. Keyboard proof uses
the actual native field editor and standard Edit → Select All menu handling.
No RPC, `performClick:`, `insertText:`, app-local event dispatch, or first-responder
shortcut executes the requested control actions.

Reliable keyboard editing requires normal source application activation. The
probe activates only its enrolled disposable source for the brief private input
sequence. It requests restoration of the previous foreground application only
while the source still owns focus and the previous application's launch identity
still matches. A newer human app switch is respected. Button/scroll success while
inactive was observed in exploratory runs; the preserved all-control proof uses
normal active-source keyboard focus.

## Safety and implementation boundary

The router rechecks child PID, process birth, native window ownership and the
original bounds before **every** post. Every event uses a private CGEventSource
state and a unique attempt tag. Public `CGEventPostToPid` plus fields 91/92 is
tried first. If incomplete, the documented private window-location and routing
fields are posted with `SLEventPostToPid`, still only to that exact child. There
is no global event-post fallback, pointer warp, Dock injection, or source-window
transform setter. Pointer positions in a receipt are observations; human pointer
movement can make them differ, and this code does not “restore” a human's pointer.

Only the exact child PID/window is selected for the stream. Only the exact host
PID/window is selected for PNG verification. Shareable-content enumeration is
used to find those identities; unrelated windows are never captured. Source text
is stored only as hashes. Scripted proof aborts on untagged control input; pixel
captures occur before scripted editing and are suppressed after human control
input is observed. The demo suppresses further screenshots after observing untagged source input,
while continuing normal interaction until Escape or its deadline. The scripted
probe still aborts when that input contaminates its evidence.

`evidence/demo-input-regression/` preserves the focused regression receipt and
hashes. Its harness launches the real demo/probe executables and directs one
untagged mouse-up to each exact owned source after checking parentage, process
birth, window ownership and unchanged bounds. This models the same untagged-input
observation as physical input; it does not claim to test physical keyboard delivery.
The demo survives capture suppression until its four-second deadline, while the
scripted probe aborts promptly. Both save no screenshots after that early event
and reap their sources. This regression requests no activation or global input.

The source publishes identity/telemetry files only. It exports no CAContext or
custom surface and receives no control-action RPC. It has a fixed deadline and
checks parent death. The host stops its stream, closes its panel, terminates and
reaps only its `NSTask` child, with a bounded exact-child kill fallback. SIGKILL
of the host is recovered by source parent monitoring. An OS-level identity race
between validation and post remains; this is fixture-only enrollment, not an
arbitrary-application authorization mechanism.

`Canvas` owns AV rendering, per-view clipping and inverse input mapping. `Router`
owns identity checks and per-PID event delivery. `source()` and the CLI lifecycle
are disposable test plumbing. These components can be separated into the native
side of a Rust Scene adapter; the experiment does not yet expose a stable C ABI.
Production integration must take geometry from Rust, retain this enrollment
boundary, and define focus/activation and popup policies explicitly.

Untested: arbitrary third-party apps, protected content, multiple displays,
performance/latency, high-DPI quality policy, native menus/popups/child windows,
IME/composition, drag-and-drop, multi-button capture, Spaces changes, relaunch
identity, persistent layout, and long-running manual use. The demo handlers for
pan/pinch/zoom are implemented but the saved E2E uses fixed camera geometries;
it does not prove every manual gesture or input type.

## Evidence export

The focused harness sanitizes its saved evidence only after cleanup. Standalone
exports can run `python3 native/captured-windows/sanitize-evidence.py DIRECTORY`
after the fixture exits. This recursively removes expired `nonce` handshake
fields, records redaction in `sanitation.json`, and refreshes evidence-file
hashes in an existing manifest. Historical implementation hashes remain frozen;
the sanitizer hash is recorded separately as `sanitation.json` → `export_tool`.
Missing original implementation lineage is marked as unrecorded, never inferred
from the current checkout. It checks every source PID is gone and requires matching reaping or
exit evidence before changing any file. Active handshake files are never
sanitized. Native measurements, verification outcomes, and PNG bytes are retained.
`python3 native/captured-windows/verify-sanitizer.py` checks this export contract
on temporary saved copies, including historical-hash preservation, without any
native process or focus test.

## Provenance

New GPL-3.0-or-later implementation. No upstream implementation was copied.
Private ABI declarations and routing field numbers were checked against
[Cantrip `skylight.rs` at `4da10af479701c8007074c65f9eb6a2db03c8ffc`](https://github.com/ArcaneArts/Cantrip/blob/4da10af479701c8007074c65f9eb6a2db03c8ffc/cantrip_cua/src/macos/skylight.rs):
`void(pid_t, CGEventRef)` posting, `void(CGEventRef, CGPoint)` window location,
and `void(CGEventRef, uint32_t, int64_t)` field setter. Runtime symbols are
resolved dynamically and all three are required. Private behavior may change
between OS builds. Public framework signatures come from the installed SDK.
