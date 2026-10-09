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
./tests/e2e/desktop-app.sh
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
lifecycle uses fresh hotkey IDs. Excessive queued presses fail closed until
panels reopen. Actual native event ordering still requires live validation. Failed registration
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
There are no native resize changes.

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
