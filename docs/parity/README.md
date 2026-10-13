# DriftWM parity contract

The completion requirement is exact feature parity with DriftWM. This directory
tracks the gap between that requirement and Infinify's experimental app. A useful
prototype, a successful build, or a passing reducer scenario does not satisfy it.

The comparison is pinned to DriftWM
[`352333a8fa1b22171492d4b71a54102045c9a19d`](https://github.com/malbiruk/driftwm/tree/352333a8fa1b22171492d4b71a54102045c9a19d),
which was also the remote HEAD when checked on 2026-10-09. The initial target
checkpoint is `27a868e`. Later upstream changes require an explicit inventory
refresh; they must not silently change the acceptance target.

## Inventory and acceptance

[`inventory.json`](inventory.json) records source action variants, input action
families, IPC requests, reference-configuration entries (including commented
defaults and examples), configurable
structure fields, protocol families and cross-cutting behavior. Source references
and hashes make omissions and drift inspectable. Reference values are examples
or documented defaults; the runtime defaults and dispatch code remain authoritative.
An inventory row is a coverage obligation, not an executable specification or a
claim that every edge case has already been enumerated.

Rows use `missing`, `implemented_unverified`, `verified`, `blocked`, or
`out_of_scope`.
`implemented_unverified` includes partial implementations with known mismatches.
Every required row must acquire an exact behavioral contract, a production-path
test, saved evidence tied to its implementation revision, and independent review
before becoming `verified`. Evidence must identify OS, architecture and relevant
hardware. No percentage or completion claim follows from counting stubbed APIs.

The user clarified on 2026-10-09 that every behavior is required for native Mac
apps. Literal Wayland/X11 client hosting and wire-protocol compatibility are
outside scope. Those inventory entries remain visible with `required: false`
and `out_of_scope`; native equivalents of platform services remain required.
A platform equivalent must preserve the specified behavior. An unsupported API
does not turn its feature into a pass.

On 2026-10-11 the owner chose the Mac's existing settings for behavior macOS
already controls, including display modes, screen lock, volume, brightness and
device settings. Infinify must respect those settings; implementing a second
set of system controls is not part of the native port. In the subsequent
67-question review and its follow-up, the owner confirmed **65 Use macOS**
answers and excluded the **two tablet display-mapping** rows. Question 18
(`protocol.image_copy_capture`) is resolved: use existing Mac display/window
capture; no dedicated live Infinify canvas feed is required.
The exact answers are recorded under `scope_decision.host_owned_review` in
the inventory. The 65 delegated rows remain visible and unverified: no duplicate
control is queued, but the decisions supply no runtime acceptance evidence.
Native capture/input suppression around the system lock, safe restoration and
correct display reconciliation remain integration obligations. Tablet pressure,
tilt, proximity and tool-cursor forwarding remain required; only display mapping
was excluded. The review does not authorize tests, fixture launches, Mac settings
changes or experiments with other applications.

The owner also excluded features without a macOS equivalent on 2026-10-11,
including the Linux backend controls, XKB keyboard model, primary selection and
touchscreen-specific input. Those 67 rows are now `out_of_scope`, with their
upstream contracts and source references retained. This supplies no acceptance
evidence. The native green button must toggle fullscreen inside the canvas;
Option-click toggles fit and uses `decoration_fit_snapped`.

## 2026-10-12 whole-desktop native admission

The owner authorized overnight benchmarks and tests on 2026-10-12. Disposable
fixtures remain the native mutation scope; no SIP, permissions or system settings
are changed by these runs. Obsolete interfaces must be removed with their call
sites migrated because this project is pre-release.

The explicit `--native-desktop-helper` mode admits this login user's application
windows, including processes opened after launch, through one authenticated
Apple-signed Dock helper. Fresh UID, process birth and window-family ancestry
checks remain per admission. Finite disposable scopes remain separate modes.
Helper readiness now audits protocol v2, exact requested scope, restoration and
alpha capabilities, and an empty restoration table before the app can connect.

The owner-run launcher keeps credentials in private files, pins Dock identity
before injection, reuses a confirmed same-Dock helper, and preserves pending
records and recovery journals after unknown outcomes. Building never injects.
The loader uses nonce files exclusively; its previous raw-argument interface was
removed with all call sites migrated. This source milestone does not establish
native clipping, cross-application drag-and-drop, performance or app acceptance.

## 2026-10-12 ordinary application checks in the VM

The owner subsequently authorized unrestricted testing inside the disposable UTM
macOS guest, including its administrator operations and permissions, and confirmed
the guest was idle. Host desktop input, windows and settings remain outside that
scope; guest work runs over SSH with UTM left in the background.

On 2026-10-13, build `3db7693` corrected ordinary TextEdit title handling: its
document-actions AX menu had been mistaken for the start of content, leaving
the title drag to macOS beneath a transformed window. At zoom 0.5, a guarded
40-by-24-point guest title drag moved the displayed window by exactly that
endpoint delta without moving its native frame. Horizontal snapping held the
first seven samples and released on the eighth; this is not a continuous-motion
or frame-rate result. A normal right-edge drag of -24 screen points reduced
native width from 610 to 562 and displayed width from 306 to 282. Each of eight
edge samples moved by the requested three screen points with the opposite edge
and native origin fixed. Input was released and the guest cursor restored; the
user subsequently continued interacting with the resulting scene. Evidence is
in `target/native-vm/live-workflow/fixed-{title,edge}-drag.json` and the matching
state/native readbacks and screenshots. The signed executable SHA256 is
`1a9fc435bb607365b4729c78301c013e95d2ddfd458a12f88e52e801d7b38cc4`.

The same guest launch exercised the previous-boot launcher branch after a real
guest reboot: the old ready record was archived and the new Dock helper started
authenticated with an empty table. The preserved pre-launch and archived record
both hash to `3c37696777244429bf33df25e0cbc066e601afc82cf6aa284fcedfc4cbc868b8`.
This establishes that specific startup branch, not restoration of windows from
the previous boot. Host desktop input and settings were untouched.

The follow-up to the owner's menu/fullscreen and opening-delay reports changes
three behaviors: smaller fullscreen answers align to the usable top-left;
native fullscreen retains the configured background beneath the menu bar; and
creation hints request discovery immediately, with a fresh observation scheduled
at the existing 50 ms stability deadline. Discovery metadata no longer waits for
existing windows' family audits. Size readback retains its bounded settling
window for intermediate answers. These changes still need guest optical and
latency validation. They do not establish that application size constraints are
bypassed, that ordinary macOS menu material is changed, or that fullscreen fills
the menu-only area for every application.

The native title-drag fix in `f7c9a21` passed bounded checks using guarded CGEvents
posted into the guest's normal HID event path against ordinary Terminal on arm64
macOS 27.0.1 (26A434), VirtualMac2,1. At zoom 1 and 0.75,
a 40-by-30-point pointer movement produced the same WindowServer screen movement;
the corresponding rounded world deltas were (40,-30) and (53,-40). The native
frame stayed fixed after the down, every one of eight drag samples, and release.
The swallowed session-stage press no longer triggers the AppKit lost-release
watchdog. Each check restored the scene, camera, zoom, native transform/frame and
guest cursor exactly. Signed executable SHA256:
`bfab0a385f674b87c52b88608cb7fc04a330738285256f640a6cbbd71017cd43`.
Local evidence: `target/native-vm/native-title/watchdog-fix/receipt.json`.

The follow-up build `9483609` retained that title-drag behavior at 0.75. On the
same ordinary Terminal, dragging the normal right edge inward by 42 screen points
reduced the native width from 860 to 804 and displayed width from 646 to 604.
All eight requested native sizes applied, the opposite edge and native origin
stayed fixed, and the maximum enclosing screen-edge rounding difference was
0.5 points. Release completed the resize transaction. The complete scene, native
geometry and cursor were restored. Local evidence:
`target/native-vm/native-edge-final/receipt.json`, executable SHA256
`edf755d6cc60b6eead48673d035252a7e42572dd8743370e0aeec7f95f4175fc`.

The `581fa9a` build retained the 0.75 edge behavior on Terminal's subsequent
860-by-649 frame. Fullscreen exit restored the pre-entry scene, transform and
screen rectangle, and fit/unfit restored the saved extent and world center.
Fullscreen coverage still fails the menu-only requirement: the requested
1920-by-1170 area becomes 1917-by-1069 in Terminal. Its cell increments and the
guest's 1920-by-1080 `NSScreen.visibleFrame` account for this clamp; centering it
leaves 50 points above and 51 below. The current AXSize path has no established
override of that application constraint. Final test cleanup restored reported
scene/native frame/screen rectangle and foreground; fractional transform and
cursor drift were 0.0234 and 0.84 points, respectively, rather than exact.
Local evidence: `target/native-vm/native-fit-fullscreen-final/receipt.json`
and `underfill-analysis.json`, executable SHA256
`ab1d9231baf961824c1bd12307197c3bdcc33e844a59d546d767597e5fc65d81`.

A newly opened TextEdit document also passed an automatic-placement check: its
world rectangle cleared the existing Terminal and Notes by 13 and 12 points,
respectively. Independent native geometry matched its active-camera projection.
TextEdit restored five older documents at launch and the camera followed another
restored window, leaving the unique document partly offscreen; this is not
confirmation that launch navigation selects the intended document. The unique
document was closed and removed, TextEdit was gracefully quit, and the original
two-window scene was restored. Local evidence:
`target/native-vm/automatic-placement-final/receipt.json`.

The `7a57b32` bundle visually filled the guest display with the inherited default
macOS wallpaper. `NSWorkspace` returned an empty options dictionary for that
wallpaper, so the inheritance fallback uses cover; explicit layout options are
still honored. The ordinary Calculator window also returned to its independently
observed transform and screen rectangle after a native-mode launch and quit.
Evidence: `target/native-vm/pending-restore-inspect/launch-recovery-live.png` and
`launch-recovery-quit.jsonl`; executable SHA256
`ad79a846b79773182d8f15641d3df1342d54dee7bb75f0db4a7bdda83834b3ad`.
That successful quit did not survive helper retirement. After a subsequent
session restored the same Calculator and committed an empty journal, terminating
its Dock writer changed the window transform from translation (-510,-554) to
identity. The screen rectangle moved from (510,554,230,408) to (0,0,230,408), while
its process birth, window ID, owner and native bounds stayed unchanged. This was
observed before loading another helper and confirmed in a screenshot. Evidence:
`target/native-vm/pending-restore-inspect/touched-calculator-before-retirement.jsonl`,
`touched-calculator-after-retirement.jsonl` and
`touched-calculator-after-retirement.png`. An empty active restoration table is
therefore insufficient evidence for safe Dock retirement. The historical schema-2
journals discarded restored originals and cannot reconstruct them. See the
[helper lifecycle notes](../../native/privileged/README.md) for the recovery work.

The schema-3 retained-original ledger was then exercised with ordinary Calculator
using build `2d9c7d6`. After Dock retirement reset its transform to identity, the
production launcher started a replacement helper, recovered the exact original
translation (-510,-554), and admitted the window with that restored original.
Normal quit again restored its original native and screen bounds
(510,554,230,408), with no pending entries and the released original retained.
This is one exact-geometry handoff check, not optical acceptance: the saved
screenshot was black. A second retirement again reset the transform, but the VM
rebooted during the subsequent sudo prompt before the recovery launcher ran.
That second handoff is untested; the reboot cause remains undetermined and no
fresh guest panic report was found. Evidence and hashes:
`target/native-vm/retained-originals/receipt.json`.

After that reboot, build `5cee261` passed two consecutive retirement/recovery
cycles with a fresh ordinary Calculator instance. Each replacement helper
recovered the independently saved original before readmission, and each normal
quit restored native and screen bounds (510,554,230,408) with the original
translation retained in the released ledger. Screenshots taken with the guest
display awake visibly confirm the restored Calculator position after both
cycles. This covers one ordinary window, not all-app or mid-frame crash recovery.
Evidence: `target/native-vm/retained-originals/two-handoff-receipt.json`.

The same bundle passed one ordinary TextEdit selection at zoom 0.75: normal HID
drag events selected the exact 22-character seed, with unchanged native bounds
and transform throughout the drag and paired release. A Finder-to-TextEdit file
drop was inconclusive: both the transformed case and the app-stopped native
baseline left the document unchanged. It establishes neither working file drop
nor an Infinify-specific failure. Local evidence:
`target/native-vm/native-content-dnd/receipt.json`. The test-created TextEdit and
Finder windows were closed afterward. Terminal/Notes already had displaced
transforms at that test's start, so restoring that baseline did not repair their
older positions.
A later unlocked-guest PNG-to-RTF baseline also produced no visible image with
Infinify stopped. Actual pointer positions matched every posted drag point, the
combined-session left button remained down through the drag and was released,
and the destination was independently identified as TextEdit's text area. The
source Finder window matched, but its exact source icon was not established by
the AX helper. This remains an unsuccessful native baseline, not evidence of an
Infinify-specific drop failure. The owned windows and temporary display-awake
assertion were cleaned up. Evidence: `target/native-vm/png-drop-baseline/receipt.json`.

These checks establish standard Terminal title-drag and edge-resize routing for
the sampled interactions, and free-space placement for that TextEdit window. They
do not establish optical frame cadence, custom title-bar compatibility, all-app
input or native compositor parity. A 60 Hz virtual display cannot establish the
120 Hz physical-display target.

## 2026-10-12 resize and capture responsiveness

A native-primary VM profile on build `5cee261` used ordinary Calculator and
five disposable TextEdit documents. Infinify used 4.49% of one guest CPU at rest
(10.03 seconds, 128.8 MiB RSS); the sampled pan/zoom interval used 9.48%
(7.80 seconds, 129.1 MiB RSS). The latter includes a two-second stack sample and
is not an unprofiled benchmark. All six original native geometries and the saved
scene were restored exactly afterward. Cursor routing accounted for 465 of 951
sampled main-thread stacks, largely waiting synchronously on WindowServer.
Native render-time cursor refresh now skips that query when no custom canvas
cursor is needed; event-driven input, grabs, pick mode and resize borders retain
fresh routing. A single repeat on build `a5e8355` contained zero cursor-routing
frames among 1,078 main-thread samples. Rest CPU was 3.29%, while sampled motion
CPU was 10.84%; motion-end RSS was 128.55 MiB and sampled footprint increased from
192.7M to 227.2M. This confirms removal of the sampled blocking path, not an
overall CPU or memory win: background WindowServer load differed, the repeated
run reported different document titles, and pointer position was not matched.
Fitted geometry, ordering, focus, camera and document bytes matched, and all six
originals were again restored exactly. The VM exposes no comparable GPU
utilization or physical-window presentation cadence. Evidence:
`target/performance/native-six-window-20261012/receipt.json` and
`after-cursor/comparison.json` in that directory.

Interactive resizing now rebases the grabbed edge when a delayed native baseline
differs from its displayed size. Subsequent motion uses the current camera and
zoom, retains fractional precision at distant world coordinates, and delivers
the final release position. Focused resize and pointer scenarios pass;
third-party acceptance remains unverified.

The signed `f7bdef71` app passed one physical right-edge shrink at zoom 0.5 in
capture mode and one in scoped primary-native mode on arm64/macOS 27.2.
`tests/e2e/physical-resize-edge.sh` posted nine guarded real CGEvent samples per
case, rather than injecting `DebugPointer` presses. Both measured 0.0-point
maximum settled edge error and changed native width 320→272 for a 24-point
screen drag. Native edges came from independent WindowServer reads; capture
edges came from reported placement after accepting real capture pixels. The
fix shares normal border admission between canvas and native input, then
refreshes the presenter's native-size basis at each accepted readback before
rendering. Both exact originals and the cursor were restored, both journals
were durably empty, and all four children exited. Exact executable hash and
evidence paths are in the native desktop's
[current evidence](../../native/desktop/README.md#current-development-evidence-2026-10-12).
Optical pixel edges, fast/human input, other physical zooms and third-party
applications remain unverified.

Unclaimed native mouse presses now retain their original drag/release pair while
crossing canvas panels. New trackpad contacts cannot steal an existing native
press. This preserves native drag ownership; it does not provide an AppKit file
drop destination for captured or replica windows. That integration remains open.

Capture-family permission preflight runs on the bounded observation worker,
removing a measured synchronous TCC wait from the main-thread demand path.
Managed discovery and child ownership/bounds observations also run on bounded
workers. Exact binding/session fences, fresh main-thread process birth and
100 ms freshness from the first native read remain required; input and captured
frame validation keep their fresh native membership checks.

Screen-pinned native resizing now uses output-local points at every canvas zoom,
keeps the opposite edge from an absolute anchor, and preserves independent pin
movement before delayed readback. Fractional readbacks do not accumulate rounding
drift. The signed `c571a2e` build passed the owned resize scenario's 58 grabs,
including eight pinned edge/corner cases at zoom 0.5 and 0.8, native size limits,
closure and unresponsive fixtures. `DebugPointer` invokes the production view
handlers and the adapter changes real fixture sizes; it does not establish
physical cursor or third-party acceptance. All nine children exited, every resize
transaction ended, and the decoy retained its bounds and received no event.

A native half-scale AppKit file session also passed between two independent
owned processes, including the original file contents, outside-application drag
context, destination callbacks and local drop coordinates. Independent reads
confirmed exact restoration and empty journals for both helpers before all
children exited. This covers two disposable AppKit applications; arbitrary
third-party applications, file promises and captured replicas remain open. See
[`NATIVE-DRAG-ROUTING.md`](../../native/desktop/NATIVE-DRAG-ROUTING.md).

The root-only family ordering optimization is implemented, but its matched
six-window capture run still presented about 47-58 frames/second and retained
main-thread stalls. A further capture-demand change now waits for actual scale
motion to settle before reducing resolution, while required upscales and native
size changes remain immediate. In the matched six-window run this reduced
reconfigurations from 36 to 12 and worst zoom main-thread work from 47.2 to
8.6 ms, but zoom presentation fell from 47 to 41.25 frames/second while larger
surfaces stayed allocated. This is a tradeoff, not an overall performance win.
The subsequent sqrt(2) resolution buckets reduced over-allocation without
lowering demanded quality, but one matched zoom sample improved presentation
from 41.25 to 52.75 fps while its worst main-thread gap increased from 8.6 to
63.1 ms. This was also a tradeoff, not stable 120 Hz.

An earlier matched capture sample, signed `42d17f4`, uses six 1700×1132-point
windows and a 2056×1290-point Retina output. Actual canvas presentations were
57.25/51/52/58/52 fps for rest/pan/zoom/window move/logical focus. Worst
main-thread gaps were 2.6/2.0/10.9/2.5/2.5 ms, down from
46.5/48.7/63.1/41.9/25.7 ms in the matching `0e47daa` run. Presentation p99 and
worst gaps remained 25 ms in every latest phase, and the 120 Hz source and
presentation assertions still failed. The new app includes both child observer
and wallpaper-query improvements plus correctness changes; one pair does not
isolate their contributions. A separately labeled 500 ms fixture-reporting
diagnostic, with the same app and redraw request, did not resolve the deficit.

The later matched `ad0dd2fa` → `2461a220` pair remained below target in every
phase: candidate rest/pan/zoom/move/focus presentation was
58.25/57.00/47.25/54.50/56.50 fps, with 25 ms presentation p99/worst gaps.
Pan and focus improved, but app CPU increased in every interval and final RSS
rose from 156.20 to 183.19 MiB. The unchanged 120 Hz assertions failed for both
builds. The first-image deadline is a resource-lifetime correction, not a proven
overall performance win. The native README records exact hashes and evidence;
separate diagnostic sampling is excluded from that comparison.

The next matched pair uses clean `2461a220` and a frozen dirty-tree candidate
with executable SHA256 `2ce30f3abd8769ce9496bdf69a041697e2e187d0145b3de0db183ac3c1580fef`.
With the same six large sources, 50 ms fixture reports and no profiling or
callback diagnostics, presented rest/pan/zoom/move/focus fps changed from
59/59.75/47.25/58/59.45 to 60/58.75/53/58/58.5. Candidate main-thread gaps in the
selected intervals stayed within 2.5 ms and final RSS fell from 188.42 to
151.47 MiB. Pan/focus throughput did not improve, zoom CPU increased, and both
builds failed the unchanged 120 Hz assertions. Presentation p99/worst gaps
remained 25 ms, drawable acquisition reached 25.06 ms, and submission latency
reached 65.67 ms despite a 120 Hz screen clock. Cold-child admission and
periodic-wallpaper changes are combined with other fixes; their individual
contributions are not isolated. All fourteen owned processes exited. Frozen
inputs, manifests and records are in
`target/performance/20261012-window-scaling/cold-admission/`; the native README
records workload, CPU-interval and whole-desktop WindowServer limitations.

The subsequent `2ce30f3a` → `61af1dba` pair tests completion-scoped release of
retired capture surfaces. Actual rest/pan/zoom/move/focus presentation was
56.45/59/52.5/58.5/57.5 → 59/59/54.25/59.25/59.5 fps, with unchanged 25 ms
presentation p99/worst gaps, approximately 25 ms acquisition and 65.7 ms maximum
submission latency. CPU and main-thread tails were mixed; candidate root
acceptance at rest reached only 44.5 fps. Ending RSS was 156.66/151.66 MiB,
while earlier baseline endpoints were lower. Both builds fail the same ten
cadence assertions. The 43-check headless regression and failing old-code
negative control establish the lifetime bound, not an overall performance win.
The workload, 50 ms reports and assertions remain unchanged, no profiler or
optional diagnostics ran, and all fourteen owned processes exited. Frozen
binary hashes, CPU interval qualifications and exact records are in the native
README and `target/performance/20261012-window-scaling/completion-lifetime/`.

A matched six-second static native idle pair compared `f7bdef71` with `ad0dd2fa`
using identical helper/harness bytes, boundary-only reads and no sampling
profiler. Infinify CPU fell from 3.98% to 2.49% of one core (37.5% in this pair),
with essentially unchanged ending RSS (53.58/53.64 MiB) and charged physical
footprint (155.03/155.05 MiB). The helper used 0.17% in both intervals. The new
app skips redundant clock-only snapshot/idle-description work and also removes
the unused capture-ack protocol; the comparison does not isolate their effects.
Whole-desktop WindowServer used 2.32/3.15% managed versus 13.29/13.78%
fixture-only, with different layouts and an extra canvas surface, so these
figures are not isolated compositor overhead. Exact six-window identity, owner,
geometry, transform and alpha restoration and empty journal checks passed in
both runs; both apps quit normally and all owned children exited. The memory
endpoints are not peaks or complete GPU allocations. These measurements do not
establish native-window optical FPS or third-party compositor parity. Full scope, hashes
and evidence locations are in the native README's
[current development evidence](../../native/desktop/README.md#current-development-evidence-2026-10-12).

The application build now signs and verifies a staged bundle before replacing
`target/app/Infinify.app`. Its adjacent `BUILD.json` records the source snapshot
and signed executable hash; changed sources or failed packaging refuse promotion.

## 2026-10-12 capture input and frame overhead

The default capture desktop now uses the same observed native green-control
geometry as helper-backed replicas: green click requests canvas fullscreen,
Option-click requests fit, and release must still hit that root rather than a
covering child. The exact shell-owned button pair precedes any separately
admitted mouse grab. Unreadable or stale Accessibility controls are not guessed.

Admitted tablet contacts now retain their original native recipient and display
while the pen leaves the canvas or crosses another window. Current camera and
native geometry map each tail packet; missing geometry suppresses motion while
the release closes its original admission. Device/tool replacement retires the
previous contact without lending its authority to the new tool. These paths
still need physical tablet validation.

Unchanged captured families reuse their ordered child list after checking every
current image and key. The compositor checks current stack buckets and skips
repeated bucket scans for already ordered frames, retaining its full fallback
for other inputs. These reduce source-level work; no measured performance claim
or inventory status promotion follows from them.

Cross-application drops through independently zoomed views remain open. AppKit
exposes app-owned drag sessions and destination callbacks; posting a drag's
mouse packets to its source does not negotiate a native destination. A foreign
session routing contract preserving payloads, operations and completion is
still required. No pasteboard-copy substitute is counted as drag-and-drop parity.
This batch uses source review and compile/link checks only.

## 2026-10-11 normal capture family integration

The default desktop's capture path now shares native descendant observation,
separate popup/sheet streams, display-clipped family composition, exact rendered
input ordering and full-family screenshot export with the native replica path.
Observation-only roots retain ancestry/geometry without capturing hidden child
images; their descriptions can project an offscreen root's visible child into
an independent display view. Root binding changes, session departure and child
invalidation retire these descriptions or prevent them authorizing input.

Child click activation settles canvas focus logically and activates only the
application when needed, preserving its native child focus. Held mouse input
keeps its exact child recipient and pairs each admitted button independently.
An extra button pressed before initial activation/delivery remains subject to
the existing one-pending-gesture rule. Cross-application drag-and-drop and
application-requested pointer lock are still open.

Two source optimizations remove an extra image-sized RGBA allocation/copy from
ordinary wallpaper uploads and repeated title/app-name text hashing from frame
keys. These are code-path savings, not measured FPS/CPU claims. Native clipping
still lacks a sufficiently established snapshot/set/restore contract; the
pinned conflicting declarations are recorded in
[`native/privileged/CLIPPING.md`](../../native/privileged/CLIPPING.md).
Replica cursor image ownership and Spaces gathering also remain open.
Physical popups above the overlay retain their application's native placement;
captured copies alone do not establish independent-view alignment. Tablet child
contacts leaving the overlay still lacked the native mode's global tail route
at this checkpoint; the 2026-10-12 implementation above closes that source gap.
No inventory status is promoted: this batch uses source review and compile/link
checks only, with no tests, fixtures, application launches or desktop experiments.

## Known differences at the initial checkpoint

| Behavior | DriftWM | Infinify checkpoint |
| --- | --- | --- |
| Snap defaults | gap 12, distance 24, break force 32 | gap 8, threshold 12, break force 24 |
| Snapping | opposite edges; optional same-edge/center; resize snaps | opposite-edge drag snapping; no resize snapping |
| Minimum zoom | hard floor 0.001 with layout-dependent effective minimum | static 0.001 floor |
| Camera motion | animation, velocity/coasting, edge pan | direct pan/zoom; unused momentum helper |
| Navigation | directional, MRU cycle, home, bookmarks, fit/fill, overview, fullscreen, output transfer | a few reducer primitives; app actions absent |
| Sessions | dormant windows, suspend, relaunch and adoption policies | saved geometry/cameras and manually rebound placeholders |
| Native surfaces | compositor-owned window and popup trees | selected independent-window capture streams |
| Input | full grabs, contexts and configurable device bindings | limited native left input/scroll; hardcoded app controls |
| Configuration and IPC | upstream config grammar and live Unix socket commands | diagnostic/scenario CLI and an internal controller ABI |
| Rendering | chrome, effects, pin/widget layers, backgrounds and screenshots | clipped live layers and placeholder tiles |

The existing app's earlier complete native-control proof belongs to its recorded
historical source. The current checkpoint has separate focused review-fix
regressions. See [desktop evidence](../../native/desktop/evidence/README.md).
The development host runs macOS 27.2. Building with deployment target 26.0 is not
evidence of runtime compatibility with macOS 26. Physical multiple-display and
device-specific behavior also need the corresponding hardware.

## Later bounded milestones

- `4ca7f5e` ports snap defaults and candidate/resize policies, checked against the
  unchanged pinned upstream algorithms. Fractional rounding, native constraints
  and complete desktop gesture behavior remain open; see
  [snapping limits](../../crates/canvas/SNAPPING.md).
- `e133f91` normalizes captured root families using frame metadata. Independent
  saved-pixel checks pass for a right-extending native panel and an in-bounds
  sheet through two clipped views. This does not establish left/up extents,
  parent discovery, interleaved stacking or native popup interaction; see the
  [family evidence](../../native/families/evidence/normalized-review.json).
- `2fb6218` adds upstream fit/minimum-zoom, navigation, bookmark and motion helper
  policies with an unchanged-source differential oracle. These helpers are not
  yet integrated into Scene/controller behavior; see
  [policy contracts](../../crates/canvas/POLICY.md).
- `2842602` integrates Stage ownership, confirmed MRU history and held cycling
  through the exported controller C ABI. Stale results after rebind/load are
  rejected. Camera navigation, native dispatch and modal/fullscreen/pin/widget
  policy remain separate requirements; see the
  [focus contract](../../crates/desktop/FOCUS.md).
- `21b454d` connects normal-window Keep/Reset navigation and held cycling to
  per-output camera animation, placements and hit mapping through the C ABI.
  Differential tests execute exact upstream method bodies. Native frame scheduling
  and the full center-window action remain unfinished; see
  [navigation contracts](../../crates/desktop/NAVIGATION.md).
- `f5007b8` adds single-window native resize transactions through the C ABI:
  coalesced requests, actual-size settlement, incremental edge anchoring and
  capture/input gates. Thirteen focused tests include an outcome-validation
  matrix, independently reviewed after fixing a contradictory-result defect.
  At that checkpoint the separately tested AX adapter was not connected through
  this transaction in the shell; see [resize contracts](../../crates/desktop/NATIVE_RESIZE.md).
- `9a190b1` connects normal-window focus/navigation to the native shell behind an
  explicit experimental launch flag. Headless checks exercise its real coordinator,
  event-order policy and Rust C ABI, including cancellation and delayed shortcuts.
  Independent review approved the corrected implementation. Native focus, real
  shortcut delivery and rendered animation remain unverified; see
  [integration evidence](../../native/desktop/evidence/navigation-headless.json).
- `6a49484` connects experimental native resize handles, the transaction, the AX
  adapter and a strict capture gate. Headless checks cover early motion, coalescing,
  cancellation, result draining, padded buffers, stale frames and source validation
  without new frames. Independent review fixes preserve final settlement and reject
  stale work. Actual handle-to-AX-to-renderer behavior, static-window refresh, groups
  and fractional upstream equivalence remain unproved; see
  [integration evidence](../../native/desktop/evidence/resize-headless.json).
- `7e9d59c` adds animated PanViewport, HomeToggle, ZoomIn, ZoomOut, ZoomReset and
  ZoomToFit to the default shell as camera-only controller commands on the existing
  flight tick, with toolbar buttons and Control-Option shortcuts, an Open canvas
  chooser entry that needs no capture, and an access request that runs only from the
  user's click. Coverage is a controller scenario through the exported C ABI and the
  headless coordinator regression. The toolbar, shortcut delivery and rendered
  animation have not been exercised live; chords, steps and fit padding are
  hardcoded and fullscreen interaction is absent. See
  [navigation contracts](../../crates/desktop/NAVIGATION.md).
- `6574ad1` routes every default-shell view and bookmark
  shortcut and view toolbar button through DriftWM's action-string grammar (Quit and
  Control-Option-Escape still call the shell's quit directly), adds a Unix-domain IPC socket with
  an `Infinify msg` client for the upstream requests that have a native meaning,
  controller bookmarks saved in the scene file (additive; older builds cannot read
  a file that contains them), and `--windowed`, a single nested development panel
  with no global shortcuts. Upstream actions and requests without a macOS
  implementation parse but answer a not-implemented error; focus writes are logical
  focus and camera navigation only, moves are logical world moves, and resize writes
  are refused. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/ipc_flow.rs`) plus scripted sessions on 2026-10-09
  against the built app in `--windowed` mode on a private scene and socket (macOS
  27.2, Apple Silicon, three seeded detached placeholders), which left no saved
  evidence. Exercised there through the socket: state, camera and zoom reads and
  writes, the six view actions, bookmark set/get/list/delete/go-to, move, focus
  by id and by bundle identifier, the unknown, not-implemented and refused
  replies, the scene file after bookmark and move changes and after a restart, a stale socket,
  a second instance refused the same socket, and exit on `quit` and on SIGTERM.
  Evidence boundary: no rendered pixels, toolbar clicks, hot keys or status
  feedback were observed; no window had a bound source, so no native focus effect
  was produced and none is dispatched for IPC focus; one output only; the default
  socket path, the peer-user check and the server's connection limits were not
  exercised against the app. See the
  [desktop shell notes](../../native/desktop/README.md) and the
  [IPC contract](../../crates/desktop/IPC.md).
- `386d57e` adds `driftwm-core`: upstream's pure modules (`config`, `canvas`,
  `layout`, `session`, `stage` and the touch recognizer) carried over verbatim
  from the pinned commit, with their 675 upstream tests retained. It is source
  the app can call, not app behavior: nothing in the shell or controller used
  it at that commit.
- `4dd642b` configures the default shell exactly as DriftWM is configured: one
  TOML file in upstream's grammar, parsed by `driftwm-core`,
  decides key bindings, mouse bindings and settings. The controller holds the
  `Config`, replaces its own copy of the action grammar with upstream's, and maps
  upstream's modifiers and keysyms to a Mac keyboard (`ctrl` Control, `alt` Option,
  `super` a physical chord, Control-Option unless `--super` picks another, with
  displacement and deterministic collision handling). The shell loads the file at
  launch (`--config`), watches it and reloads on change, registers the reported
  bindings as global hot keys in place of its fixed table, repeats repeatable
  actions while held, and asks the controller for the binding of every press and
  scroll in place of its fixed gestures. Pan step, zoom step, fit padding, camera
  speed, nudge step, navigation anchors, config bookmarks, focus placement, the
  snap settings and the two session restore flags now come from the file.
  `nudge-window`, `exec`, `spawn`, `exec-terminal`, `exec-launcher` and
  `reload-config` run. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/config_flow.rs`) plus one scripted session of two launches
  on 2026-10-09 against the built app in `--windowed` mode on a private scene, config and socket
  (macOS 27.2, Apple Silicon, three seeded detached placeholders), which left no
  saved evidence. Exercised there through the socket: the defaults with no file;
  a file created, edited and broken while running, each picked up without
  a restart (pan step, zoom step, fit padding, bookmark seeds; the broken file
  keeping its predecessor); an accepted file moved away and back, which kept the
  configuration and the runtime bookmarks and reported upstream's read failure;
  a relaunch with no file starting at a new output's camera and the seed
  bookmarks; `reload-config`; `nudge-window`; `spawn` and `exec`
  starting real processes with the `[env]` environment; the unknown and
  not-implemented replies; exit on SIGTERM. Evidence boundary: no hot key was
  registered (`--windowed` registers none) and none was pressed; key repeat, every
  pointer press, drag and scroll, right and middle button forwarding, key lookup
  on another keyboard layout inside the app (the lookup code alone was run in a
  scratch harness against installed layout tables, registering nothing), `--super`,
  `exec-terminal` and `exec-launcher` were not run; nothing drawn was observed (status line, tooltips, help); no window had
  a bound source; one output only. At that commit nineteen of upstream's default
  key bindings and four of its default mouse bindings named actions that did not
  run; media keys are not registered, and trackpad and touch gesture bindings,
  window rules, decorations, effects, backgrounds, input-device settings and every
  other setting whose feature is absent are parsed and unused. See the
  [desktop shell notes](../../native/desktop/README.md#configuration) and the
  [configuration contract](../../crates/desktop/CONFIG.md).
- `c11fece`, window navigation and focus, makes DriftWM's `center-window`,
  `center-nearest`, `cycle-windows` and `focus-center` run in the
  default shell through the action grammar, and so through key bindings, the
  toolbar (Center, Previous, Next) and `msg action`, with upstream's cycle prelude,
  `find_nearest` and visibility thresholds from `driftwm-core`, anchors as
  `center-nearest` targets, and new `activate`, `clear_focus` and `focus_logical`
  controller commands for click-to-focus and the completed click's reveal,
  followed native focus, the empty-canvas click, and focus that stays logical.
  The navigation coordinator and native focus driver, until now behind
  `--experimental-native-navigation`, run in every normal launch. The obsolete
  flag has been removed; `--no-native-focus` keeps focus logical. Native focus
  needs Accessibility only; hold-to-commit samples the modifier state instead of
  using an event tap, and the hard-coded Option-Tab hot keys are replaced by the
  configured binding. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/navigation_actions_flow.rs`), the headless coordinator
  regression (`tests/e2e/desktop-navigation.sh`, injected focus driver, clock and
  scheduler), and four scripted launches on 2026-10-09 of the built app in
  `--windowed` mode on a private scene, config and socket (macOS 27.2, Apple
  Silicon, three seeded detached placeholders), which left no saved evidence.
  Exercised there through the socket: `center-nearest` right, left, up, down and
  up-right from known starting points with the focused window or the viewport
  centre as origin, at zoom 1 and with a kept zoom of 0.5, an anchor from a config
  file written while running, `center-window` with and without a focused window,
  `focus --id` followed by `center-window`, `cycle-windows`, upstream's messages
  for four malformed specs, both launch flags, and exit on SIGTERM. Evidence
  boundary: native focus of a real window was not exercised by any route; no
  window had a bound source, so no focus request was produced, and with
  placeholders only the focus history is empty, so `cycle-windows` replied Ok and
  changed nothing and no cycle that changes the order was seen in the app; no hot
  key, Option release, toolbar button, click, followed native focus or drawn
  frame was observed; one output only. Known mismatches: with native focus
  allowed the focus history is fed only by confirmed or observed native focus,
  so a window whose focus request fails or is superseded before it is confirmed
  stays out of it (without Accessibility or with `--no-native-focus` the shell
  answers each request `focus_logical` and the history follows logical focus, as
  upstream's follows keyboard focus); a click is forwarded while its native
  focus request is still in flight, not after it; `center-window` was always
  Reset because there was no fill (since the window sizing milestone below it
  returns to the fill's view for a window filled behind
  `--experimental-native-resize`, and is Reset in every default launch, where
  no fill can exist); `auto_navigate_on_click` pans at a completed
  click's release as upstream does, without upstream's title-bar double-click
  deferral; every canvas press ends an open cycle at the press; an IPC
  `cycle-windows` is always one committed step; the pointer `center-nearest`
  swipe and `focus_follows_mouse` were absent until the pointer policy
  milestone below, and so was `auto_navigate_on_close` until the window
  lifecycle milestone below. See the
  [desktop shell notes](../../native/desktop/README.md#window-navigation-and-native-focus)
  and the [navigation](../../crates/desktop/NAVIGATION.md#window-navigation-actions)
  and [focus](../../crates/desktop/FOCUS.md) contracts.
- `5812d6f` adds six independent behaviours to the default
  shell. Hot corners: an `[[outputs]]` entry (upstream's exact-name or `*` rule,
  matched against the display's stable id) binds actions to corners, the shell
  runs upstream's `check_hot_corners` latch over a polled pointer and the
  controller runs the action through the normal dispatch (`hot_corner`), with
  the pointer position and modifier state the corner fired under, so a corner
  bound to `focus-center` or `cycle-windows` behaves as that key binding does.
  `send-to-output` and `send-cursor-to-output`: upstream's `output_in_direction`
  over the outputs' `screen_bounds`, the focused window teleported to the target
  viewport's `focus_placement` point, and the cursor move returned as a
  `warp_pointer` effect the shell performs. `switch-layout`: a `switch_layout`
  effect, performed by selecting among the keyboard input sources the user has
  already enabled, with the selected source reported back (`layout_changed`) and
  answered by the IPC `Layout` request and `StateInfo.layout` / `layout_short`.
  The IPC event stream: `Subscribe` and `msg subscribe` with upstream's ack,
  snapshot, per-change `Event::State` lines, hash dedupe and two-slot coalescing.
  `autostart`: run once, 100 ms after launch, never on reload; each command,
  like every `exec`, is given `INFINIFY_SOCKET`, the socket the app serves, in
  place of upstream's `WAYLAND_DISPLAY`, so a `msg` in it reaches the instance
  that started it. Upstream's
  Linux-only default commands: a default binding whose program is not on `PATH`
  is replaced by a macOS equivalent (`mod+l` puts the displays to sleep with
  `pmset`), or left to macOS (volume, brightness and media keys), and a binding
  the user wrote is registered as written. Coverage is controller scenarios
  through the exported C ABI (`crates/desktop/tests/platform_actions_flow.rs`,
  additions to `config_flow.rs` and `ipc_flow.rs`, and one scenario in
  `navigation_actions_flow.rs` for a corner that runs window navigation) plus
  two launches on 2026-10-09 of the built app in `--windowed` mode on a private
  scene, config and
  socket (macOS 27.2, Apple Silicon, one display, one enabled input source, three
  seeded detached placeholders), which left no saved evidence. Exercised there
  through the socket: the event stream end to end (ack, first state, one line
  per frame of a flight and none while idle, no repeated line, eight subscribers
  and a ninth refused, requests on a subscribed connection, a clean end when the
  app exits); `msg layout` and `state` carrying the launch layout report; an
  autostart command starting once and not again on `reload-config` or a watched
  file change; in two further launches after review fixes, an autostart child
  and an IPC `exec` child carrying `INFINIFY_SOCKET` as the served socket path
  (the file's `[env]` value once it set one), and an autostart `msg` with no
  `--socket` answered through it; and the single-display answers of `send-to-output` (window
  unmoved) and `send-cursor-to-output` (no effect). Evidence boundary: no hot
  corner fired (no pointer was moved into one, and arming is not readable over
  the socket); the pointer was never warped and no window was sent to another
  display (one display); no input source was selected and no input-source change
  was reported (`switch-layout next` ran with one source enabled and selected
  nothing); `pmset displaysleepnow` was not run, and it locks the session only
  as far as the user's Lock Screen setting does; the hot keys for
  `send-to-output` were not registered (`--windowed` registers none); the
  30-second drop of a stalled subscriber, `subscribe` before the canvas opens and
  autostart in a chooser launch were not reached; nothing drawn was observed; no
  window had a bound source. Known mismatches: the pointer is sampled every 80 ms
  (every frame during a flight) instead of on every motion, and a corner is measured on
  the display's panel (toolbar strip included) rather than on the output;
  subscribers are capped at eight and a stalled one is dropped, where upstream
  does neither; a change of active output alone is found at the next idle poll
  (80 ms) rather than the next frame; an `[env]` `INFINIFY_SOCKET` wins over the
  one the shell adds, where upstream's `WAYLAND_DISPLAY` insert overwrites;
  `layout_short` is a language code, not an xkb token; fullscreen and pinned
  legs of the output actions do not exist; `[input.keyboard]` layout options and
  `[[outputs]]` `scale`, `transform`, `position` and `mode` stay read and
  unused. See the
  [desktop shell notes](../../native/desktop/README.md#displays-hot-corners-layouts-and-autostart),
  the [configuration contract](../../crates/desktop/CONFIG.md#outputs) and the
  [event stream contract](../../crates/desktop/IPC.md#event-stream).
- `1f44d0f`, window lifecycle: every ordinary application
  window is meant to live on the canvas by itself, as every toplevel is managed
  in DriftWM. The controller adopts a window that appears into a waiting slot of
  its application or places it with upstream's `window_placement` policy
  (`center`, `cursor`, or `auto` through `driftwm-core`'s own `place_auto`, with
  upstream's cascade), then raises, focuses and navigates to it with
  `zoom.reset_on_new_window`; `window_closed` removes it or leaves a stand-in by
  `session.suspend_on_close`, a window rule or a close/suspend mark that
  lapses after upstream's 10 seconds, with upstream's focus-follow tiers and
  `navigation.auto_navigate_on_close` read from the one focus history that
  `cycle-windows` walks, which a shell without native focus fills by answering
  each request `focus_logical`, so they need no report of native focus;
  `retitle` follows titles; `close-window`, `suspend-window` and the IPC
  `Close`, `Suspend` and `Relaunch` requests run and return `close_window` and
  `launch` effects, a relaunch staying pending for upstream's 30 seconds. The
  macOS rule that replaces upstream's session restore: applications outlive
  Infinify, so the scene file keeps one slot per window (stand-ins listed in an
  additive `standins` key), running windows are re-adopted into their slots by
  bundle identifier and title in a discovery pass at launch and whenever the
  canvas reopens, a slot whose titled window the pass names as existing off
  screen keeps waiting for it, and at `adoption_complete` the other unmatched
  slots are dropped unless `session.restore_windows` keeps them as stand-ins;
  a config file refused at launch decides nothing. The shell gains a window
  manager (discovery over the window list, ScreenCaptureKit streams started and
  stopped on demand, an Accessibility close-button press on a freshly validated
  identity, `NSWorkspace` launch), opens the canvas at launch when Screen
  Recording access exists, and keeps the chooser-first run as `--manual`.
  It lands on top of `c11fece` and `5812d6f`: the focus request of a new
  window and of the window that follows a close goes to the navigation
  coordinator like every other (performed natively, or answered
  `focus_logical`), the controller keeps one focus history for cycling and for
  the close tiers, the IPC event stream reports the windows that come and go,
  and `close-window` and `suspend-window` are reported as implemented by
  `bindings`, leaving six of upstream's default key bindings on actions that do
  not run.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/lifecycle_flow.rs`, synthetic identities, expected
  positions derived by hand from upstream's rules, expiry driven by
  `tick_navigation` timestamps) plus ten short scripted launches on 2026-10-09
  of the built app on a private scene, config and socket (macOS 27.2, Apple
  Silicon), six on the build before the review fixes and four on the build with
  them, which left no saved evidence, and one more of the merged build on the
  same day (below). Those ten launches had neither Screen
  Recording nor Accessibility access. Exercised there: the windowed canvas
  opening and reporting on stderr that it manages nothing; `state` with seeded
  waiting slots (and, in the earlier six, one stand-in); `close`, `suspend`,
  `relaunch`, `close-window` and `suspend-window` on placeholders (dismissal,
  upstream's error replies, a relaunch of a bundle identifier with no
  application reported and survived, and in the later four a second request for
  it answering `ok` with no second attempt); the stand-in list in the scene
  file and after a restart (earlier six); `--manual` opening on the chooser
  with no canvas; exit on SIGTERM. The launch of the merged build, `--windowed`
  with no Screen Recording access (the missing-Accessibility note was not
  printed, so that access presumably existed; it was not checked), repeated on
  one build what the earlier milestones and this one had shown apart:
  `center-nearest right` landing on the seeded window at 1950 0,
  `pan-viewport right` moving the camera 100 points, `zoom-to-fit` and back,
  the not-managed line on stderr, three waiting slots in `state`,
  `focus --id` then `close-window` dismissing one, `suspend` and `relaunch`
  answering as above, an `exec` child and the autostart command both carrying
  `INFINIFY_SOCKET`, and a `subscribe` client receiving the state without the
  dismissed window; it exited 0 on SIGTERM with its socket removed.
  Evidence boundary: no window was discovered,
  adopted, placed, captured, retitled, closed or relaunched;
  `adoption_complete` was never sent, so the slot drop, held slots, the refused
  config rule and `restore_windows` were not exercised in the app; no mark or
  relaunch was seen to lapse there and no close was followed; the close-button
  press, on-demand capture and the launch of a real application are compiled
  and read only; no hot key (⌃⌥Q is now registered), status line or pixel was
  observed; one output only. Known mismatches: expiry is measured on the
  navigation clock the host ticks, not a wall clock, and the identity match of
  a pending relaunch stays open for the whole 30 seconds because there is no
  activation token; slot matching by title is a macOS addition and is greedy
  one window at a time; no parent, modal, widget, pin or fullscreen tiers;
  window rules apply only `suspend_on_close` and `restore_windows`; the native
  focus request for a new or follow-focused window has never been performed on
  a real window, and with native focus allowed a window whose request failed
  or was superseded is in no tier's history; upstream's blank-slate rule for
  auto placement after a click on empty canvas is not carried over; stand-ins
  have no upstream chrome and no click or Enter relaunch; a window that is off
  screen during a discovery pass keeps its slot only if it is titled and the
  slot has that exact title. See the
  [lifecycle contract](../../crates/desktop/LIFECYCLE.md) and the
  [desktop shell notes](../../native/desktop/README.md#managed-windows).
- `f083155`, camera motion, makes the camera move as DriftWM's does. The
  controller keeps upstream's own `MomentumState` (`driftwm-core`) per output and
  gains additive commands and fields: a timed `pan` scaled by
  `navigation.trackpad_speed` or `mouse_speed`, `pan_end`, a `pointer` report,
  `zoom_by` for wheel and pinch at the config's zoom speeds, and a pointer on
  `gesture_to`. Its frame tick runs scroll momentum, edge pan, zoom and camera in
  upstream's order. A released pan drifts by `navigation.drift`; a window dragged
  into the `[navigation.edge_pan]` zone pans the canvas beneath it with upstream's
  ramp and its wait at an edge that borders another output; `toggle-cursor-pan`
  runs, switching a cursor edge pan that `edge_pan.cursor_pan` seeds at launch.
  The shell stamps pans with their event time, ends them at the scroll phase's
  end, on release or 50 ms after the last pan (a scroll under a held drag pan
  ends with the release), drops macOS's own inertia events for canvas pans,
  passes the pointer with window drags, reports it while cursor pan is on and
  no button is held, and no longer computes zoom factors. The trackpad gestures
  of the next bullet pan, pinch and drag through these same paths, and the
  shell's pinch reaches the controller as a gesture, not as `zoom_by`. Coverage is nine controller
  scenarios through the exported C ABI (`crates/desktop/tests/motion_flow.rs`),
  in which momentum is compared bit for bit with upstream's `MomentumState` and
  edge pan, cursor pan and both zooms with values derived by hand from upstream's
  formulas; the headless coordinator regression; and one scripted session on
  2026-10-09 against the built app in `--windowed` mode on a private scene,
  config and socket (macOS 27.2, Apple Silicon, three seeded detached
  placeholders), which left no saved evidence. Exercised there through the
  socket: `toggle-cursor-pan` accepted twice; a config file setting `drift`, the
  pan and zoom speeds and every `[navigation.edge_pan]` key loaded, then replaced
  and reloaded, with nothing on stderr; `pan-viewport`, `zoom-in`, `zoom-reset`,
  `home-toggle`, `zoom-to-fit`, `go-to-bookmark` and a camera write each landing
  exactly through the reordered tick; `debug-counters`; exit on SIGTERM. The
  app built with the next bullet's gestures on top was driven once more the
  same way: the toggle accepted twice, a motion config loaded and reloaded with
  nothing on stderr, and the same actions landing exactly. Both were built on
  `4dd642b`. Merged onto `c11fece`, `5812d6f` and `1f44d0f`, the frame is the
  navigation coordinator's tick in every normal run, the action prelude ends
  an open cycle and stops momentum in one place for keys, IPC, hot corners and
  gestures, and the flights those commits arm (window navigation, a completed
  click's reveal, a new window, the follower after a close) stop a coast as
  every flight does; that build passed the motion, gesture, navigation,
  lifecycle, platform, config and IPC controller scenarios and the coordinator
  regression, and was driven once on 2026-10-10 in the same way (6.9 seconds,
  no Screen Recording access): the toggle accepted twice with the camera
  unmoved in between, a file with `drift`, the pan speeds, two edge-pan keys
  and `zoom.trackpad_speed` loaded with no config line on stderr,
  `center-nearest`, `center-window`, `pan-viewport`, `zoom-to-fit` and
  `home-toggle` landing exactly on that tick, and a `subscribe` client
  receiving 46 State lines, none repeated, over the 1.6 seconds of two of
  those flights.
  Evidence boundary: momentum, edge pan and cursor edge pan need real scroll and
  drag input, which cannot be injected, and were not exercised in the running
  app. Neither were wheel or pinch zoom, the config speeds on a real gesture, the
  dropping of macOS inertia events, the rule that tells a rest from a flick by
  event times, or the 50 ms launch delay inside the app (it was run alone in a
  throwaway harness). The cursor-pan flag cannot be read over the socket, so the
  toggle's acceptance was observed and its effect was not. Nothing drawn was
  observed, no hot key was registered, no window had a bound source, and there
  was one output, so the wait at a shared edge ran only in the controller
  scenarios. Known mismatches: a drag stays on the output it began on, zoom is
  refused during a window drag, only edge pan carries a dragged window, a resize
  gesture and touch arm no edge pan, and the pointer is never warped. Edge pan
  speed was that of the shell's 60 Hz timer until the frame timer became a
  display link on 2026-10-10: it is per frame of the display now, as
  upstream's is. See the
  [desktop shell notes](../../native/desktop/README.md#camera-motion) and the
  [motion contract](../../crates/desktop/MOTION.md).
- `f083155`, trackpad gestures, brings upstream's dispatch
  of libinput's swipe, pinch and hold gestures (`src/input/gestures/`) to the
  controller behind three additive commands, `gesture_begin`, `gesture_update`
  and `gesture_end`, resolved against the `[gestures]` tables with upstream's
  precedence: three-finger swipe pans and coasts, pinches zoom around the
  pointer or fire `zoom-to-fit` and `home-toggle` at the configured thresholds,
  a hold fires on release, a three-finger tap followed by a swipe moves the
  window under the pointer, and `set-trackpad` turns the dispatch off and on.
  It is built on the camera-motion milestone above and adds no camera
  machinery of its own: a swipe that pans is that milestone's timed pan and
  `pan_end`, on its one momentum per output; a pinch that zooms is its pinch,
  with the dynamic minimum and the end snap; and a swipe that moves a window
  drives the pointer's drag, edge pan included. macOS hands no such gestures to an
  application, so the shell stands where libinput stands: canvas views accept
  raw indirect touches, a new recogniser (`native/desktop/trackpad-gestures.m`)
  turns three or more fingers into those event streams by rules written out
  beside the libinput behaviour each imitates, and AppKit's two-finger magnify
  is routed through the same commands and no longer through `zoom_by`. Coverage is controller scenarios with
  synthetic event streams through the exported C ABI
  (`crates/desktop/tests/gesture_flow.rs`), in which a swipe's coast is compared
  bit for bit with the same deltas sent as that milestone's timed pans; the recogniser fed scripted touch
  sequences in throwaway command-line programs, once with its events passed on
  to the real controller library, which accepted every one; and scripted
  sessions on 2026-10-09 against the built app in `--windowed` mode on a private
  scene, config and socket (macOS 27.2, Apple Silicon, three seeded detached
  placeholders), the last of them on the build that holds both of these
  milestones. None of it left saved evidence. Exercised through the socket:
  a config with a `[gestures]` override loading cleanly, malformed gesture
  entries reported in upstream's words and skipped while the rest of the file
  applied, a `[gestures]` value of the wrong type refused whole with its
  predecessor kept, `set-trackpad on`, `off` and `toggle` and their argument
  errors, the view actions landing as before, and exit on SIGTERM; on the
  build with both milestones, a file holding motion settings and a `[gestures]`
  override loading and reloading cleanly, `set-trackpad` and
  `toggle-cursor-pan` answering, and the view actions landing as before. Those
  builds stood on `4dd642b`, where `center-nearest`, `center-window` and
  `cycle-windows` were still refused. Merged onto `c11fece`, `5812d6f` and
  `1f44d0f`, a gesture's threshold or hold action runs through the one action
  dispatch with the gesture's pointer and the modifier state of the event that
  fires it (a new optional `held` on `gesture_update` and `gesture_end`), so
  the four-finger swipe, the `mod` three-finger swipe and the two default
  holds run window navigation and a swipe bound to `cycle-windows` holds its
  cycle open or commits it as a key binding does; a move's drag ends, with its
  edge pan, when its window closes by itself; and in the shell a gesture
  reply's focus request goes to the navigation coordinator and a press ends an
  open cycle, then the gesture, then every flight and coast. `gesture_flow`
  covers these with synthetic streams, and reads upstream's 22 default gesture
  bindings one by one: 14 run, 6 are refused by name and the 2 resizes are
  gated (13 and 7 at this commit; `zoom-to-fit-snapped` runs since the window
  sizing milestone below). On 2026-10-10 that build was driven once over its socket (6.9
  seconds, private scene, config and socket): a `[gestures]` override with a
  named swipe bound to `cycle-windows forward` and a hold bound to
  `focus-center` loaded with no config line on stderr, `set-trackpad off`,
  `on` and `toggle` answered `ok` and `set-trackpad maybe` upstream's message,
  and `center-nearest right`, which the earlier sessions saw refused, flew to
  the seeded window and focused it. Evidence
  boundary: **no physical trackpad gesture was performed**, which an automated
  session cannot do. No gesture event has reached the merged app either: a
  gesture firing window navigation, `held`, hold-to-commit from a gesture and
  the merged press path are controller scenarios and compiled shell code. The recogniser's events were passed to the controller
  library before it was joined to camera motion, and not again since. The shell's touch forwarding, timers, magnify routing and
  gesture sink have only been compiled; whether macOS delivers three- and
  four-finger touches to the canvas panel, real-finger behaviour, how the
  recogniser's thresholds feel, and coexistence with macOS's own gestures
  (Mission Control, App Exposé, the full-screen swipe, Launchpad, Show Desktop,
  three-finger drag, which the user must turn off in System Settings; nothing
  here changes a setting) are untested; the recogniser's constants are from
  memory of libinput and were not checked against its source; expected values
  are derived by reading upstream's handlers, which were not executed as an
  oracle; nothing drawn was observed. Six of upstream's default gesture
  bindings name three actions that do not run in a default launch
  (`fit-window`, `fit-window-snapped`, `toggle-fullscreen`; the first two run
  behind `--experimental-native-resize`, and `zoom-to-fit-snapped`, the fourth
  at this commit, runs since the window sizing milestone below), gesture
  resize is gated with native resize, an unbound
  gesture is not forwarded to the application under it, a move gesture stays
  inside its output, three fingers resting
  mid-swipe do not start the drift that upstream's 50 ms timer starts,
  `set-trackpad off` cannot
  silence the pointer or two-finger scrolling, and `[touch.*]` stays unused. See
  the [gesture contract](../../crates/desktop/GESTURES.md) and the
  [desktop shell notes](../../native/desktop/README.md#trackpad-gestures).
- `43a1525`, per-window policy: `[[window_rules]]`,
  widgets and screen-pinned windows. The controller resolves a window's rules
  once, when it maps, with `driftwm-core`'s own matcher and merge (the bundle
  identifier as `app_id`, the source title as `title`), and applies `position`
  (frame center, Y up, ahead of `window_placement`), `widget`,
  `pinned_to_screen` with `output` and its output-relative `position`,
  `focus_on_open` and `opacity`; a retitle and a config reload re-resolve
  nothing, as upstream documents. A widget stays below every window and out of
  the focus history, snapping, clusters, fitting and auto placement, and is
  refused by drags, resizes, nudges and IPC `Focus` and `Suspend`; a pinned
  window keeps a place and its own size on one output whatever the camera and
  zoom, above that output's canvas windows. `toggle-pin-to-screen` and
  `move-to-bookmark` run, IPC `Pin` and `Opacity` answer with upstream's shapes
  and refusals, `Move` and `Resize` refuse a pinned window, and `State` fills
  `pinned` and `is_widget`. `snapshot.placements` and `hit` follow upstream's
  layer order (widgets, canvas windows, pinned windows) and carry `widget`,
  `pinned` and `opacity`; the shell's compositor draws a widget below and a
  pinned window above the canvas windows, the pinned one from its screen
  rectangle at its own size, each at that opacity (the rendering milestone
  below; probe, demo and owned-fixture runs fade their layer tiles instead),
  and the shell starts
  no move or resize gesture on a widget or a pinned window (a widget still
  gets the press as a click), and after registering its displays it sends the
  one new command, `outputs_settled`, on which a pin whose display is gone
  moves to one that is there. A close never hands the focus to a widget or a
  pinned window. Widgets are never saved; a pin is saved with its slot in an
  additive `pins` key. Coverage is
  controller scenarios through the exported C ABI
  (`crates/desktop/tests/rules_flow.rs`, synthetic observations on two outputs,
  expected rectangles derived by hand from upstream's conventions) plus one
  scripted launch of the built app in `--windowed` mode on a private scene,
  config and socket (macOS 27.2, Apple Silicon), first on 2026-10-09 and
  repeated on 2026-10-10 on the build with the review fixes, which left no
  saved evidence; what follows is the repeat. That launch had no Screen
  Recording access, so no window was captured and every window was a
  placeholder; the two pins in it were made beforehand by a throwaway program
  driving the same controller in process with synthetic sources, one of them
  on an output the app never registers, and read from the scene file by the
  app. Exercised in the app through the socket: the pin saved on the missing
  output listed under `State.pinned` on the app's one output from the first
  read on, which with no discovery pass in that run is the shell's
  `outputs_settled`; both pins unchanged by a pan and a `move-to-bookmark`
  while the canvas points under them followed the camera (a zoom was run only
  on 2026-10-09); upstream's `Move` and `Resize` refusals for a pinned
  window; `Pin` and `Opacity` refusing placeholders (`stand-ins can't be
  pinned`, `no window with id N`) and `toggle-pin-to-screen` leaving a focused
  placeholder alone; `move-to-bookmark` centering a focused placeholder and
  passing over an unset name and the pinned one; rules in the config changing
  no window that did not map; upstream's unknown-decoration warning and its
  TOML error for an unknown rule key; the moved pin in the file saved at exit;
  exit on SIGTERM. After the renderer below was built in with it, one more
  one-second launch the same day read a scene with one pinned placeholder:
  listed under `State.pinned` unchanged by a pan and at zoom 0.5 while its
  canvas point followed the camera, absent from three viewport screenshots as
  upstream excludes a pinned window from canvas captures, alone in a `window`
  screenshot and outside the frame of `all`, with the same `Pin`, `Opacity`,
  `Move` and `Resize` refusals. Evidence boundary: rules, pinning and widgets were exercised
  live only on placeholders through the socket, and no captured window was
  involved. No rule was resolved in the app, no widget existed there, no live
  window was pinned, unpinned or given an opacity there (those ran only in the
  controller tests and the seeding program), no window closed there (the
  focus-follow rules ran only in the controller tests), and what the app's
  own panel draws was not observed: the layer order, the pinned space and a
  written opacity were seen only in frames an offscreen tool read back from
  the shell's renderer driven by this controller (the rendering milestone
  below); no pointer press was
  made, so the shell's refusal notes and click routing to a widget or a pinned
  window are compiled and read only; ⌃⌥T is now registered and was not
  pressed; one output only, so a screen change and Return to desktop with a
  pin in place were replayed only as controller commands in the shell's
  order. Known mismatches: a rule's `size` is recorded and not applied in
  every default launch, and is asked of a new window only behind
  `--experimental-native-resize` (the window sizing milestone below);
  `fullscreen` is recorded and not applied;
  `preserve_aspect_ratio` was recorded with no effect at that commit (since
  2026-10-11 a pointer or gesture resize keeps it, see the counts below), and
  `layer_order` is recorded with no effect, which upstream itself ignores for
  a regular window
  (`decoration` and the border, corner and shadow fields are drawn, see the
  rendering milestone below, `blur` is frosted, see the effects milestone
  below, and `pass_keys` and `pass_mouse` act, see the pass-through
  milestone below); a pinned window
  cannot be resized, and is moved only by the move binding's pointer drag
  and the move gesture (the pass-through milestone below), where upstream's
  resize binding, its resize gesture and its title bar also move and resize
  it in screen space (unimplemented here); a pin leaves a display that is gone only when the shell reports its
  displays settled (`outputs_settled`), where upstream rehomes it at the
  unplug, because the shell removes and re-registers every display on any
  screen change; a window pinned by toggle that closes has no spatial
  follower, where upstream tests the snap rectangle it had before the pin; the
  pin is saved with the slot, where upstream's session file holds none, and a
  saved pin is clamped onto its output at launch; a pin waiting on a slot no
  window has taken reads `stand-ins can't be pinned` while `State` lists it;
  upstream's pin dot is drawn only in a compositor title bar, which a Mac
  window has only under a `server` rule; a widget that maps does not hand the focus back to
  the head of the history; `[decorations] opacity` and `opacity_focused` follow
  the canvas's logical focus, not native keyboard focus. All of the above was
  built on `4dd642b` with the window lifecycle. Merged onto `c11fece`,
  `5812d6f`, `1f44d0f` and `f083155`, there is one focus history, which a
  widget and a pinned window never enter whoever answers their focus request
  (`focus_result`, `focus_logical`, `observe_focus`, a native activation); the
  candidates of `center-window`, `center-nearest`, `focus-center` and
  `cycle-windows` are the canvas windows, `center-nearest` does not anchor on a
  pinned window and `focus-center` passes over one; no completed click and no
  followed native focus flies to either; a move gesture over a widget falls
  back to a pan and over a pinned window moves it in screen space (the
  pass-through milestone below; it was claimed and inert before that), and a
  gesture's drag is released when its slot maps as a widget; `send-to-output` leaves a
  widget and rebinds a pin to the adjacent display; `toggle-pin-to-screen` and
  `move-to-bookmark` run through the one action dispatch, whose prelude ends
  an open cycle and stops momentum, from keys, IPC, hot corners and gestures;
  the event stream carries `pinned` and `is_widget`; and `outputs_settled` is
  sent from the `openPanels` every launch, Open canvas, chooser attach and
  screen change goes through. Four scenarios added to `rules_flow` cover
  those joins against a layout with a widget and a pinned window in the way,
  each beside a control showing what an unfiltered search or grab would have
  taken; the earlier scenarios were restated for the one history. Asked with
  upstream's built-in defaults, the controller's `bindings` reply listed
  45 key bindings of which 41 ran, leaving four on actions that did not
  (`toggle-fullscreen`, `fit-window`, `fit-window-snapped`,
  `zoom-to-fit-snapped`), and of the 35 action names of upstream's grammar it
  refused seven by name (those four, `grow-window`, `shrink-window` and
  `fill-window`); the window sizing milestone below has the counts with
  `zoom-to-fit-snapped` running. The merged
  app was launched three times on 2026-10-10 as before (6, 16 and 8 seconds,
  three placeholders, no Screen Recording access, nothing saved): a
  placeholder pinned in the scene file stayed under `State.pinned` through a
  pan and a zoom and in all 463 lines of a `subscribe` stream, out of the
  viewport captures and alone in a `window` capture; `Pin`, `Opacity`, `Move`
  and `Resize` gave the same refusals; `toggle-pin-to-screen` left a focused
  placeholder alone and `move-to-bookmark` moved one; with the pinned
  placeholder focused, `center-nearest` and `center-window` chose a canvas
  placeholder. That adds nothing to the evidence boundary above but the event
  stream: the joined navigation, activation, gesture, hot-corner and
  `send-to-output` rules ran only as controller scenarios, with no live
  window, widget, second display, key, pointer press or gesture in the app.
  Further mismatches from the join: `focus-center` takes no widget, where
  upstream's walk reaches one and flies to it; a click raises a widget among
  the widgets, where upstream only focuses it; a move gesture does not move a
  pinned window, where upstream's does in screen space; `send-to-output` takes
  a pin's own output as its source, where upstream takes the output showing
  the pin's canvas frame. See the
  [rules contract](../../crates/desktop/RULES.md) and the
  [desktop shell notes](../../native/desktop/README.md#window-rules-widgets-and-pinned-windows).
- `43a1525`, rendering: the canvas of a normal run is
  drawn the way DriftWM draws it. A Metal port of upstream's frame composition
  and canvas background (`native/desktop/compositor.{h,m}`,
  `background.{h,m}`; upstream's border, shadow and corner-clip shaders and its
  dot grid, tile and wallpaper shaders hand-translated, user GLSL shaders
  translated at load; built, checked against the unmodified upstream GLSL and
  independently reviewed outside the repository, then carried in with its
  notes) replaces the per-placement display layers on a flat colour: one layer
  per output draws the `[background]` in its five types, the outlines of the
  other outputs' viewports from `[output.outline]`, every window bottom to top
  with upstream's shadow, border, corner clip and opacity resolved by
  `driftwm-core`'s own `effective_*` helpers from `[decorations]` and the
  rule each window mapped with (the per-window policy above, an IPC `Opacity`
  write included: nothing is matched again when a frame is described),
  widgets in upstream's bucket below the canvas windows and screen-pinned
  windows in the one above, drawn from their screen rectangle at zoom 1
  whatever the camera, and upstream's stand-in (bar, close glyph, body, application
  name, `launching…`, always opaque) for a window without a source. The
  controller describes the frame in an additive `render` block and
  per-placement keys and bumps a revision on every accepted reload, so that
  the shell reads the background's shader and image files again as upstream
  does; `msg screenshot` runs with
  upstream's four targets, scale rule and refusals as a deferred effect the
  shell renders offscreen with the same compositor; a canvas capture holds no
  screen-pinned window and draws widgets below the other windows, `all`
  frames the canvas windows and stand-ins only, and a `window` capture takes
  a pinned window or a widget alone, all as upstream's does. macOS rule: a captured
  native window already draws its own title bar, so it is decorated as
  upstream decorates a client-side-decorated window unless a rule says
  otherwise. Probe, demo and owned-fixture modes keep the earlier drawing.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/render_flow.rs`, regions and pixel sizes derived by
  hand from upstream's functions) plus three short scripted launches on
  2026-10-09 of the built app in `--windowed` mode on a private scene, config
  and socket (macOS 27.2, Apple Silicon, three seeded placeholders) and two
  more on 2026-10-10 after the review fixes, none of which left saved
  evidence; and, once built together with the per-window policy above, one
  scenario across both contracts in `crates/desktop/tests/rules_flow.rs`, an
  offscreen tool and two further launches the same day, described at the end
  of what was seen. Seen there, in the PNGs `msg screenshot` wrote, each
  opened and its pixels read: the stand-ins at their seeded canvas positions
  to the pixel at zoom 1 and after `zoom-to-fit`; application-name labels and
  the `launching…` label; the default dot grid, a static, an animated and
  a textured upstream shader, a tile with and without
  `mirror_tile`, a wallpaper and `none`, each adopted from a config rewrite
  without a restart; a missing and a non-compiling shader falling back to the
  dot grid with the reason on stderr; border width and both border colours
  with the focus following `msg focus`, corner radius, shadow on and off,
  chrome colours, bar height and font; all four
  targets, `--from-screen`, `--scale`, and the refusals including two
  unwritable paths; exit on SIGTERM. Seen in the two later launches, after a
  review had found each as a defect in the earlier build: stand-ins opaque
  under `[decorations] opacity = 0.5` (alpha 255 in a `window` capture, one
  body colour in `all`); `-o -` relaying bytes equal to a file capture of the
  same target; a shader file replaced behind an unchanged config picked up by
  `reload-config` alone, a broken one falling back after a `touch` of the
  config and the repaired one drawn again; a wallpaper lying only over the
  view's footprint in `region`, `all` and `--from-screen` captures and
  transparent elsewhere; and the count of Metal drawables in the running app
  staying at 1 over six seconds of an animated background. Seen with the
  per-window policy built in: in frames read back from the shell's renderer,
  linked with the compositor and this controller into a throwaway tool
  outside the repository (synthetic sources with plain-coloured buffers, one
  output off the global origin), a rule-pinned window at one output-local
  rectangle and size at zoom 0.5, after a pan and at zoom 1 while a canvas
  window and a widget moved and scaled, the widget under the canvas window
  and the pinned window over it, a written opacity of 0.5 as the blend it
  should give, and a pinned detached slot as an opaque stand-in; the
  controller's own capture effects performed by that renderer without the
  pinned window in `viewport`, `all` and `region` and with it alone in
  `window`; and in two more launches of the built app (3 and 1 seconds, three
  placeholders), the viewport, `zoom-to-fit`, `window`, `region`, `-o -` and
  missing-shader results as before, and a placeholder pinned in the scene
  file absent from viewport captures before and after a pan and at zoom 0.5,
  alone in a `window` capture and outside `all`'s frame. Evidence boundary:
  no launch had Screen Recording access, so every window was a stand-in and
  no captured window was ever drawn through the compositor: its colour,
  alpha, the sRGB stream setting, the kept last frame, frame-driven redraw
  and the opacity a live window is captured alone with are compiled and read
  only. A screenshot is an offscreen render: the layer in the app's
  own panels was not seen on a display (orientation and stacking were checked
  only on a throwaway panel built the same way, before integration), so the
  widget and pinned layers were never seen there either, nor were
  the status-line copy of a fallback, an animated background on screen, a
  second output and its outline, a window rule, `default_mode` or a `server`
  title bar in the app, the experimental native-resize presentation through
  the compositor, or any probe, demo or owned mode after the change. No pixel
  was compared with a pixel from DriftWM itself. Known mismatches: blur,
  `[effects]` and the open and close animations were not drawn by this
  milestone and are by the effects milestone below, and move and resize
  animations are not drawn at all; `cache_shader` was
  accepted and ignored (a shader always rendered live) and gigapixel TIFF
  tiles were not supported by this milestone, and both are drawn since the
  background caches milestone below; text is CoreText's,
  not cosmic-text's; a window whose rectangle lies just outside an output
  casts no shadow into it; a screenshot path's missing directories are not
  created; captures are not tiled; in a capture a wallpaper is cover-cropped
  to its output's footprint as on screen, where upstream's capture element
  samples the whole image across it; a stand-in's label needs the application
  installed to be a name rather than a bundle identifier; a `server` rule
  draws a second title bar above a Mac window's own; a detached slot that
  still holds a pin is drawn pinned and left out of canvas captures, a state
  upstream never has; no fullscreen, layer surfaces or popups. All of the
  above was built on `4dd642b` with the window lifecycle. Merged onto
  `c11fece`, `5812d6f`, `1f44d0f` and `f083155`, the shell has one drawing
  path and one frame timer: each redraw adopts the `render` settings, draws
  through the compositor, notes whether cursor edge pan wants the pointer and
  schedules the State event for subscribers; the timer runs while the
  controller reports camera motion (a flight, a coast, an edge pan) or a panel
  shows an animated background and stops when neither is left, ticking the
  camera and watching the hot corners only while it serves motion; the
  autorelease pool per turn of the main loop and per layer flush is kept; and
  a `Screenshot` is rendered and answered inside its own request, beside the
  long-lived `subscribe` connections. `render_flow` passes with the
  snapshot's `keyboard_layout` and `trackpad` keys beside `render`. Seen in
  the three launches of 2026-10-10 named under the per-window policy above:
  the viewport, `zoom-to-fit`, `window`, `region` and `-o -` captures and the
  missing-shader fallback as before; the focused border colour on the
  stand-in `center-nearest` had just flown to; three screenshots answered
  on other connections while a `subscribe` client went on receiving the
  frames of that flight (12, 24, 35 and at last 148 lines), with no
  consecutive line repeated in any stream; and, under an animated shader
  background, two captures half a second apart differing, a subscriber
  receiving nothing while only the background animated, and every flight
  landing exactly. Not seen: the panel on a display, so neither the layer
  there nor the timer's redraws of an animated background; a hot corner,
  cursor edge pan or a coast on the joined timer. See the
  [rendering contract](../../crates/desktop/RENDER.md), the
  [desktop shell notes](../../native/desktop/README.md#rendering) and the
  [compositor notes](../../native/desktop/COMPOSITOR-NOTES.md).
- `271cdc6`, pointer policy: what DriftWM does with a
  pointer that moves. Until now the shell handled no mouse-moved event, so an
  application under the canvas never saw the pointer move,
  `focus_follows_mouse` and `[zoom] interact_min` were read and ignored, and a
  press bound to the mouse action `center-nearest` only said it was not
  implemented. The controller gains `hover` (upstream's `maybe_hover_focus`:
  with `focus_follows_mouse` the topmost window under the pointer, a stand-in
  included, takes logical focus without being raised and without a flight;
  empty canvas keeps the focus; a drag or resize gesture, a native resize that
  has not drained and an open focus cycle hold it back; the reply also says
  whether the motion is the window's to receive), upstream's `pick_mode` per
  output from the live zoom and `zoom.interact_min` (reported by `hit`,
  `input`, `hover` and `snapshot.outputs[].pick`; `input` refuses a pick
  target, so nothing can be forwarded to it; `mouse_binding` takes a `pick`
  flag for upstream's held-modifier rule and its canvas-context retry of an
  unbound scroll), `pick` (upstream's `resolve_pick`: navigate to the window at
  zoom 1, landing per `focus_placement`; since the window sizing milestone
  below, a window filled behind `--experimental-native-resize` returns to its
  fill view instead when that view is at or above the threshold) and
  `pointer_nearest` (upstream's
  `NavigateGrab`: the 16 point dead zone, the octant of press minus pointer by
  `driftwm-core`'s `direction_from_vector`, then the `center-nearest` action).
  A native focus report that is only the echo of a hover's own request is
  recorded without a raise or a flight; a request that failed or was withdrawn
  unanswered stops counting as echoed 3 seconds after its hover, on the
  controller's tick clock. All of it is in one new module,
  `crates/desktop/src/pointer_policy.rs`; `ABI_VERSION` and every existing
  command shape are unchanged. The shell gains `native/desktop/pointer-hover.{h,m}`:
  a tracking area that is always active on each canvas panel of a normal run,
  one `hover` per 60 Hz frame while no button is down and no gesture runs,
  the reply's focus request handed to the navigation coordinator like a
  click's, the motion re-addressed to the window under the pointer through the
  route and validation a click takes, the pick-mode press, drag and release,
  and the swipe; `--no-hover-forwarding` turns off only the delivery of motion
  to applications.
  It was built on `1f44d0f`. Merged onto `f083155`, the pointer has one
  reading in the shell: while camera motion's frame timer runs, each frame
  carries the waiting hover, ahead of cursor edge pan's pointer report and the
  tick, and the hover's own timer runs only while that one does not. What
  holds the pointer now includes a drag pan whose button is down, a trackpad
  gesture between its begin and its end and a scroll pan whose momentum is
  yet to launch, which an optional `time_ms` on `hover` times on the pans' own
  event clock; a coast, a flight and cursor edge pan hold nothing, and no
  hover stops any of them. Below `interact_min` a scroll that finds a canvas
  binding is that milestone's timed pan or wheel `zoom_by`, a drag is a window
  drag with its edge pan, and a trackpad gesture is not changed, as upstream's
  gesture handlers never read pick mode. `pointer_nearest` runs its action
  once through the one action dispatch, with the pointer and a new optional
  `held`, so that dispatch's prelude ends an open cycle and stops the
  output's momentum.
  Merged onto the per-window policy and the rendering milestone above, both
  staged and not committed, the window under the pointer is the layered hit
  (the windows pinned to the output, the canvas windows, the widgets). With
  `focus_follows_mouse` a pinned window under the pointer has the priority and
  takes the focus where it stands, as upstream asks `pinned_window_under`
  first, and stays out of the focus history like every focus of a pinned
  window; a widget is passed over, pinned or not, and keeps the focus where it
  is (`hover_focus_window`); the motion is forwarded to either. The echo of a
  hover on a pinned window is recorded without a raise or a flight. A pick
  target is a canvas window or a stand-in: a pinned window stays interactive
  below `interact_min`, also over a target, a widget is never picked, `pick`
  does nothing with either, and `begin_drag` refuses both as at any zoom. The
  no-raise focus is now `Scene::focus_in_place` in `crates/canvas`, `focus`
  without its raise, in place of a rebuild of the scene through its saved
  form. In the shell the one frame timer carries the waiting hover and the
  pointer report on every frame, also while only an animated background keeps
  it running, a stand-in's hit carries `pick` only when its placement is
  neither pinned nor a widget, and the experimental resize handles are not
  drawn on an output in pick mode.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/pointer_flow.rs`, sixteen scenarios with synthetic
  identities and focus results on an output whose origin is not the global
  origin, two of them for the rules merged from `f083155` and three for a
  pinned window and a widget under the pointer; expected values derived by
  hand from upstream's rules, not from an executed upstream oracle), one build
  that links both sides with
  `-Wall -Wextra -Werror`, and two short scripted launches on 2026-10-10 of the
  built app (`--windowed 1100x700 --manual`, private scene of three detached
  placeholders, config and socket; macOS 27.2, Apple Silicon), which left no
  saved evidence. Exercised there through the socket: a config with
  `focus_follows_mouse = true` and `[zoom] interact_min = 0.5` loading with
  nothing on stderr; eight `zoom-out` actions taking `msg zoom` from 1 to
  0.467, below the threshold, and `zoom-reset` back to 1; a reload with
  `focus_follows_mouse` flipped answering `ok` with nothing on stderr; the file
  watcher reporting upstream's `config: zoom.interact_min -1 below minimum 0,
  using 0` and `config: zoom.interact_min 5 above maximum 1, using 1`; a launch
  with `--no-hover-forwarding` starting and answering `state`, the flag given
  twice exiting 64; exit 0 on SIGTERM with the socket removed. The build
  merged onto `f083155` passed `pointer_flow` with the gesture, motion,
  navigation, lifecycle, platform, config, IPC and view scenarios and the
  coordinator regression, and was launched twice more the same day without
  `--manual` (9 seconds and 1 second, no Screen Recording access): the same
  config loaded with no config line on stderr, `center-nearest right` landed
  on the seeded window at 1950 0 and focused it, `pan-viewport right` moved
  the camera 100 points, `zoom-to-fit` went out and came back, eight
  `zoom-out` actions ended at 0.467 and `zoom-reset` at 1,
  `toggle-cursor-pan` twice and `set-trackpad off` and `on` answered `ok`, the
  reload and the two range warnings came as before, and a launch with
  `--no-hover-forwarding` answered `state`; both exited 0 with the socket
  removed. The build merged onto the per-window policy and rendering passed
  `pointer_flow` with the rules, render, gesture, motion, navigation,
  lifecycle, platform, config, IPC, view and controller scenarios and the
  coordinator regression, and was launched twice the same day (6 seconds and
  under a second, the same three detached placeholders, no Screen Recording
  access): the same config loaded with no config line on stderr,
  `center-nearest right` landed at 1950 0 with the seeded window focused,
  `pan-viewport right` moved the camera 100 points, `zoom-to-fit` went to
  0.2848 and came back, eight `zoom-out` actions ended at 0.4665, where a
  `msg screenshot` of the view showed the focused stand-in on the dot grid,
  `zoom-reset` returned to 1, the reload with `focus_follows_mouse` flipped
  answered `ok`, a `window` screenshot wrote the 900×600 stand-in,
  `toggle-cursor-pan` twice answered `ok`, `msg pin` on a stand-in was refused
  in upstream's words with and without `on`, and a launch with
  `--no-hover-forwarding` answered `state`; both exited 0 with the socket
  removed.
  Evidence boundary: the socket has no pointer and `msg` exposes neither pick
  mode nor `focus_follows_mouse`, so `hover`, sloppy focus, `pick` and
  `pointer_nearest` were exercised only through the controller's C ABI tests;
  in the app only the settings' loading and the zoom crossing the threshold
  were seen. No real pointer motion, no mouse-moved event at a canvas panel, no
  native focus change, no forwarded mouse-moved event, no pick-mode press and
  no swipe was observed in this session, and no window with a bound source was
  on the canvas. What the merges added in the shell (the hover carried by the
  frame timer, also while it serves an animated background alone, the pointer
  reading shared with cursor edge pan's report, the hover standing down for a
  trackpad gesture, a pick-mode scroll that drifts, the handles left off in
  pick mode, a stand-in's pick flag) is compiled and read only, and no pinned
  window and no widget was on the canvas of any launch: a stand-in cannot be
  pinned. Known mismatches: a trackpad gesture in progress
  and a scroll about to launch its momentum hold the pointer from hover,
  which are no pointer grab upstream; the cursor stays the canvas's own (no
  pointing hand over a pick target, no application cursor); no leave is
  delivered when the pointer moves off a window; the native request of a hover
  focus is a click's, so the real window is activated and raised natively
  although the canvas does not restack; the focus history is promoted when the
  request is answered, not at the hover; an open focus cycle blocks hover focus
  where upstream's hover would end the cycle; the echo rule has no upstream
  counterpart; a `pick` returns a filled window to its fill view as
  upstream's does (when that view is at or above the threshold) only behind
  `--experimental-native-resize`, since `fill-window` is gated, and lands at
  zoom 1 in every default launch; pick mode is per output,
  not the active output's; `pointer_nearest` decides from two points, so it is
  upstream's only because the shell sends it once at the first drag event 16
  points from the press; upstream's exclusions for layer surfaces, fullscreen
  and modal windows and client resize margins have nothing to apply to;
  `pass_mouse` and the screen-space drag of a pinned window, which this
  milestone by itself did not have, are the pass-through milestone's below,
  with upstream's pick-mode gate on a claim and a pinned drag that is the
  same below the threshold as above it. See the
  [pointer contract](../../crates/desktop/POINTER.md) and the
  [desktop shell notes](../../native/desktop/README.md#pointer-motion-sloppy-focus-and-pick-mode).
- `1c9bfea`, window sizing, makes DriftWM's sizing
  actions controller policy (`crates/desktop/src/sizes.rs`, adapted from
  upstream's `src/state/{resize,fit,fill}.rs` with driftwm-core's own fill
  search and cluster shifts): `grow-window` and `shrink-window` with
  `[navigation] resize_step` and the opposite edge held, IPC `resize W H`
  keeping the centre, `fit-window` and `fit-window-snapped` with their camera
  flight, saved size and toggle back, `fill-window` with its restore point and
  the view `center-window` returns to, `zoom-to-fit-snapped`, and upstream's
  `Normal` / `Fit` / `Fill` window mode in the IPC state and the snapshot.
  `zoom-to-fit-snapped` moves a camera only and runs in every normal launch.
  The rest end by giving a native window a new size, which goes through the
  existing size-only native resize transaction (`f5007b8`, `6a49484`) started
  without a drag: a new command,
  `native_resize_capability`, turns them on, and without it every one of
  them and the IPC resize write answer byte for byte as before. When this
  milestone landed the shell sent it only when started with
  `--experimental-native-resize`; since 2026-10-11 every normal run sends it
  (see "Sizing and fullscreen in every normal run" under
  "What is still open"). A sizing
  action asks for a size and writes the place, the neighbours' shift and the
  fit or fill state when the native result arrives, for the size the window
  actually took. Evidence boundary: **no native window was resized.** Sizing
  ran only in controller scenarios through the exported C ABI
  (`crates/desktop/tests/sizes_flow.rs`, 21 scenarios when it was built on
  `f083155` alone, 30 with the joins below), in which the test plays
  the native side and answers each resize effect with a made-up result, with
  expected values worked out by hand from upstream's rules and upstream not
  executed as an oracle. Built together with the shell on 2026-10-10 (macOS
  27.2, Apple Silicon), the app was driven twice over a private socket on a
  private scene of three detached placeholders, with no Screen Recording
  access: without the flag the five actions and the resize write answered
  their previous refusals; with it `grow-window`, `shrink-window` and `resize`
  answered the stand-in refusals and the three toggles answered `ok` and
  changed nothing; in both, `zoom-to-fit-snapped` framed a two-window cluster
  at the expected camera and zoom and returned. That is as far as the socket
  reached: a stand-in begins no size transaction, so the shell's hook that
  hands a reply's resize effect to the resize coordinator, its relaxed gates
  during such a transaction, the hot keys, mouse bindings and gestures that
  fire these actions, key repeat on a step and anything drawn are compiled and
  read only, and nothing was saved as evidence. Known mismatches: placement is
  written at the result rather than at the request; one transaction at a time,
  so a second sizing action is continued, replaced or refused where upstream
  sizes any number of windows; native size limits are unknown before asking;
  a step or an IPC resize of a stand-in is refused where upstream resizes the
  stand-in's frame; restore points are lost with the window's source and are
  never saved; upstream's `restore_size` is captured at the first fit or fill
  rather than at a window's first commit; `toggle-fullscreen` is not here.
  All of the above was built on
  `f083155`. Merged with the three milestones above (per-window policy,
  rendering, pointer policy), every sizing action is a canvas window's, as
  upstream's `is_canvas_window` makes it: with a widget or a screen-pinned
  window focused the five actions and `zoom-to-fit-snapped` do nothing, IPC
  `Resize` answers upstream's `this window has no canvas size to set: …` for
  one before the gate is asked, no sizing action and no IPC `Resize` begins
  a size transaction for one (`begin_native_resize` refuses it as before;
  its one size transaction is that of its rule's `size` at its map), and
  neither is an obstacle to a
  fill, shoved by a snapped fit or framed by `zoom-to-fit-snapped`; a window
  pinned after a fit or fill keeps its restore point, as upstream's
  `pin_window` clears neither; `send-to-output` ends a canvas window's fill
  and only rebinds a pin; a window rule's `size` is asked of a new window as
  it maps, a widget and a rule-pinned window included, through the same
  entry as IPC resize, when the capability is on: the window is placed for
  that size, and one that maps while another size is owed is asked in its
  turn, in map order, `rule.not_applied` naming `size` until then; it stays
  recorded and listed in `rule.not_applied` when the capability is off and
  for an adopted slot; a pick below
  `zoom.interact_min` returns a filled window to its fill view when that view
  is at or above the threshold (upstream's `resolve_pick`); `center-window`
  and `focus-center` restore a fill view for canvas windows only; a drag is
  decided in one place, refused for a widget and for a window owed its size,
  each in its own words, and installed in screen space for a pinned window
  (the pass-through milestone below), which owes a size only while its
  rule's `size` is being asked at its map and is refused like any other
  until then; a size still
  owed holds the pointer for
  `hover` as a resize drag does; the snapshot's `mode` sits beside `widget`,
  `pinned` and `rule`; and the shell hands a reply's size transaction to the
  resize coordinator from one method, for every action, IPC, gesture and
  pointer reply and for the attach of a ruled window. Nine scenarios added to
  `sizes_flow` and one to `rules_flow` cover those joins, the test again
  playing the native side. Asked with upstream's built-in defaults, the merged
  controller's `bindings` reply lists 45 key bindings of which 42 run without
  the capability, leaving `toggle-fullscreen`, `fit-window` and
  `fit-window-snapped`, and 44 with it; of the 35 action names of upstream's
  grammar it refuses six by name without the capability (those three,
  `grow-window`, `shrink-window`, `fill-window`) and one with it. The same
  requests sent to the controller as it was before this merge and to the
  merged one, with the capability off, on a scene with a canvas window, a
  widget, a rule-pinned window and a ruled size, gave identical raw replies
  (168 and the saved file, read by a throwaway program outside the
  repository) but for `"mode": null` on each snapshot window and
  `zoom-to-fit-snapped` reported implemented. The merged app was launched
  five times on 2026-10-10 on three detached placeholders (private scene,
  config and socket, no Screen Recording access, nothing saved; the first
  ended at once on a mistake in the driving script, before anything was
  asked, and the two that follow were each run twice with the same answers,
  the second time on the final build): without the flag the five actions and the resize write answered
  their refusals unchanged, `zoom-to-fit-snapped` framed a two-placeholder
  cluster at camera `2236 -0` and zoom `0.6385869565217391`, a viewport
  screenshot of it was written and looked at, and `center-nearest`,
  `pan-viewport`, `zoom-to-fit`, `pin` and `opacity` answered as before; with
  the flag the three toggles answered `ok` and changed nothing and
  `grow-window`, `shrink-window` and `resize` answered the stand-in refusals.
  That adds nothing to the evidence boundary: no live window existed in any
  launch, so no size transaction ran in the app by an action or by a rule, no
  rule was resolved, no widget or pinned window existed there and no pointer
  event was sent; the joins ran only as controller scenarios. Further
  mismatch from the join: a pinned window is not resized by hand, where
  upstream resizes one in screen space. The feature stayed behind
  `--experimental-native-resize` until 2026-10-11, and runs in every normal
  run since. See the
  [sizing contract](../../crates/desktop/SIZES.md) and the
  [desktop shell notes](../../native/desktop/README.md#window-sizing-actions).
- `4eb130c`, effects: DriftWM's background blur, its
  window open and close animations and stand-in fades, and its on-screen error
  bar. The compositor above is replaced by a superset of itself, built, checked
  against upstream's blur shaders and animation curves and independently
  reviewed outside the repository, then carried in with its notes; it is
  API-additive, and the one provenance line of each file is all that differs
  from that copy. The controller reports, all additive to ABI 1 and never
  saved: `render.effects`, the `[effects]` table as `driftwm-core`'s parser
  left it; `decoration.blur`, `driftwm-core`'s `effective_blur` over the rule
  a window mapped with, false for every stand-in; `render.errors`, upstream's
  config error source under upstream's rules (read failure, parse failure,
  one warning with a count, since the gaps milestone below the least in byte
  order where upstream names the parser's first, cleared by a clean load), a
  changed message
  spending a render revision; and `lifecycle_events`, the last 32 window
  events upstream animates, each with a serial: `open`, `close`,
  `close_to_standin`, `standin_dismiss`, `standin_adopted`. The shell's
  renderer frosts a blurred window, shows the controller's message and the
  background program's own in upstream's source order in the bar, and plays
  each event once from the frame it last drew: a closing snapshot baked from
  the window's last picture at upstream's density and listed in upstream's
  closing order, alpha only over the stand-in a close leaves, the open
  animation from the window's first picture, and the two stand-in fades, all
  on the one frame timer, which stops when the last ends. macOS rules: the
  windows of the launch pass and a window that takes its own saved slot back
  open nothing, since none of them opened in the canvas; an opening window is
  held invisible until its stream delivers its first picture, a second at
  most. Probe, demo and owned-fixture modes are untouched. Coverage is
  controller scenarios through the exported C ABI
  (`crates/desktop/tests/effects_flow.rs`, against `driftwm-core`'s own parse
  and `effective_blur`), two throwaway offscreen tools outside the repository
  and one scripted launch of the built app on 2026-10-10 (macOS 27.2, Apple
  Silicon, `--windowed`, a private scene, config and socket, three seeded
  placeholders, about 3 seconds), none of which left saved evidence. Seen, in
  frames read back from the app's renderer linked with this controller's
  library and driven through the C ABI with real config files (PNGs opened,
  pixels read): the error bar with the text of an unknown-action warning, of
  three warnings as the first and ` (+2 more)`, of a TOML parse error run into
  one line, and of a config warning followed by a missing shader's message,
  and its absence after a clean reload; the changed `[effects]` values in the
  frame; a controller-placed window opening only from its first picture and
  frosted at opacity 0.6 over a stand-in; its close as a snapshot fading over
  0.71 s at `animation_speed = 0.1`; a close into a stand-in fading in place;
  a relaunched window's adoption crossfade from its first picture; a
  dismissed stand-in shrinking and fading, and nothing played for one the
  output did not show; no pixel buffer retained after a close or a reset.
  Seen with hand-written snapshots only: two outputs, the bake densities, the
  closing order, a pinned snapshot, `animation_speed = 1`. Seen in the app,
  over `msg` and on stderr only: upstream's wording of both config errors,
  viewport captures byte-identical with and without an error and with
  `[decorations] blur` on, two stand-ins dismissed with the app still
  answering, exit status 0 on SIGTERM with the socket removed, and a saved
  scene holding nothing of the effects. Evidence boundary: no run had Screen
  Recording access and nobody looked at the app's panel, so the bar, a frost,
  a fade and an opening window were never seen on a display, and no
  ScreenCaptureKit buffer was ever blurred, opened or closed: every picture
  was a plain-coloured synthetic buffer or a stand-in. `msg` reaches none of
  the three new keys, so in the app they are known only by their effects. The
  frame timer was imitated by a loop at about 25 ms a tick; timing at a
  display's refresh is unmeasured. No pixel was compared with a pixel from
  DriftWM itself. Known mismatches: upstream's keyboard error source does not
  exist (macOS owns the layouts); `animation_speed` reaches no move, resize,
  fit or fullscreen animation, which do not exist here; a window that takes
  its own waiting slot back is not crossfaded; a config file that is refused
  rebuilds the background program once where upstream redraws the bar only;
  each output bakes its own closing snapshot where upstream shares one, and
  upstream's one-second age limit on a closing window's pixels has no
  separate test; a new window is invisible for up to a second and takes
  clicks meanwhile; a background that fell back is shown in the status line
  as well as in the bar; captures
  hold no closing snapshot or error bar, which was not checked against
  upstream's capture code (only that it omits blur). All of the above was
  built on per-window policy and rendering alone. Merged with pointer policy
  and window sizing, the joins are these. There is one frame timer, and a
  window that opens or leaves keeps it alive exactly as an animated
  background does: it is started without the camera-motion flag, so each of
  its frames carries the waiting hover and cursor edge pan's pointer report,
  ticks no camera and leaves the hot corners to the idle poll, and it ends
  itself with the last animation. A window that opens while a rule's `size`
  is being asked of it (the experimental flag) has no settled picture until
  that size transaction ends, so its opening, and a stand-in fade waiting
  with it, is held until the last of the transaction's effects is answered,
  which the renderer reads from the snapshot's `native_resize`, and for ten
  seconds at most; the milestone's renderer alone would have opened it on a
  picture of the size it was leaving, or after one second on an empty frame.
  `window_closed` for a window whose size is owed is refused and logs
  nothing, and the report accepted once the transaction has drained logs its
  close once. A refused reload answers with `focus_follows_mouse` beside the
  message that spends a render revision. The sizing state and the event log
  sit together in the controller, neither saved; the log, the error message
  and the capability survive a scene `load`. `decoration.blur` and
  `lifecycle_events` sit beside `mode`, `pick` and the policy keys. One
  addition was made with the merge: `forget`, the shell's ⌃⌥-click on a
  placeholder, now logs `standin_dismiss` for what is drawn as a stand-in, so
  that dismissal fades like the others; a bound window it removes logs
  nothing. Coverage of the joins: `effects_flow` gained the `forget` cases
  and a scenario for a size that is owed, the test playing the native side
  (one `open` at the map; `native_resize` naming the window with its pending
  effect through the baseline read and the setter; the refused close leaving
  the whole snapshot unchanged; one `close` after the adapter's
  `missing_window`; a delivered size logging nothing more), and the whole
  reply of a refused reload; the `forget` rule was broken two ways and the
  scenario failed each time. A throwaway offscreen tool outside the
  repository linked the merged `canvas-renderer.m`, the compositor and the
  background module, fed them hand-written snapshots and asked
  `-animates:draw:` whether an open had begun: with a size owed, not on a
  picture delivered during the baseline read, not 1.3 s on, not when the
  transaction had just ended without a settled picture, and then on the
  first settled picture, or at the next description that had one; with no
  size transaction, on the first picture or after a second, as before; after
  a transaction that left no picture, one second later; with an effect never
  answered, after ten seconds and one more. Built against the milestone's own
  renderer the same tool reported the open begun on the baseline-read picture
  and at one second on nothing. The tool drew no frame: it shows when the
  frame description says an animation runs, not a pixel. The merged app was
  launched once on 2026-10-10 (macOS 27.2, Apple Silicon, `--windowed
  1100x700`, a private scene, config and socket, three seeded placeholders, 6
  seconds, no Screen Recording access, nothing saved). `center-nearest
  right`, `pan-viewport right` and `zoom-to-fit` and back landed at `1950
  -0`, `2050 -0`, `750 -390` at 0.28484848484848485 and `2050 -0`;
  `zoom-to-fit-snapped` answered `ok` and framed the focused placeholder at
  `1950 -0`, zoom 0.7933333333333333, and back; the five sizing actions and
  `msg resize` answered their refusals without the flag. An unknown action in
  `[keybindings]` and `reload-config`: `config: invalid action
  'no-such-action': unknown action: no-such-action` on stderr, twice, and
  `state` still answered; a file with `[effects] blur_radius = 4`,
  `animation_speed = 0.25` and `[decorations] blur = true` reloaded with
  nothing more on stderr. Three viewport captures, before the error, with it
  and with blur on, were the same bytes, and the picture, looked at, is the
  focused stand-in on the dot grid with no bar and no frost. `focus --id 2`
  and `close-window` left two windows and no focus; a capture taken at once
  and one a second later were the same bytes, the dot grid alone. Exit status
  0 on SIGTERM, the socket removed, a saved scene of two windows holding
  nothing of the effects. That adds nothing to the evidence boundary: no live
  window existed, so nothing opened or closed in the app, no rule or size
  transaction ran there and the held opening exists only in the tool's
  hand-written snapshots; nobody looked at the panel, so the dismissal's fade
  is known only to have left the app answering; no pointer event was sent, so
  the ⌃⌥-click's fade, a hover on a frame that only an animation keeps alive
  and the timer stopping after one are compiled and read, not run; the app
  was not launched with `--experimental-native-resize` for this merge.
  Further mismatches from the join: an opening window waits for the size it
  is owed, ten seconds at most, and then opens as it is, where upstream has
  no such wait because a window's first sized commit already has its rule's
  size; a window whose picture is withheld when it closes (its size still
  owed, or left unsettled by the last resize) fades from nothing; a `forget`
  fades a placeholder but moves the focus by none of upstream's rules. See the
  [effects contract](../../crates/desktop/EFFECTS.md), the
  [desktop shell notes](../../native/desktop/README.md#blur-window-animations-and-the-error-bar)
  and the [compositor notes](../../native/desktop/COMPOSITOR-NOTES.md),
  Part II.
- `b11ca68`, pass-through and the pinned drag: the rest
  of upstream's per-window rules, merged with the pointer policy, window
  sizing and effects above. `pass_keys`: the controller reports in every
  snapshot what the window that holds the keyboard passes (`null`, `true` or
  a list of combos, resolved against the config and the title of the moment
  as upstream's `live_rule_for` does, `null` for a stand-in as upstream skips
  a suspended window), and marks each key binding `passable`; the shell
  compares it at every redraw, which every applied reply ends in, a hover's
  that moved the focus and a pointer command's included, and, when it
  changed, unregisters the Carbon hot keys of the passed, passable bindings
  so that macOS delivers the chord to the frontmost application, registering
  them again when the focus leaves. Nothing is posted or injected, and
  nothing polls. A window focused by hover (`focus_follows_mouse`) passes
  once its request is answered or its echo arrives, and the window the
  pointer left stops passing with the hover itself. `pass_mouse`: the shell
  names the window under the pointer, and whether it is a pick target, in its
  binding lookup for a press, a scroll and a wheel notch, and a binding that
  window's rule claims (upstream's `pass_mouse_claims` through
  `PassList::allows`, asked only once a binding matched and only in the
  window context) answers `passed`, which the shell treats as unbound: the
  press or scroll goes to the application by the existing forward path. Below
  `[zoom] interact_min` upstream's gate applies: a canvas window, a pick
  target there, claims nothing, and a screen-pinned window keeps its button
  claims and loses its scroll and notch claims. Wheel notches: for each event
  of a discrete wheel the shell now asks `wheel_up` or `wheel_down` first,
  where upstream's notch site sits, runs an action binding once per line (ten
  at most) and consumes the event, and otherwise, a passed notch included,
  goes on to the continuous lookup. The move binding pressed on a
  screen-pinned window drags it in screen space as upstream's
  `MoveGrab::new_pinned` and `apply_pinned_move` do: by the pointer's screen
  displacement whatever the zoom, pick mode included, the frame unclamped,
  without snapping, cluster or edge pan, the pointer's output taking the pin;
  a pointer on no output (the shell's is not confined, and its outputs leave
  out the toolbar strip) is held at the edge of the output the drag is on, as
  upstream's cursor is, so the frame can leave its output in part and never
  wholly. The trackpad move gesture over a pinned window installs the same
  drag and raises and focuses the window, as upstream's
  `try_start_gesture_move` does for `GestureTarget::Pinned`; the state
  `swipe_pinned` is gone. `layer_order` is read, shown with the window's rule
  and listed in `rule.not_applied`: upstream applies it to layer-shell
  surfaces only and documents it as ignored for regular windows, so the port
  ignores it as upstream does (an earlier build of this milestone ranked
  windows by it; that was reverted in the merge). Evidence boundary:
  `pass_keys`, `pass_mouse`, the notch lookup and the pinned drag by press
  and by gesture ran only as controller scenarios through the exported C ABI
  (`crates/desktop/tests/passthrough_flow.rs`, 19, with `rules_flow` 22,
  `pointer_flow` 16, `sizes_flow` 30 and the neighbouring modules), with
  synthetic observations. No key was pressed, no hot key was seen being
  unregistered or registered again, no real window received a passed key,
  press or scroll, no wheel was turned, and no pointer or swipe dragged a
  pinned window; the shell's hot key code, its notch site and its hooks were
  compiled and read only. Two launches of the merged build
  (`--windowed`, private scene, config and socket, no Screen Recording
  access, placeholders only, each under 30 seconds) observed a config
  carrying `pass_keys = true`, `pass_mouse = ["alt+left"]` and
  `layer_order = 2` in one rule and `"mod+wheel-up" = "zoom-in"` in
  `[mouse.anywhere]` loading and reloading without a warning, upstream's
  `invalid key combo` and `invalid mouse combo` warnings for combos the
  grammar lacks, a pin that the merged controller had dragged in process
  listed under `State.pinned` at the dragged place before and after a pan,
  the earlier milestones' navigation, pan, `zoom-to-fit` and
  `zoom-to-fit-snapped` answering as before, a viewport and a window
  screenshot, and a clean exit; a windowed run registers no hot keys, no
  placeholder has a rule, and `msg` has no verb for a press, a scroll, a
  notch, a hover or a gesture, so the launches reached none of the new
  behaviour, and a throwaway program reading the same scene and config
  through the controller in process found `pass_keys` null, no lookup
  passed and the `mod+wheel-up` notch answered as an action, as the rules
  for a window without a client and for a bound notch say.
  Known mismatches: `pass_keys`
  follows the window whose native focus is settled, not the logical focus
  alone, and is decided per focus change where upstream decides per key
  press, so nothing is passed while a request for another window is in
  flight, failed or unanswered; the exit chord and `quit` are never passed,
  in the place of upstream's VT switch, where upstream passes its `quit`
  binding; a pass list matches a binding by its combo text, so of two
  upstream combos on one physical chord only the one holding the chord
  passes; with `--no-native-focus` or without Accessibility the released
  chords go to whatever application is in front; a widget that is not pinned
  keeps its `pass_mouse` claims below `interact_min`, where upstream's code
  drops them, because the lookup is not told the pointer's output; a wheel
  line counts as a notch, with no accumulator for a high-resolution wheel;
  under Shift, where AppKit hands a wheel's vertical lines over as horizontal
  ones, the notch is read back from the horizontal axis, so a sideways wheel
  turned under Shift counts as a notch too, and the continuous lookup is left
  with the horizontal lines (a shift-qualified wheel zoom does nothing, a pan
  goes sideways), read off events built in memory and not off a wheel; a
  pinned window is still not resized and a gesture does not carry one to
  another output; a pinned
  drag's pointer off every output is held in the controller's arithmetic
  only, the macOS cursor itself going on, so it has to come back to the
  output's edge before the frame leaves that edge again, where upstream's
  held cursor moves it at once; media keys are not registered at all.
  See the [rules contract](../../crates/desktop/RULES.md#pass-rules) and the
  [desktop shell notes](../../native/desktop/README.md#passing-keys-and-presses-to-an-application).
- `2d409fc`, upstream behaviour gaps: nine places where
  the milestones above recorded a difference from upstream although
  upstream's behaviour can be had here, each followed from upstream's code at
  the pinned commit. (1) A press bound to `move-window`,
  `move-snapped-windows`, `resize-window` or `resize-window-snapped` raises
  and focuses the window under the pointer before its grab, as the move and
  resize arms of upstream's `on_pointer_button` and its `try_pinned_button`
  do, for a canvas window and a screen-pinned one alike: `begin_drag` and
  `begin_resize` do it themselves and answer `{"effect": <focus request or
  null>}`, `begin_native_resize` carries the request as the one entry of
  `effects` beside its transaction's `effect`, and the shell hands either to
  the navigation coordinator like a click's; a resize press that can begin
  nothing (the gate off, which was so at that commit and is no more since a
  resize press begins a resize in every normal run; a pinned window; a begin
  the resize path or the controller turns away) is raised and focused by the existing `focus`
  command. A widget keeps its refusal. (2) IPC `Resize`
  raises its window as upstream's `cmd_resize` does and hands it no focus;
  a request identical to the one last asked raises nothing, as upstream's
  `resize_element_to` returns before its map.
  (3) A problem in the config file is shown once, in the error bar; the
  shell's status line no longer repeats it and keeps only its own notes;
  every message still goes to stderr. (4) The bar's one line for several
  warnings is the first of them in byte order, then upstream's ` (+N more)`,
  so a file that did not change has one message at every load and spends no
  render revision for a reordering; the `load_config` reply keeps the
  parser's order and the shell prints the warnings sorted. (5) `hit`,
  `input`, `hover` and the pick press below `[zoom] interact_min` were read
  against upstream's `pointer_focus_under_pick`, its focus cascade,
  `pick_target_under` and `try_pick_button`, and needed no change: a pinned
  window is found ahead of the pick guard, a widget after it, and a canvas
  window over a widget ends the cascade; scenarios now pin the widget under a
  canvas window and the pinned widget. (6) A fit and a fill measure their
  window by the size it was last asked for, upstream's
  `configured_window_size`, where the port read the committed frame. (7)
  Ruled windows that map together are each asked for their rule's `size`,
  one at a time in map order: the next is asked in the `native_resize_result`
  reply that ends the transaction before it, or in the `attach` reply of the
  next new window, and the shell takes the transaction such a result reply
  names for a sizing one; a waiting window the user sizes first (IPC
  `Resize`, a step, a fit, a fill, a resize drag) leaves the queue unasked,
  as upstream's one-shot `pending_size` never forces a rule's size over a
  later one. (8) With the capability on a new window is placed
  for the size its rule names, as upstream configures the size first and
  places for it, a widget and a rule-pinned window included, and lands on
  that frame to the pixel when it takes the size; the cascade and the `auto`
  placement of a later arrival read the frame a ruled window is becoming,
  asked or still waiting its turn, so several windows of one rule that map
  together cascade as upstream's do. (9) `msg camera` can print
  `-0`: upstream's `viewport_center` negates a zero and its client prints the
  pair as it is, so nothing is normalised. No command and no reply shape
  changed but for the added keys named in (1). Evidence boundary: all nine
  ran only as controller scenarios through the exported C ABI and JSON
  (`pointer_flow` 16, `sizes_flow` 31, `rules_flow` 26, `effects_flow` 5,
  `passthrough_flow` 19, `ipc_flow` 8, `lifecycle_flow` 25, `controller_flow`
  4 and the neighbouring modules, 186 scenarios), the test answering every
  focus request and resize effect itself. The shell's side (the focus of a
  bound press, the status line, the sorted stderr lines, the adoption of a
  waiting window's transaction) was built and read. The built app was
  launched three times on 2026-10-10 (`--windowed`, private scene, config
  and socket, no Screen Recording access, three placeholders, 5, 6 and 3
  seconds, exit 0 on SIGTERM with the socket removed) and driven through
  `msg` only: `camera` read `550 -318`, then `1950 -0`, `2050 -0` and `0 -0`
  after `center-nearest right`, `pan-viewport right` and `home-toggle`;
  `resize --id 1 800 500` without the flag answered `resize is not
  implemented on macOS yet: native layout resize is not available`; a
  viewport screenshot showed the dot grid and the corner of one placeholder;
  and a config with two unknown actions printed its two warnings on stderr
  at every load, in an order that changed between loads in the first run
  (built before the shell sorted them) and in one order at all seventeen
  loads of the two runs after. A fourth launch after the review of this
  milestone (6 seconds, the same private paths, exit 0 on SIGTERM with the
  socket removed) answered the same: `camera` `550 -318`, `1950 -0`,
  `-620 -890` after `focus --id 3` and `0 -0` after `home-toggle`, the two
  warnings in one order at all four loads, the same resize refusal and the
  same screenshot. No button was pressed, nothing was dragged,
  no window had a live source, no size was asked and nothing was looked at
  on a display: the error bar, the status line and every focus are unseen,
  and the bar's text is not readable over the socket. The headless
  navigation coordinator regression was not rerun (the coordinator did not
  change) and no fixture or probe mode was run. Known mismatches: a press
  dropped while a size is owed and a move begin that is refused focus
  nothing, where upstream has no such
  refusal and has already raised and focused the window; the pick-mode drag
  asks for the focus twice (the press's `activate`, then `begin_drag`),
  where upstream focuses once; the bar can name another warning than
  upstream's for a table the parser reads in a fixed order; IPC `Move` still
  does not raise; a resize drag ends the size last asked for, where upstream
  goes on reading the drag's last configure; a ruled window that takes
  another size than its rule names keeps the top-left of the frame asked
  for, where upstream places the size it got, and stands on the canvas at
  its own size until it answers; ruled windows are asked in turn, not at
  once, a waiting one is not marked in the snapshot so its opening is not
  held for the size until its turn, and one that waited out a drag, or
  whose turn came under a gesture or as a transaction was retired, is asked
  with the next new window or at the next transaction's end; in probe, demo
  and owned-fixture runs `begin_drag` and `begin_native_resize` now also
  raise and logically focus the window and leave a focus request those runs
  never answer, which no fixture run has looked at. See the
  [desktop shell notes](../../native/desktop/README.md#upstream-behaviour-gaps-closed)
  and the [pointer](../../crates/desktop/POINTER.md),
  [sizes](../../crates/desktop/SIZES.md), [rules](../../crates/desktop/RULES.md),
  [effects](../../crates/desktop/EFFECTS.md) and
  [navigation](../../crates/desktop/NAVIGATION.md#activate) contracts.
- `ed34eec`, fullscreen, makes DriftWM's fullscreen
  controller policy (`crates/desktop/src/fullscreen.rs`, adapted from
  upstream's `src/state/fullscreen.rs`, the fullscreen arms of
  `src/input/actions.rs` and the fullscreen lines of its navigation, output,
  pointer, gesture, IPC and map paths, with driftwm-core's own
  `Action::runs_during_fullscreen` and `place_auto`): `toggle-fullscreen`,
  the window rule `fullscreen = true` with its `output`, the per-output
  fullscreen state with the saved place, size, camera, zoom and pin that the
  exit restores, the parked camera, centring of a window that took another
  size, what ends a fullscreen (upstream's action guard, so `exec` but not
  `spawn`; bound pans, zooms and grabs; IPC camera, zoom and suspend, and not
  IPC close; the activation of another window, a new one that macOS made key
  among them; the window closing; another ruled window taking the output;
  output removal), the background placement of a new window, `home-toggle`'s return into fullscreen and `send-to-output`'s
  fullscreen leg, the translucent rule, `disable_when_fullscreen` for hot
  corners, hover's re-assertion of the fullscreen window's focus, and
  fullscreen in the snapshot (`outputs[].fullscreen`, the `fullscreen` mode,
  one placement marked `fullscreen` in output screen space with a bare
  decoration) and in IPC `State`. The shell's renderer draws that placement
  as the compositor's fullscreen element (bare, at its screen rectangle at
  zoom 1, over black or, for the translucent rule, over the canvas
  background and the outlines), draws no resize handle on it and suppresses
  its output's hot corners. This is not macOS native fullscreen, which is
  never used. A fullscreen window is resized to its output, and that goes
  through the same size transaction as the sizing milestone above, so the
  whole feature sits behind the same gate: without
  `native_resize_capability`, which the shell then sent only when started with
  `--experimental-native-resize` and since 2026-10-11 sends in every normal
  run, `toggle-fullscreen` and a rule's
  `fullscreen` answer and report byte for byte as before, no output is ever
  fullscreen, and no switch was added. Evidence boundary: **no native window
  was resized or presented fullscreen.** Fullscreen ran only in controller
  scenarios through the exported C ABI
  (`crates/desktop/tests/fullscreen_flow.rs`, 15 scenarios on two outputs,
  neither at the global origin), in which the test plays the native side and
  answers each resize effect with a made-up result, with the capability-off
  replies compared against literals captured from the tree before this work
  and upstream not executed as an oracle. The renderer's part was read back
  offscreen by a throwaway program outside the repository, on hand-written
  snapshots in the contract's shape, before the controller side existed. Built
  together on 2026-10-10 (macOS 27.2, Apple Silicon), reading the two sides
  against each other found that the controller counted on `hover` replies to
  carry the size an exit still owed while the shell performs none from a
  hover reply, which would have stranded a window at its output's size;
  `hover` no longer carries one, and two replies the shell dropped (the
  bookmark question before `go-to-bookmark`, the cancelled `gesture_end`
  after a refused update) now reach its size hook. The test modules of every
  touched source file then passed (229 scenarios in 17 modules), as did the
  headless navigation coordinator script; asked with upstream's built-in
  defaults by a throwaway program outside the repository, the controller's
  `bindings` reply lists 45 key bindings of which 42 run without the
  capability and all 45 with it, and of the 35 action names of upstream's
  grammar it refuses six by name without the capability and none with it;
  and the app was driven twice over a
  private socket on a private scene of three detached placeholders, with no
  Screen Recording access: without the flag `toggle-fullscreen` answered its
  previous refusal and `state` printed `fullscreen 0`; with it
  `toggle-fullscreen` answered `ok` on a focused placeholder and changed
  nothing (there is no refusal for a stand-in: upstream's arm does nothing
  without a client), `state` still printed `fullscreen 0`, and a viewport
  screenshot rendered and was looked at. That is as far as the socket
  reached: no live window existed, so no fullscreen was entered and no size
  transaction ran in the app, and the shell's reply paths for one, the
  drawing of a controller-reported fullscreen placement, every key, mouse
  binding, gesture and hot corner that toggles fullscreen, a rule's
  `fullscreen` on a real window and every way out are compiled and read only;
  nothing was saved as evidence. Known mismatches: no enter or exit
  transition, and a grey placeholder while a size is unresolved; the answer
  to an offered size is a native result, not a configure ack; a size is
  written only when a native observation commits it, so a window that has
  left fullscreen keeps its output's size until its transaction answers, and
  after an exit made by a pan, a zoom, a pointer drag, an output change or a
  displaced incumbent that transaction begins only with the next action, IPC
  request, gesture or click; a restore whose transaction ended before the
  window was asked is begun again, three times at most, and one the
  application refused is not; a new window that takes the keyboard as it
  opens ends the fullscreen, where upstream keeps a background-placed window
  unfocused; a resize drag out of fullscreen starts from the output's size; one transaction, so an
  enter is refused while another size is owed; output removal is settled when
  the shell has said which outputs exist, not at removal; a rule's
  `fullscreen` is not applied to windows already open at launch, to a window
  attached by hand or to an adopted slot; on the band beside a smaller
  fullscreen window only the fullscreen window is hit and a mouse binding is
  resolved in the canvas context; no pointer warp, no carried pointer lock
  and no client fullscreen request; the older `cycle_focus` command does not
  pass over a fullscreen window; a capture draws the canvas rather than the
  fullscreen output; and a window still fullscreen at Quit or Return to
  desktop is handed its size back by the shell before the scene is saved
  (compiled, and run only with nothing fullscreen), while one whose shutdown
  is cut off keeps its output's size and is saved at its old place with that
  size, where upstream saves the frame from before. All of the above was
  built on the window sizing milestone. Merged with the three milestones
  above (effects, pass-through and the pinned drag, upstream behaviour
  gaps), fullscreen meets each of them in upstream's way. Effects: a
  fullscreen window is frosted by its own rule's `blur` alone
  (`effective_blur`'s `is_fullscreen`, in the one function that answers
  `decoration.blur`); a window that maps straight into fullscreen logs its
  `open` and one that closes fullscreen its `close`; the shell's renderer
  applies its one fullscreen function to the frame the effects build, draws
  the error bar on a fullscreen display as on any other (upstream builds it
  for every output, and the compositor notes say the same), leaves closing
  snapshots and stand-in fades out of a fullscreen display's frame
  (upstream: "no dying-window flash over a fullscreen app"), bakes a
  fullscreen window's own snapshot bare, and does not hold the opening of a
  window that is fullscreen for the size it is owed. Pass-through: the
  fullscreen window claims by `pass_mouse` at the button, scroll and notch
  sites with no pick gate (upstream `fullscreen_claims`), passes its
  `pass_keys` while it holds the keyboard, and a wheel notch's action runs
  through the action guard; a pinned drag is frozen while the pointer is
  over a fullscreen output (upstream's move grab), no drag of a window
  pinned to a fullscreen output is installed from elsewhere, and no output
  becomes fullscreen under a drag. The closed gaps: a grab on a fullscreen
  output ends the fullscreen, then raises and focuses the window, then takes
  hold, upstream's order for a press bound to move or resize, and a refused
  grab undoes all three; a rule that names both `size` and `fullscreen`
  places the window for the size, as upstream configures it first, and the
  fullscreen then owes that size for its exit instead of asking it, so the
  window waits in no queue, while a ruled window that maps during a
  fullscreen's transaction waits its turn behind it and is placed in the
  background against the frames the waiting ones are becoming; a window
  owed its size by an exit is measured by that size, not by the output's
  the enter last asked, so a fit or fill out of fullscreen lands where a
  plain one does, and a filled window comes back at the size its fill asked
  for; IPC `resize` refuses a fullscreen window in upstream's words before
  it raises anything; a widget or a screen-pinned window is sized by two
  requests only, its rule's `size` as it maps and a fullscreen exit's
  restore, and the size transaction refuses every other. Five scenarios
  added to `fullscreen_flow` (20 now) and one case in its fit scenario cover
  those joins, the test again playing the native side; the one that pins the
  configured size was seen to fail with the fix taken out. The
  capability-off literals were captured again, from the tree before this
  merge built apart: every reply was byte for byte the one recorded but a
  key binding's `bindings` entry, which pass-through had given `passable`,
  and the sizing literals of `sizes_flow` did not change. Asked with
  upstream's built-in defaults, the merged controller's `bindings` reply
  lists 45 key bindings of which 42 run without the capability, leaving
  `toggle-fullscreen`, `fit-window` and `fit-window-snapped`, and all 45
  with it; of the 35 action names of upstream's grammar it refuses six by
  name without the capability (those three, `grow-window`, `shrink-window`,
  `fill-window`) and none with it. Nineteen controller test modules passed
  (263 scenarios), as did the headless navigation coordinator script. The
  merged app was launched twice on 2026-10-10 on three detached
  placeholders (private scene, config and socket, no Screen Recording
  access, nothing saved): without the flag `center-nearest right` settled
  on the Browser placeholder at camera `1950 -0`, `pan-viewport right`
  moved it to `2050 -0`, `zoom-to-fit` framed all three at zoom
  `0.28484848484848485` and came back, `toggle-fullscreen` answered its
  refusal unchanged, `state` printed `fullscreen 0` and a viewport
  screenshot was written and looked at; with the flag `toggle-fullscreen`
  answered `ok` on a focused placeholder and changed nothing, as before the
  merge, and the app exited with status 0 on SIGTERM with its socket
  removed, through the shutdown path that ends fullscreens, with nothing
  fullscreen. That adds nothing to the evidence boundary: no live window
  existed in either launch, so no fullscreen was entered, no size
  transaction ran in the app, nothing was drawn fullscreen, no window had a
  rule, a pin or a picture, and no pointer event was sent; the joins ran
  only as controller scenarios, and the shell's side of them is compiled
  and read. Further mismatches from the join: a rule's `size` beside its
  `fullscreen` is owed, not asked first, where upstream configures the
  client twice; and in the band beside a smaller fullscreen window nobody
  claims by `pass_mouse`, where upstream still asks the fullscreen window.
  The shell ends every fullscreen once before it shuts down, at Quit, on
  SIGTERM and at Return to desktop; a screen change is no shutdown, and
  there a fullscreen whose output is still connected is kept and one whose
  output went is ended by the controller, as upstream does both. The
  feature stayed behind `--experimental-native-resize` until 2026-10-11, and
  runs in every normal run since. See the
  [fullscreen contract](../../crates/desktop/FULLSCREEN.md) and the
  [desktop shell notes](../../native/desktop/README.md#fullscreen).
- `72be7ea`, tap bindings, closes one gap of a default launch, with no flag.
  A `[keybindings]` entry that is a bare modifier chord
  (`"alt+shift" = "switch-layout next"`) is no longer skipped: the `bindings`
  reply lists it under `taps` with the macOS chord a key binding's modifiers
  map to, and a new `tap {modifiers, output}` command runs the bound action
  through the one action prelude and refuses a chord nothing is bound to. No
  window's `pass_keys` takes a tap: upstream decides a tap on a key release,
  ahead of that test, which asks presses only. The tracker is the shell's
  (`tap-keys.m`), upstream's `TapTracker` over `flagsChanged` from one
  NSEvent global and one local monitor, set up and torn down with the hot
  keys: the peak chord, tainted by anything else on top, fired once on the
  first release, and not again until every modifier is up. It holds no timer,
  and neither the display-link frame timer nor the lost-input check calls it.
  A key or a button on top is not listened for; the login session's event
  counters (keys, mouse buttons, and the system-defined events a volume,
  brightness or media key arrives as) are compared at the chord's start and
  at its release, the session's own last-seen times are asked at the start
  for what landed before the shell heard of the chord, and a hot key that
  fired, a scroll and a gesture that begins taint directly. **The usable area
  was built with it, and the shell sends none.** Upstream measures an output
  less the exclusive zones of its layer-shell panels (`usable_area_on`); on a
  Mac the counterpart would be what the menu bar and the Dock leave of a
  display. The controller's side landed and is kept: `register_output` takes
  an optional `usable_rect_local`, a new
  `set_usable_area {output, usable_rect_local}` replaces it in place, a
  change moves nothing and saves nothing, as upstream arranges its layers
  again and owes the output a frame and no more (`handle_layer_commit`,
  `layer_destroyed`), and a screen-pinned window's clamp and fullscreen still
  measure the whole output, as upstream's `clamp_pin_frame` and fullscreen
  do. The shell's side, a file that read `NSScreen.visibleFrame` and sent it,
  was removed before landing by the owner's decision of 2026-10-10: the
  canvas covers each display edge to edge with nothing reserved for the menu
  bar or the Dock, windows may sit beneath them, and both stay visible on
  top. So no output is registered with a rectangle and `set_usable_area` is
  never sent, every output is usable whole, the renderer's `DrawnChrome`
  coverage rule tests the whole output as it did, and the controller's
  rectangle is inert. That is a deliberate difference from upstream, not a
  gap that waits for work. The wire contract only grew (`usable_rect_local`,
  `set_usable_area`, `taps`, `tap` with the optional `pointer` and `held` an
  `action` takes); the ABI version is unchanged. Evidence boundary:
  `crates/desktop/tests/usable_tap_flow.rs` (15 scenarios through the
  exported C ABI, on two outputs off the origin, one with what a Dock on the
  left and a menu bar on top would leave of it, expected values derived by
  hand from upstream's rules, upstream not executed as an oracle) and eleven
  more controller test modules (175 scenarios) passed on 2026-10-10 on the
  tree that landed (macOS 27.2, Apple Silicon). The app was launched twice,
  windowed, on three detached placeholders with a private scene, config and
  socket and no privacy grant: once from the tree the milestone was built
  in, and once from the tree that landed, with the display-link frame timer
  and the lost-input check beside the tracker and no usable-area file. In
  both a config holding the `alt+shift` tap loaded with no warning on stderr
  and `reload-config` was acknowledged; `center-nearest right` settled on
  camera `1950 -0` and `zoom-to-fit` on zoom `0.28484848484848485`, the
  numbers recorded for earlier builds; a viewport screenshot was written and
  looked at; and SIGTERM ended it with status 0 and its socket removed. In
  the first, the config rewritten with two taps that land on one chord
  brought the controller's collision warning to stderr, so the tap table is
  reached in the app. That is all a windowed launch reaches: it installs no
  monitor, and no key was tapped in either. The tracker and the controller
  also met once outside the app, in a throwaway program outside the
  repository that linked the release controller library with `tap-keys.m`
  and installed no monitor: `bindings.taps` fed to the tracker with modifier
  events built in memory produced one `tap`, answered with the
  `switch_layout` effect, and none for an unbound or a tainted chord. (With
  the shell file since removed, the same program registered the display's
  output with a rectangle and had a hand-made one, 80 points shorter, taken
  by `set_usable_area`, which moved the point `set-bookmark` stored to its
  centre: the controller's side answering, and nothing the app does.) The
  tracker alone, fed the same way, fired for a chord handed to it five
  seconds late with nothing seen by the session since, and not for one that
  began before the session's last key or button event. No normal run was
  made, so the app has sent no `tap`; no modifier and no media key was
  pressed for any of it and no monitor has delivered an event: that a media
  key moves the system-defined count is read from Apple's headers, and that
  a modifier does not from the session's counts, watched through seven
  minutes of the owner's own work (244 reads in which a modifier alone had
  changed, the system-defined count still in every one); no real event's
  timestamp was set beside `systemUptime`, and if one ever reads older than
  it is no tap fires. Whether macOS sends modifier changes to a process
  without Accessibility trust is not known here: Apple's documentation gates
  key-related events on it and names no exception, and if it holds a tap
  fires only while Infinify is the active application, with nothing said.
  Known mismatches of the tracker: two keys of one modifier count as one, so
  such a chord fires on the last release and not the first; a key held from
  before the chord until after it is not seen; a scroll or gesture that
  reaches no canvas panel does not cancel a tap; a key or button that lands
  after the release, before the shell hears of it, does; whatever else macOS
  sends as a system-defined event cancels a tap as a media key does, so
  Sticky Keys and Slow Keys, which announce a key with one, are expected to
  stop every tap (not observed); nothing resets the tracker at the lock
  screen; and upstream's warning that the tap never fires beside
  `grp:alt_shift_toggle` is reported unchanged although XKB options are not
  applied on a Mac. Inventory: `config.keybindings.alt+shift` became
  `implemented_unverified`; `protocol.layer_shell` stays `missing`, its note
  now saying that nothing is reserved for the menu bar and the Dock by the
  owner's decision, a deliberate difference and not a gap awaiting work, and
  that panel and overlay policy is still missing; and the 21 rows whose
  notes say the app registers no usable area keep that clause, which is
  still true. See the
  [navigation contract](../../crates/desktop/NAVIGATION.md#the-usable-area),
  the [configuration contract](../../crates/desktop/CONFIG.md#tap-bindings)
  and the
  [desktop shell notes](../../native/desktop/README.md#what-has-been-run-for-tap-bindings).
- `a47217e`, the background caches: the two things the Metal background
  port had left out, both in a default launch.
  `[background] cache_shader = true` bakes a static shader into canvas-space
  chunk textures and pans those: upstream's rule for which shader qualifies
  (it declares `u_camera` and neither `u_time` nor `u_zoom`, has no `texture`
  and is not under `transparent_shader`), its 1024-unit chunks over eight
  levels with a one-texel apron, the resident coarse cover, two bakes a frame
  and sixteen when the level changes, and least-recently-shown eviction. A
  `type = "tile"` path ending in `.tif` or `.tiff` is upstream's gigapixel
  wallpaper: a tiled pyramidal TIFF drawn from its levels chunk by chunk, with
  upstream's level choice by zoom, chunk aggregation, six decodes at a time
  off the main thread, eight uploads a frame and the always-loaded fallback
  level under the chunks still loading; a file upstream refuses falls back to
  the dot grid with upstream's text on stderr and the error bar.
  `cache_budget_mb` bounds each output's cache of either kind, and the
  controller now reports it as `render.background.cache_budget_mb`. A chunk
  that becomes ready redraws its own output and nothing is drawn while
  nothing is pending. While a cache fills, its output is given one frame per
  tick of the frame timer, the display link at the display's refresh rate,
  and upstream's allowances are spent once a frame, unscaled, as upstream
  spends them per frame of its output. A blurred window over either cache
  has its frost
  recomputed in the frame a chunk lands, as upstream's blur refreshes when
  the background's elements change: review found the frost left a blur of
  the coarse picture, and the fix is the one change this milestone makes to
  `compositor.m`. Four rows became `implemented_unverified` (the field
  and reference rows of `cache_shader` and `cache_budget_mb`), and the notes
  of six background rows that said the opposite were corrected.
  Known mismatches, each upstream's own unless marked: the bake is not the
  live render everywhere (equal, to one level on at most 0.056 % of pixels,
  only at zoom 1, 0.5, 0.25 … with the camera on the baked level's grid;
  shifted by under a pixel at a fractional camera; the next coarser level
  stretched between those zooms); on a 2x display the default budget of 128
  is 0.4 MB short of a view that lies across the canvas origin on both axes,
  the home view among them, which then shows the coarse cover alone, a blur,
  until `cache_budget_mb` is raised; a TIFF's level follows the zoom alone
  and its chunks have no apron; `msg screenshot` draws neither cache, a baked
  shader live and a TIFF from one level of at most 4096 pixels, which was not
  what this milestone's brief asked of it and is what
  `capture_background.rs` does. The port's own: tiles are decoded by ImageIO
  one at a time, and a tile whose compressed data is damaged is not detected
  (what upstream's decoder does with such a tile was not established);
  a coarse cover or a TIFF view that does not fit the budget is drawn live or
  from the coarser levels that fit, where upstream bakes or requests and
  evicts every frame; the bake waits on the main thread inside the frame;
  one frame timer follows the fastest display, so beside it a slower
  display's cache is offered frames at the faster rate, where upstream gives
  each output its own.
  Evidence boundary. The controller's side is one scenario in `render_flow`
  (five modules, 37 scenarios, passed). The caches' pictures were compared
  only by a throwaway harness outside the repository that links the module
  and the shell's renderer, rebuilt from the final tree: baked against live
  for five upstream shaders at ten cameras, zooms and scales (ten frame pairs
  byte-identical, the other on-grid ones one level apart on 1 to 1078
  pixels, the off-grid ones different as above); the renderer on a detached
  2x layer of the app's size (baked equal to live at zoom 1 and 0.5 away from
  the origin; at the home view 86 % of pixels different under the default
  budget and 506 pixels by one level under 256; one draw, then none in thirty
  idle ticks); a generated 16384×8192 seven-level pyramid against the same
  picture as a PNG tile (byte-identical at zoom 1 on a 1x target at three
  cameras, 0.2 % of pixels on chunk edges at 2x, different at zoom 0.5 on 2x
  where the level follows the zoom); and pans of 300 and 400 frames in which
  the chunk bytes were never above a budget of 512, 128, 32 or 8 MB. After
  the review the harness, rebuilt, drew one blurred window over each cache
  through the compositor's offscreen encode: in eight sequences (a jump of
  the view, the frame after concealed ones, a first frame) the frost was
  recomputed on the frames a chunk landed in and the settled frame was
  pixel-identical to one from a renderer with no frost yet, with no
  recompute and no difference over a live shader and a PNG tile. The app
  built from this tree was launched five times on 2026-10-10 on three
  placeholders (private scene, config and socket, no Screen Recording access;
  7 to 13 seconds, exit status 0 and the socket removed each time), and three
  more times after the review fixes (13, 8 and 8 seconds, the same exits,
  the same results). Seen
  there, in the PNGs `msg screenshot` wrote, all opened, and on the app's
  stderr: viewport captures with `cache_shader` on and off byte-identical at
  three cameras and two zooms, which shows a capture unaffected and nothing
  about the bake; a 4096×2048 pyramid byte-identical to its PNG at zoom 1,
  0.5 and 0.25; the 16384×8192 pyramid 39 % to 54 % different from its PNG,
  the capture being its 4096 level, and byte-identical to that level as a PNG
  tile at the matching scale; a stripped, a greyscale and a missing TIFF with
  upstream's three texts and captures byte-identical to the dot grid; and the
  caches' own lines for a view over the budget, carrying the budgets the
  configs named (128, 40 and 1 for the shader, 8 and 2 for the TIFF), which
  is the one sign in the app that the layer's caches ran and took the
  controller's number. All of that was on the tree the caches were built in,
  before the display-link frame timer (`a476e93`) and the tap bindings
  (`72be7ea`); they landed on the tree that has both, and one thing changed
  at that join. A tick of the frame timer that had already drawn its output,
  as every tick of a flight has, forced a second frame of a filling cache and
  so spent upstream's per-frame allowances twice; now an output that has
  drawn since the last tick is not forced again. A second throwaway program
  outside the repository, which links the landed `frame-driver.m` with the
  renderer and the module and copies `main.m`'s rule for the timer, measured
  it on a 120 Hz display: after a jump to cells never shown the timer
  started, baked two chunks a tick at 120 ticks a second and ended by itself,
  with no tick and no chunk in the idle half second after; a flight over
  fresh cells baked up to four a tick at 79 ticks a second as the two sides
  merged and two a tick at 119 to 120 after the change (94 and 111 at 2x); a
  pyramid's timer started with its decodes outstanding and ended by itself,
  and its ready handler was never called off the main thread. On the landed
  tree seven controller test modules (63 scenarios) and the headless
  navigation coordinator script passed, and the app built from it was
  launched four times on the three placeholders (2.9 to 7.4 seconds, exit
  status 0 and the socket removed each time), with dark sea baked under the
  default budget, under 1 (the live fallback's line on stderr) and under
  256, a shader path that does not exist (upstream's text and the dot grid's
  capture), an 8192×4096 pyramid (its picture in the capture) and a stripped
  file (upstream's text). `center-nearest right` settled on camera `1950 -0`
  in three of the four, and `pan-viewport right` on `2050 -0` and
  `zoom-to-fit` on zoom `0.28484848484848485` in the two that sent them from
  there. In the other one the same first command came to rest at `1661.93
  3682.86`, with every later command exact from that place; the next launch
  of the same binary, config and script did not repeat it, and nothing
  recorded says what moved the camera (a scroll reaching the panel, which is
  on the owner's display, would). That is the renderer and the frame driver
  outside the shell, and the app answering with the caches on: the shell's
  own frame block was not seen serving a filling cache, no flight was watched
  over one, and no tap was made. Not seen: either cache's picture on the
  app's panel
  (no screen capture from an agent session), eviction in the app, a real
  gigapixel file or one written by `vips` or GDAL, a second display, a
  display whose scale changes, a live window over a cached background, a
  blurred one over it anywhere but in the harness, and memory over a long
  run. See the
  [render contract](../../crates/desktop/RENDER.md) and the
  [desktop shell notes](../../native/desktop/README.md#background-caches).
- `532a67d`, event-driven window tracking: the shell is told of native
  windows instead of asking for them, the way yabai is
  (koekeishiya/yabai `dd845723416f5fe92af49fad5ebab00369e07edd`, MIT; `NOTICE`
  records what was adapted). A managed run observes `NSWorkspace` (an
  application launched, terminated, activated, hidden, shown; the active
  Space changed) and, with Accessibility access, one observer per regular
  application on the main run loop (a window created, moved, resized,
  retitled; the focused window changed) and each window that observer knows
  (destroyed, miniaturized, deminiaturized), in the new
  `native/desktop/window-events.{h,m}`. An event is only a hint to look now:
  it runs the pass or the per-window look the poll runs, for the application
  or window concerned, which reads the window list or native focus afresh,
  so a new window is offered through the unchanged rules (the Accessibility
  subrole test; still for 50 ms of wall time, where it was one poll), a
  close sends `window_closed`, a title `retitle`, a frame `observe`, and a
  focus change the coordinator's native `activate`. The poll stays: every
  80 ms as before without Accessibility access or while an application is
  not observed in full, and once a second as a reconciliation otherwise, the
  focus poll likewise at one second. Accessibility messages go off the main
  thread with a quarter-second timeout, and an application that does not
  answer is asked again, five times a tenth of a second apart and then once
  a second. No controller command changed shape. The controller already
  refused every duplicate, late and early report by its binding check, each
  command being a transaction; one rule is new: a native activation repeated
  for a window still wholly off its home output, while that output is on the
  flight the first report armed, changes nothing where it re-armed the
  flight. Seven scenarios added to `lifecycle_flow` (32 now) pin a close
  reported twice, a title and a frame for an unbound window, a native
  identity that closes and returns, native focus early, twice and late, an
  application quitting in a burst, a close and the focus that follows it in
  both orders, and a pass that ends before a window arrives. Evidence
  boundary: those scenarios, with the test playing the shell; the seven
  named controller test modules and the headless navigation coordinator
  script passing; the app built; four three-second `--windowed` launches on
  three detached placeholders (private scene, config and socket) in which
  `center-nearest right` settled at camera `1950 -0` and the app exited 0 on
  SIGTERM with its socket removed; and a throwaway observe-only program
  around the real `window-events.m` in which all 7 regular applications
  running were observed for all six notifications within half a second and
  the observers were removed cleanly (run before that file's last two
  changes, to a window lookup that is not answered and to a window watched
  twice, which are compiled and read only). The launches had no Screen Recording
  access, so no window manager and no observer existed in the app: no native
  event has reached the app, and no real window was adopted, closed,
  retitled, moved or followed through an event. All of that was on the tree
  the events were built in, before the tap bindings (`72be7ea`) and the
  background caches (`a47217e`); they land on the tree that has both. Nothing
  in the shell changed at that join: the poll keeps the lost-input check, the
  display link's fallback and the capture report beside the reconciliation,
  the Accessibility subrole test stands before the one call that offers a
  window whether an event or the poll started the pass, and the build script
  compiles each of the four new files once. Two things hold there that
  neither side had said. The tap tracker is handed Accessibility trust at
  each read of native focus, so where the observers are in place a grant
  reaches it within a second, not half of one. And a native activation
  repeated on an output whose
  usable rectangle was replaced in mid-flight arms a flight of its own to the
  new place, the first having kept its anchor: run once at the merge by a
  scenario that was not kept, and nothing the app does, since the shell sends
  no rectangle. On the landed tree nine controller test modules (115
  scenarios, `usable_tap_flow` and `motion_flow` beside the seven) and the
  headless navigation coordinator script passed, and the app built from it
  was launched once on the three placeholders (private scene, a config
  holding an `alt+shift` tap, private socket, 4.1 seconds, no Screen
  Recording access): `center-nearest right` settled on camera `1950 -0`,
  `pan-viewport right` on `2050 -0` and `zoom-to-fit` on zoom
  `0.28484848484848485` and back, a viewport screenshot was written and
  looked at, and it exited 0 on SIGTERM with its socket removed and the
  not-managed line alone on stderr. It had no window manager, so no observer
  existed there either and no real window event was driven. Known mismatches
  and limits:
  one behaviour is new and unobserved, a window its application reports
  destroyed is closed once it is off screen even if the window list keeps
  its number, which would also close the tile of a native tab if an
  application reports a deselected tab as destroyed; what no event announces
  is now found within a second, where the poll found it within 80 ms; one
  application that does not answer keeps the whole poll at its old pace;
  minimized windows, hidden applications and windows on another Space behave
  as before (kept, not captured afresh, not offered while off screen). No
  inventory row changes status: the rows this touches (window lifecycle,
  followed native focus) were `implemented_unverified` already and stay so.
  See the [event delivery rules](../../crates/desktop/LIFECYCLE.md#event-delivery)
  and the [desktop shell notes](../../native/desktop/README.md#event-driven-tracking).
- This milestone (commit pending), desktop mode, makes a normal run the
  desktop, as DriftWM is the session and not an app one launches (the
  owner's decision of 2026-10-10). Each display's panel covers the whole
  display, `NSScreen.frame`, and that rectangle is the output the shell
  registers: the 64-point strip with its toolbar buttons and status line is
  gone from normal runs, `--windowed` included, nothing is kept free for the
  menu bar or the Dock, and the panel stays at the floating window level,
  below both, so both go on drawing over the canvas. The panels are on every
  Space (`CanJoinAllSpaces | Stationary | IgnoresCycle |
  FullScreenAuxiliary`, public API only). A launch goes straight to the
  canvas; with Screen Recording or Accessibility missing one small window
  names what is missing, offers an Allow button for each, Relaunch and Quit,
  and opens the canvas when both are there. `--manual` keeps the chooser.
  What the status line flashed is one stderr line per note. The bundle
  carries a LaunchAgent (`RunAtLoad`, `KeepAlive` with `SuccessfulExit`
  false, Aqua, Interactive), `Infinify login-item on | off | status`
  registers it through `SMAppService`, and `scripts/install-app.sh` puts a
  signed copy in `~/Applications`; the quit action, `msg action quit`,
  SIGTERM and a log out end with status 0 after the usual cleanup, which is
  what returns the native desktop, and any other end is not 0. After a
  wake, an unlock or a Space change the panels are put back in front, and
  rebuilt only when the displays changed. No controller command changed
  shape and the controller's code did not change: `screen_bounds` was always
  whatever rectangle the shell named, and the shell sends no usable area, so
  hot corners are now the display's true corners and centering, placement
  and fit are measured on the whole display. The probe, demo and
  owned-fixture modes keep their strip, toolbar, status line and chooser
  unchanged. Evidence boundary: eight controller test modules passed (95
  scenarios, none about this milestone), the app was built and ad hoc
  signed with the LaunchAgent inside, and it was launched five times on
  2026-10-10 as `--windowed 1100x700` on three detached placeholders
  (private scene, config and socket, no Screen Recording access, nothing
  saved; Accessibility was evidently trusted, since no launch printed the
  missing-Accessibility note, and with placeholders only no native focus or
  input was attempted): `state` read the output as 1100x700 at camera
  `550 -350` where the strip left 1100x636 at `550 -318`, a viewport
  screenshot of 1100 x 700 pixels was looked at and shows canvas to every
  edge, `center-nearest right` settled on the Browser placeholder at
  `1950 -0`, centred in the whole view, each status note was one stderr
  line, and `action quit` and SIGTERM each ended the app with status 0 and
  the socket removed; `login-item status` from that bundle printed `off` and
  registered nothing. After the review fixes of the same day the eight
  modules passed again and two more such launches repeated those readings;
  in one, a failure note that arose twice 3.2 seconds apart was two stderr
  lines, and a third half a second later was none. That proves the windowed
  output and the clean exit
  and nothing else of desktop mode: no run was made on a whole display, so
  the panel under the menu bar and the Dock, every Space and Mission
  Control, wake, lock and a display change, the permission window with real
  grants and its relaunch, the quit at log out, the install script, the
  login item under launchd and a restart after a crash are compiled and
  read only, and no real window was on the canvas. All of that was on the
  tree desktop mode was built in, before the tap bindings (`72be7ea`), the
  background caches (`a47217e`) and event-driven tracking (`532a67d`); it
  lands on the tree that has all three. Two places in the shell changed at
  that join: its shutdown and its release stop the session watch and the tap
  monitors both; and the build script names each shell file once, desktop
  mode's `login-item.m`, `onboarding.m` and `session-watch.m` beside
  `window-events.m`, `tap-keys.m`, `frame-driver.m` and `background-tiff.m`.
  The rest was read, not run. A launch
  starts once: with both grants the canvas opens and starts the hot keys
  with the tap monitors, the coordinator and the window manager with its
  observers; with one missing the permission window is all there is, with no
  key registered, no monitor and no observer, until it hands over to that
  same start. The change of Space has two observers, each registered once:
  the session watch puts the panels back in front and the window events run
  a discovery pass. A rebuild of the panels stops and starts the tap
  monitors with the hot keys, lets the frame timer be made again by the next
  frame that is wanted, and keeps the window manager and its observers.
  Every way out ends in the one cleanup, which stops the observers, the
  session watch, the tap monitors, the frame timer and the capture streams
  once each. The three milestones added no stderr line to the shell's main
  file, so no note is written both directly and by the rule that writes a
  status note once; and nothing they added converts between a panel and its
  output, so the hover, the lost-input release and an event's look measure
  the whole panel as everything else does. On the landed tree thirteen
  controller test modules (179 scenarios, `usable_tap_flow`, `motion_flow`,
  `effects_flow`, `passthrough_flow` and `rules_flow` beside the eight) and
  the headless navigation coordinator script passed, and the app built from
  it was launched twice on the three placeholders (private scene, a config
  holding an `alt+shift` tap, private socket, four seconds and one, no
  Screen Recording access): `state` read the output as 1100x700 at camera
  `550 -350`, two viewport screenshots of 1100 x 700 pixels were looked at
  and show canvas to every edge, `center-nearest right` settled on the
  Browser placeholder at `1950 -0`, `pan-viewport right` on `2050 -0` and
  `zoom-to-fit` on zoom `0.28484848484848485` and back, stderr held the
  not-managed line alone, with no warning for the tap, and `action quit`
  ended one launch and SIGTERM the other with status 0 and the socket
  removed; `login-item status` from that bundle printed `off` and registered
  nothing. Being windowed and without Screen Recording access, those
  launches had no hot key, tap monitor, session watch, window manager or
  observer: nothing read at the join was run there, no tap was made and no
  window event arrived. Known mismatches and
  limits: a capture stream macOS stops across sleep or lock is not started
  again; a run started by launchd has no stderr, so its status notes are
  lost; nothing stops a second instance; cursor edge pan does not pan
  upward under the menu bar, where the shell reports no output; and no
  private window tag keeps the panel out of Mission Control, which was not
  observed either way. No inventory row changes status. See the
  [desktop shell notes](../../native/desktop/README.md#desktop-mode) and
  [started at login](../../crates/desktop/CONFIG.md#started-at-login).

These milestones add evidence to partial rows. None satisfies an entire native
behavior row or changes the completion requirement.

## Native feasibility gates

Before expanding the capture architecture, prove its treatment of real native
window families: two windows in one app, child panels, sheets, menus, popovers,
modal dialogs and IME candidate surfaces. Test independent camera views,
clipping, input target/focus, outside-frame pointer grabs and lifecycle. Separate
actual pixels/native effects from successful API calls and logical projections.

The `desktopIndependentWindow` ScreenCaptureKit filter selects a specified window.
The owned macOS 27.2 experiment observed grouped parent/child pixels despite that
selection, so native geometry cannot be inferred from the selected window alone.
SDK documentation scopes `includeChildWindows` to display-bound window and
application sharing; setting it is not proof of arbitrary popup capture.
See [Apple's filter contract](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:))
and [child-window property](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows).

Native resizing requires exact fresh AX/native identity and observed accepted
geometry, including constraints, rejections and timeouts. A stretched capture is
not native layout resizing. A single WindowServer transform cannot provide two
different views of one window; a privileged path still needs an independently
verified surface and interaction model. Disabling SIP alone establishes none of
these capabilities.

On 2026-10-11 the owner selected independent views per display. The native adapter
now selects one stable real placement and renders other root placements from one
shared live capture, with each display's camera and zoom. Scoped replica pointer
delivery and canvas green-button actions are wired. Separate popup/sheet streams,
metadata crops, scoped member input and family closing/export are now implemented
but unverified. Child-only replica placements also preserve visible popups when
their root is outside a display viewport, without changing world geometry or
native ownership. Hover uses the exact validated child and retains controller
pick/grab policy; stale session or binding observations cannot restore family
placements. Captured-view hover is now enabled in native mode while physical
native motion is not reposted. Canvas pick, resize and mouse-grab cursor shapes
are implemented with conditional application-local restoration; foreign replica
cursor images remain unavailable. Captured root/child ordering now uses a
coherent native rank cohort within controller-order and physical/pinned/closing
barriers. Hit detection consumes the renderer's applied order, refusing stale
descriptions; clicks delayed for focus retain their original binding and exact
recipient, and are discarded on source/session cancellation. One-shot exports
use their own revalidated stacking cohort with offscreen-family fallback and
the same compositor order constraints. Cross-family closing order and
physical-versus-replica stacking remain incomplete. Native clipping at display boundaries, physical interaction, capture
quality and presentation timing remain open. Targeted Rust linting, a release
library build and native compilation/linking passed without running tests or
launching fixtures; this does not change any row to verified.

Other unresolved authority gates are exclusive global gestures while an app owns
keyboard focus, relative/confined input, native cross-app drag-and-drop, secure
capture/input suppression around lock, and reconciliation with macOS-owned
display mode/scale/rotation/power. The owner's host-control decisions require
coexistence with those display settings, not a second configuration interface.
The available public APIs cover parts of these behaviors; missing public APIs
are not by themselves proof that private implementations are impossible.

## Work order

1. Maintain the source-pinned inventory and define each row's exact acceptance.
2. Run owned-fixture native family, input and geometry capability proofs.
3. Review those proofs before choosing the native family/input architecture.
4. Port policy semantics with differential traces against pinned upstream:
   snapping, constraints, cameras, navigation, focus, fullscreen and placement.
5. Integrate compatible configuration, IPC, sessions, renderer and native actions
   through stable module boundaries, with one integration owner.
6. Verify platform services and any required client compatibility.
7. Run acceptance on M5/macOS 26 and required physical displays/devices, plus
   representative native application families and failure/recovery cases.

Policy work can proceed while native feasibility remains open. A failed or
unproven native gate must remain visible; it cannot be hidden by progress in
unrelated features. Tests stay focused on changed paths and touched modules.

## What is still open

On 2026-10-10 every row that was still `missing` was read again against the
tree at `ed34eec`. 24 of them described behaviour a default launch already has
and became `implemented_unverified`; the other 190 stay `missing`, each with a
note that says why. No row is `verified` or `blocked`, and the sweep moved none
to `out_of_scope`: that is the owner's decision, which a note only recommends.
Two milestones have moved rows since, and the table is counted from the file
as it stands after both, and was counted again from it after event-driven
tracking and desktop mode, which moved none. The tap-bindings milestone moved one,
`config.keybindings.alt+shift`, to `implemented_unverified`. The background
caches milestone above took four more out of the real gaps, the field and
reference rows of `cache_shader` and `cache_budget_mb`. `protocol.layer_shell`
stays `missing` and stays counted for full native panel/overlay acceptance.
Independent floating panels now have an explicit display-pin policy and retain
the application's stacking and keyboard focus; this does not establish full
third-party overlay compatibility. The owner subsequently selected menu-bar/notch
exclusion for fit/fullscreen, while leaving the Dock outside that exclusion.
On 2026-10-11 sizing and fullscreen began to run in every normal run, which
moved 27 rows out of the gated group to `implemented_unverified`. Later that
day resizing by pointer began to run in every normal run too, which moved 13
more: the 2 that were gated (2 − 2 = 0), 1 that was counted as provided by
macOS (68 − 1 = 67) and 10 of the real gaps (21 − 10 = 11), so
427 + 13 = 440 and 158 − 13 = 145 = 0 + 67 + 67 + 11. The owner later
excluded the 67 features without a Mac equivalent, and native green-control
dispatch implemented the two `decoration_fit_snapped` rows. The current counts
after the 67-question review and native continuation are 444 implemented but
unverified, 72 missing and 72 outside scope. The two newly excluded rows concern
tablet display mapping; source tablet delivery and relative mouse-delta conversion
moved their rows to partial `implemented_unverified`. No runtime status was promoted.

| Rows | Count |
| --- | --- |
| `implemented_unverified` | 444 |
| `missing` | 72 |
| of which gated behind `--experimental-native-resize` | 0 |
| of which delegated to macOS | 65 |
| of which awaiting a scope decision | 0 |
| of which with no Mac counterpart | 0 |
| of which real gaps | 7 |
| `out_of_scope` | 72 |
| all rows | 588 |

Current implementation priorities (2026-10-11, after the independent-display
view decision):

- Complete native clipping at display boundaries and replica cursor-image
  synchronization. Root/member replicas, scoped pointer/tablet routing and family
  closing/export are implemented but unverified.
- Complete Spaces gathering and native popup/modal ordering across applications;
  preserve the selected display-pin policy and application-owned panel focus.
- Finish raw multi-finger gesture delivery over application windows and verify
  the physical magnify path. Normal-run sizing/fullscreen dispatch is implemented.
- Implement drag-and-drop across captured views and application-requested pointer
  lock/confinement. Implicit mouse capture, relative delta conversion and tablet
  payload forwarding are partially implemented; physical delivery
  and replica cursor images remain open. Tablet display mapping is excluded.
  These are three missing rows because drag-and-drop is
  represented by both `protocol.data_device` and `platform.dnd`.
- Complete panel/overlay compatibility (`protocol.layer_shell`) and the target
  platform acceptance pass (`platform.acceptance`). The two remaining brightness
  gesture examples name Linux commands; the owner uses macOS brightness controls,
  so these do not require a new Infinify brightness setting.
- Reconcile and verify the 444 implemented-but-unverified rows, including native
  family/input/geometry, configuration and IPC, renderer behavior, session restore
  and recovery. Some rows still contain known partial behavior; that status is
  not a claim that only testing remains. Stable 120 fps is also unproven.
- Preserve existing Mac display/window capture for sharing and recording.
  Question 18 is resolved: no dedicated Infinify canvas feed is queued. Internal
  root-replica streams for independent per-display views remain required.

The 65 delegated missing rows remain integration/acceptance accounting, without
duplicate Mac controls. All 67 questionnaire decisions are resolved; work remains
on the implementation gaps above. On 2026-10-12 the owner authorized overnight
benchmarks and tests while the laptop is idle. Native mutation remains limited
to explicitly spawned disposable fixtures under `AGENTS.md`; broader application
acceptance and SIP-off testing remain separate from those owned-fixture results.
Earlier scope updates ran no tests or fixture launches.

The `missing` rows, by group:

- **Gated behind `--experimental-native-resize` (0).** The flag and its legacy
  path have been removed. Normal edge/corner resizing uses the current native
  resize coordinator; old invocations are rejected as unknown arguments.
- **Resize by pointer in every normal run (13 rows moved on 2026-10-11).**
  `MouseAction.ResizeWindow` and `ResizeWindowSnapped` with their default
  bindings `config.mouse.on-window.alt+right` and `alt+shift+right`;
  `ContinuousAction.ResizeWindow` and `ResizeWindowSnapped` with
  `config.gestures.on-window.alt+3-finger-swipe` and
  `alt+shift+3-finger-swipe`; `field.WindowRule.preserve_aspect_ratio`; and
  `resize_on_border` and `decoration_resize_snapped`, each with its field row
  and its reference row. A bound press, and a left press on the resize border,
  start upstream's resize grab as a size transaction in readback mode: each
  size is asked of the real window and the canvas shows the size it took
  (`crates/desktop/NATIVE_RESIZE.md`, "Pointer resize"). The pointer rows, the
  border and the ratio were run end to end on disposable fixture windows by
  `tests/e2e/scoped-resize-drag.sh` (`native/desktop/README.md`, "What has
  been run for the pointer resize"). The four gesture rows were run at the
  controller only (`crates/desktop/tests/gesture_flow.rs`): no gesture can be
  made through the shell by a test, and what the shell does with the size
  requests a gesture reply carries was shown by the pointer drag. What keeps
  all 13 unverified: every press and drag was synthesized through the canvas
  view's own handlers, none was made by a person or delivered by the window
  server, no application of the owner's was resized, nothing was seen with a
  picture, and there was one display. Where a Mac window cannot follow
  upstream's client is in each row's note.
- **Sizing and fullscreen in every normal run (27 rows moved on 2026-10-11).**
  `grow-window`, `shrink-window`, `fit-window`, `fit-window-snapped`,
  `fill-window`, `toggle-fullscreen` and fullscreen itself, a rule's `size`
  and `fullscreen`, `navigation.resize_step`,
  `hot_corners.disable_when_fullscreen`, and the key, mouse and pinch bindings
  that run them were `missing` behind the flag and are now
  `implemented_unverified`: the shell of every normal run performs size
  requests, and a size is settled by reading the window back, with no capture
  (`crates/desktop/NATIVE_RESIZE.md`, "Readback mode"). They were run end to
  end on disposable fixture windows and an Electron window by
  `tests/e2e/scoped-sizing.sh`
  (`native/desktop/README.md`, "What has been run for sizing without the
  flag"). What keeps them unverified: no application of the owner's has been
  resized or made fullscreen, no chord, mouse press or trackpad gesture was
  made by a person, a rule's `fullscreen` and a hot corner beside a fullscreen
  window ran in controller scenarios only, and nothing was seen with a
  picture.
- **Delegated to macOS (65).** The owner confirmed the Mac's existing controls
  and services in the 67-question review and follow-up on 2026-10-11. Infinify must preserve
  their behavior; the decisions do not establish successful integration.
  No duplicate controls are queued; host integration still needs acceptance
  evidence.
  Families: the display arrangement (`[[outputs]]` scale, transform, position
  and mode, and output management); display power, gamma, idle and the lock
  screen; screencast source selection and native display/window capture;
  synthetic keys; trackpad and mouse
  settings; keyboard layouts and Caps Lock; the pointer
  size; the volume, brightness, media and Print keys.
- **Live capture (included in the 65 delegated rows).** The owner resolved
  question 18, `protocol.image_copy_capture`, with “Use existing Mac capture”.
  A dedicated Infinify canvas feed is not required. The row remains `missing`
  for host integration/acceptance accounting, without runtime evidence.
- **Tablet display mapping (2 newly outside scope).** Questions 62 and 67,
  `field.Config.tablet` and `field.TabletSettings.map_to_output`, are now
  `out_of_scope` with `required: false`. The corresponding reference-config row
  was already excluded. Pen-event forwarding remains a separate required gap.
- **No Mac counterpart (67, now outside scope).** The owner excluded these
  on 2026-10-11. Families: everything touchscreen (the `[touch]`
  tables and thresholds, the touch-only triggers, `[input.touch]` and the two
  touch speeds); `[backend]`; `[xwayland]`; the cursor theme and the cursor's
  opacity on inactive outputs; Num Lock and the XKB keyboard model; the primary
  selection; shortcut inhibition by a client; the media stop key; the reference
  config's tablet `map_to_output`.
- **Native green control (2 implemented but unverified).** The native input
  bridge dispatches the exact clicked binding to canvas fullscreen or, with
  Option held, fit. `decoration_fit_snapped` now carries fit to snapped neighbours.
  Actual physical input and third-party acceptance remain unverified.
- **Real gaps (9).** Nothing but the work is waited for here:
  - drag-and-drop between windows on the canvas (2);
  - pointer lock, confinement and relative motion for the application under
    the pointer (2);
  - tablet tools (1);
  - any policy for panel or overlay windows; the row's other clause, the
    area a panel reserves, is no gap but the owner's decision: nothing is
    reserved for the menu bar and the Dock (1);
  - the two brightness swipe examples, whose command is a Linux program with
    no Mac substitute (2);
  - the acceptance pass itself, on the M5 and macOS 26 target (1).

The questionnaire resolves the earlier split treatment of tablet `map_to_output`:
display mapping is excluded across both typed fields and the reference-config
spelling. The existing Mac/driver feature stays available.

Two more gaps have no row of their own. They are recorded in the
[pointer contract](../../crates/desktop/POINTER.md#differences-from-upstream),
not in the inventory: popups and menus open at the native window's place, not
where the canvas draws the window, and the cursor shape cannot follow the
application under the pointer.

The evidence boundary stands for every row, whatever its status. The original
inventory evidence consisted of controller scenarios, own-fixture probes and
scripted `msg` sessions without Screen Recording access. Overnight performance
runs on 2026-10-12 additionally captured real animated disposable fixture
windows. That does not establish third-party acceptance or verify the inventory
rows. No completion claim follows from these counts.
