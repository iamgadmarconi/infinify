# Infinify native desktop shell

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+. The build does not launch anything. Open the app to
choose ordinary local application windows. No window is automatically selected.
Screen Recording permission is required for capture; Accessibility permission
is required for native input. Missing grants are explained in the chooser; this
app and its tests never request permissions or change privacy settings or SIP.

The app links the actual Rust desktop static library. Every connected display
gets a nonactivating panel and an independently persisted camera on the shared
world. Each visible `(logical window, display)` has its own
`AVSampleBufferDisplayLayer`; one ScreenCaptureKit stream feeds all placements of
a source. This is continuous live capture of native application content.
Ordinary native windows remain where their owners put them. Cameras and world
movement do not move, transform, park, or resize native windows.

## Controls

- Choose windows: add a selected native source, or explicitly rebind a saved
  placeholder using the chooser's drop-down. Same-source duplicate attachments
  are rejected; the existing world window is visible through every display camera.
- Drag blank canvas or Option-drag / Option-scroll: pan that display's camera.
- Command-scroll or pinch: pointer-anchored zoom, from 0.001 to 1.0.
- Control-Option-drag: move the logical world window, using Rust snapping and
  hysteresis. Add Shift to move its connected cluster.
- Normal left-click, left drag, and scroll: forward through Rust inverse hit
  mapping to the selected native source. The original application owns keyboard
  focus, text editing, shortcuts, and IME; the overlay does not emulate a text field.
- Control-Option-click a detached placeholder: dismiss it.
- Return to desktop: stop capture, close panels, and show the chooser.
- Quit or the registered Control-Option-Escape hotkey: save and exit. The visible
  Quit button remains available if hotkey registration fails.
- Resize status: explains that native layout resizing is currently unavailable.
  Resize the original application on the desktop; observation reconciles native
  bounds and capture dimensions without replacing persistent world geometry.

A normal source click requests activation only for its freshly validated owning
application. Identity validation checks PID, process birth, window number, current
owner PID, and the last observed native bounds immediately around delivery.
Private per-window routing is reused verbatim from
`../captured-windows/captured.m`, including its Cantrip signature provenance.
There is no global synthetic event fallback. Release-on-cleanup applies only to
left buttons pressed by this shell; user keyboard state is never synthesized or
released. Lost/closed sources become inert placeholders. Stream errors detach
rather than leaving stale content eligible for input.

## Persistence and lifecycle

The default scene file is
`~/Library/Application Support/Infinify/scene.json`. `--state /absolute/file.json`
selects another file whose parent directory already exists. Saves use the Rust
controller's private temporary file, fsync, atomic rename, and directory sync.
Only world geometry, display UUID cameras and app/title metadata are persisted;
PIDs, window IDs, process births, and captures are not saved. Reloaded windows are
unbound placeholders. A chooser selection is always required to rebind; there is
no PID or title guess. A failed load blocks source selection and disables every
save path, preserving the original bytes until an explicit different state path
or repaired file is provided. Display changes recreate panels while retaining cameras
by stable display UUID. Source lifecycle and normal bounds are polled on the
main event loop; ScreenCaptureKit buffers independently report pixel dimensions.

## Safe disposable demo and verification

```sh
./scripts/build-app.sh
mkdir /tmp/infinify-demo-unique
./target/app/Infinify.app/Contents/MacOS/Infinify --demo /tmp/infinify-demo-unique
./tests/e2e/desktop-app.sh --live-owned-fixture
```

Both demo modes accept only an empty evidence directory, launch their own
nonce-enrolled native AppKit child, and restrict the chooser to that exact PID.
Interactive demo stops after 60 seconds; the child has a 65-second deadline and
also exits when its parent exits. Automated probe requires existing grants,
never prompts, and writes all state into a fresh temporary directory. It blocks physical input to its test canvas and stops
scripted controls when foreground ownership changes or source events show any
untagged input, including before capture starts. Interrupted runs delete captured
screenshots. A second `--demo-probe-guard` regression injects an untagged click
only into its disposable source and verifies suppression and cleanup. Previous foreground is restored only if the fixture is still
foreground and the prior process is still the same running application.

The E2E drives the chooser selection and real capture pipeline, inspects exact
host-window screenshots for independently updating red/blue content in both
clipped views, changes the Rust cameras, sends scoped native button/text/scroll
input through the changed views, checks saved-state reload remains unbound,
and verifies stale-input rejection and cleanup. Text assertions use SHA-256 of
the fixture's actual native control contents. This proof uses two viewports in
one panel on the development machine; it does not claim physical multi-display
or arbitrary third-party app compatibility.

## Known limits

Native AX layout resizing is deliberately gated, not simulated by changing
world geometry. Right/middle click, hover, cross-boundary pointer capture,
context-menu/popover capture, native drag-and-drop, and application-specific
floating child windows are not implemented. Ordinary selected app activation
works with the tested native window, but choosing among multiple native windows
of one application and app-specific focus rules needs broader validation.
A held pointer drag cannot retarget another source. Only the last validated
in-window point receives a synthetic button-up if a pointer leaves its source; arbitrary outside-source drag delivery is not claimed.
Minimized/hidden/Space transitions, display hotplug, IME composition and the
registered exit hotkey require manual validation on the intended workstation.
Cluster behavior uses the controller contract; fixture evidence currently has a
single source. Production chooser/managing of existing user windows has not been
run during development. Ad-hoc signing is local development packaging, not a
notarized distribution build. Private SkyLight input symbols can change with OS
updates; unavailable symbols leave live viewing functional and input disabled.

## Experimental native navigation

`--experimental-native-navigation` opts into the native navigation integration.
It can accompany `--state /absolute/file.json` or the interactive `--demo DIR`;
probe and internal child modes reject it. The default click/activation path is
unchanged. This flag is an experimental runtime authorization for explicitly
selected sources, not evidence of third-party compatibility.

The gated toolbar adds **Center selected**, **Previous**, and **Next**. Center
uses the controller's `navigate_window` with reset zoom; this does not claim the
complete upstream `CenterWindow` action. Previous/Next use unheld cycles. Toolbar
navigation resolves the toolbar's display; shortcuts resolve the pointer's
output. A multi-output demo toolbar requires the pointer inside an output.
No arbitrary first display is selected. Already-reserved toolbar space is not
subtracted a second time.

Option-Tab and Option-Shift-Tab use Carbon hotkeys only while the experimental
panels are open. A listen-only event observer tracks the accepted keypress,
actual Option release, and human interruption. Delayed Carbon delivery after
release is unheld; delivery after cancellation is rejected. Canceled presses
remain as tombstones so an old callback cannot borrow a later press; each panel
lifecycle uses fresh hotkey IDs. Excessive queued presses fail closed; reopening
panels resets the queue. Actual native event ordering still requires live validation. Failed registration
leaves the buttons available. A missing or disabled input observer disables
native focus dispatch, including button focus, while camera navigation remains
available. No event-suppression fallback or permission prompt is used.

Only these explicit navigation actions dispatch native focus effects. A serial
worker receives immutable effect/identity/generation tickets, bounded deadlines,
and cancellation epochs. Ownership, unchanged native bounds, and foreground
process birth are checked without entering the controller from the worker.
Workspace activation notifications permanently invalidate a lease after a
foreign foreground transition. Success requires independent exact-window
readback from the focus adapter. Mouse and other human intent cancel pending
work and camera flights before the legacy pointer path; clicks are never saved
for later replay. Detach, rebind, chooser, screen changes, cleanup, and shutdown
invalidate work before teardown. Unsupported non-null owner authority fails
closed rather than being silently discarded.

Coalesced bounded observation runs at most once per half second on the same
serial worker. Expected confirmations use `focus_result`, duplicate confirmed
observations do nothing, independently validated external focus ends cycling,
and failed/unknown readback does not claim focus loss. A single common-mode
60 Hz main-thread timer advances all active camera flights and renders once per
frame; idle polling keeps the clock current and completed flights save once.
The navigation flag does not enable resizing; resizing has a separate experimental flag.

`./tests/e2e/desktop-navigation.sh` runs the real Objective-C coordinator and
input-order policy against the actual Rust C ABI with injected nonmutating
focus, clock, and scheduling. It covers exact identities, binding generations,
held/reverse/release-pending cycles, supersession, rejected commands, teardown,
observation reconciliation, pointer cancellation, two-output intermediate camera
poses, and saved final poses. It starts no NSApplication, windows, fixture,
capture, hotkeys, or event taps. The app build and this test are integration
checks only. Live native focus, multiple windows of one app, third-party apps,
physical displays, shortcut delivery, foreground notifications, and input-tap
behavior remain unrun and unproven for this path.

## Experimental native resizing

`--experimental-native-resize` independently enables eight orange handles on the
selected ordinary source. Handles use true projected world edges; viewport clipping
does not invent resize edges. Shift/group resize is rejected. Default controls stay
unchanged. Escape requests cancellation (the global observer does not suppress the
native app's Escape); release ends the gesture. The OS must already permit event
observation; no permission prompt is requested. Global Escape observation remains
unproved on a live host.

`resize-coordinator.m` calls the real Rust JSON C ABI only on the main thread. Every
emitted adapter effect is registered before its serial worker dispatch, matched to
the controller's current pending effect, and reconciled on main even after cancel,
output removal, or quit. Duplicate dispatch is rejected for the coordinator lifetime.
There is no second motion queue. Setter timeout uncertainty retains the source;
unknown geometry, temporary CG absence, or stream failure never attests lifetime end.
Chooser/load/detach/return require the controller's structural guard to permit them.
Quit drains every dispatched call without a timeout-based destruction deadline, then
saves committed geometry; unresolved uncertainty is reported, not rolled back or
reported successful. An OS call that stalls leaves shutdown visibly pending.

The native driver reuses `native/families/window-server-family.h`: read-only yabai
MIT-derived WindowServer queries at commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, with `YABAI-NOTICE.txt` copied into the app.
Unknown ancestry, children, foreign association, and unmapped extent are unsupported.
A fresh root-only guard is checked immediately before AX size mutation. Its veto is
an adapter policy refusal, not evidence about AX resize capability. Original adapter
results, including actual AX/CG rectangles and timeout flags, pass through unchanged.

Managed capture never unconditionally enqueues frames. Initial binding explicitly
invalidates capture authority. Acceptance requires exact stream/source/generation/
revision, complete typed metadata, a strictly newer WindowServer mach display time
than the main-thread observation cutoff and last displayed frame, real CV buffer
dimensions, a bounded pixel crop derived from contentRect and scaleFactor, and
screenRect plus content extent matching a freshly verified root-only native frame.
Missing metadata has no arrival-time, frame-count, or configuration-callback fallback.
The same sample acknowledged by the C ABI is installed. Placement and input mappings
include content padding; input native coordinates remain native geometry. Lost
mapping immediately removes every existing surface and clears retained frames. The
last accepted sample is retained with its revision for newly visible placements of
static sources; a new layer that cannot install it remains inert. Generic geometry
polling is disabled for managed sources; the capture gate reconciles fresh idle
geometry only when the controller permits structural changes, then requires a
post-observation frame. Active or uncertain transactions retain exclusive ownership. A half-second read-only
validation tick also checks roots independently of frame arrival; input delivery
performs the same validation. Newly observed loss after recovery advances the token
even when no frame has restored capture authority.

A revision change requests updated stream dimensions after the cutoff; its callback
is never proof of fresh pixels. Whether static native applications reliably emit a
new Complete frame after this request is **unproved**. Strict metadata checks may
leave a tile inert. Metadata proves geometric freshness, not semantic layout or
pixel correctness; current screenRect coordinate assumptions require live validation.

`tests/e2e/desktop-resize.sh` exercises the production coordinator, Rust C ABI, and
real synthetic CVPixelBuffer/CMSampleBuffer objects without NSApplication startup or
any native windows, AX calls, capture streams, activation, event taps, or fixtures.
This is headless contract evidence only. The signed app is built without launching.
The existing independent resize fixture does **not** prove this integration. A future
explicitly authorized owned-fixture gate must cross real handles, AX mutation, SCK,
renderer pixels, independent AX/CG observation, clamp behavior, static-frame refresh,
Escape handling, and cleanup. No such integrated live proof has been run or claimed.

## Prepared noninteractive owned resize gate — runtime UNRUN

`tests/e2e/desktop-native-resize.sh` defaults to building the signed app, reading
pre-AppKit help, the existing headless resize integration, and 66 offline PNG
oracle CLI regressions. It creates no windows, starts no capture, makes no AX
calls, and registers no input observers. Its success proves preparation only.

After an explicitly authorized desktop test interval, select one bounded case:

```sh
./tests/e2e/desktop-native-resize.sh --live-owned-fixture --scenario right-shrink
```

The native internal entry point is `--owned-resize-probe EMPTY_DIRECTORY [SCENARIO]`.
Only this entry point spawns/enrolls its exact nonce/PID/kernel-birth/window fixture;
there is no arbitrary PID/window option. `--owned-resize-fixture` validates its
actual parent identity and lease before AppKit startup. The foreground PID and
kernel birth are captured **before** NSApplication initialization and rechecked
after startup and before every window order. Startup self-activation fails; it
never becomes an accepted baseline. A fresh isolated scene is used. The chooser attaches the exact SCK source, and the runner calls the real
DesktopView mouseDown/Dragged/Up at a real projected orange handle. Normal input
forwarding is disabled only for this internal mode, so a vanished handle cannot
fall through to activation. Production capture policies and reconfiguration are
unchanged. A driver lease composes with the existing root-only check immediately
before AXSize. Its hooks are frozen before dispatch; native results pass through
unchanged and are drained during shutdown.

Cases are `EDGE-grow`, `EDGE-shrink`, and `EDGE-clamp` for `top_left`, `top`,
`top_right`, `right`, `bottom_right`, `bottom`, `bottom_left`, and `left`; also
`static`, `family`, `sigint`, `sigterm`, and `controller-death`. Default is one
right-shrink case. `--scenario matrix` explicitly requests all cases and stops on
the first failure. Each controller has a 23-second work deadline and each fixture
an independent 25-second lifetime. Synchronous OS-call stalls cannot be forcibly
bounded safely: a stalled controller is terminated and, after a four-second drain grace, killed
and reaped as an explicitly failed run. SIGKILL is also used for the selected
controller-death case, never as fixture restoration proof.

The fixture is deliberately a **borderless resizable AppKit window** with real
min/max constraints, a same-title decoy, and (for `family`) a real attached child.
It does not override AX setters. Unsupported exact AX identity or AXSize fails;
it does not widen the scope or claim ordinary titled/third-party compatibility.
It draws once and invalidates only when actual content bounds resize: fixed
24-point markers on opposite edges and six 36-point saturated tiles wrap at a
400-point content width. No animation or manual redraw during capture waiting
makes static refresh appear successful. Two actual AV render surfaces use .6 and
.9 cameras; independent AX/CG rectangles plus fixed layout/output constants drive
the external saved-byte PNG oracle. Native origin movement is recorded honestly;
world opposite-edge anchoring and unchanged cameras are separate assertions.
Controller crop metadata and fixture child frames are not oracle inputs.

This mode is exclusively a **noninteractive owned layout/capture probe**. Its
root, decoy, child and chooser use a dedicated NSWindow subclass that refuses key
and main status and sets ignoresMouseEvents before any ordering or child attachment.
Its host panel has the same contract plus the nonactivating style. A dedicated
NSApplication is installed from startup and rejects unexpected queued pointer,
button, drag, scroll, keyboard, flags, gesture, tablet and unknown events before
normal dispatch, atomically latching failure. Framework housekeeping alone passes;
there is no event-tag exemption. Scripted DesktopView calls bypass the event queue.
All owned-window exclusion contracts are checked before capture and mutation.

Every setter checks the exact owned identity, unchanged read-only transform,
recognized geometry, deadline, foreground identity, fresh fixture exclusion state,
and sticky input-exclusion status. The same foreground application's unrelated
input is allowed: this mode does not query global HID inactivity or require an
input-observation grant. Switching foreground apps still aborts, and unexpected
input delivered to the probe is dropped and permanently aborts the session.
Owned mode registers neither the global Escape monitor nor the exit hotkey; use
the supervisor's SIGINT or the bounded deadline. Visible chooser buttons are inert
in this probe, and the host toolbar explicitly labels the noninteractive mode.
Other desktop/demo modes retain their existing controls. This does not prove physical-input handling or ordinary
application compatibility. Source and host screenshots are only of enrolled owned windows and are deleted after
interruption. No global event posting, foreground activation/restoration, transform
setter, permission prompt, SIP or settings change is used. The fixture watchdog
runs in common and event-tracking modes, checks exact parent birth, reconciles only
recognized pending resize intent, and skips restoration after unknown/human state.
It closes only its own windows and writes an honest receipt. Normal and signal restoration
are independently checked through AX/CG while the fixture remains alive. On
controller death, the fixture holds its restored window for at most two seconds so
the surviving supervisor can independently read AX/CG and transform before
acknowledging closure. A missed hold or missing readback is restoration-unproved
and fails; a fixture receipt plus disappearance alone cannot pass cleanup.

`resize-live.py` records exact source hashes including the `.inc.m` inputs and
runs `resize-verify.py` only after native-path completion. Abnormal/family scenarios
never claim pixel/layout proof; missing scenarios are not marked passed. No
successful live result has been frozen for this integration. Startup/preflight,
AX enrollment, per-guard conditions, first contamination, and restoration evidence
record separate booleans, exact owned bounds and initial/current transforms; no
human text is recorded. A transform failure does not silently replace the initial
baseline. The new noninteractive path remains runtime-unrun. Full native resizing
parity, reliable
static SCK refresh, real desktop interruption handling, and third-party support
remain **unrun and incomplete**.
