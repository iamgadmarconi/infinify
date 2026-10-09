# Infinify native desktop shell

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+. The build does not launch anything. Open the app to
choose ordinary local application windows. No window is automatically selected.
Screen Recording permission is required for capture; Accessibility permission
is required for native input. The chooser explains a missing grant and offers an
Allow… button: the app asks macOS for access only from that click, then opens
the matching System Settings pane. Screen Recording takes effect after a
relaunch. Automated probes and tests never request permissions or change privacy
settings or SIP. An ad-hoc signature changes with every build, so macOS drops
both grants on each rebuild; build with
`INFINIFY_SIGN_IDENTITY="<stable signing identity>" ./scripts/build-app.sh` to
keep them.

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
- Open canvas (chooser): show the saved world and its cameras without adding a
  window. Placeholders, panning, zooming and the view actions need no capture,
  so this works before any source is chosen and without Screen Recording access.
- Drag blank canvas or Option-drag / Option-scroll: pan that display's camera.
- Command-scroll or pinch: pointer-anchored zoom, from 0.001 to 1.0. The view
  actions below are the animated toolbar and keyboard equivalents.
- View actions: toolbar buttons Home, Fit, −, 1:1 and + on every canvas panel,
  and while panels are open the global shortcuts Control-Option-A (home toggle),
  Control-Option-W (zoom to fit; press again to return), Control-Option-= (zoom
  in), Control-Option-- (zoom out), Control-Option-0 or Control-Option-Z (zoom
  1:1), and Control-Option-Command with an arrow key (pan one step). Buttons act
  on their own display (in the two-viewport demo panel, the viewport last
  clicked, scrolled or pinched, else the first); shortcuts act on the display
  under the pointer, or the first display when the pointer is over no panel.
  Home goes to the origin at 1:1 and Fit frames every window, detached
  placeholders included; a second press returns to the view left, and any other
  pan or zoom forgets the Fit return. Zoom in stops at 1:1. Zoom out stops at
  half the zoom that fits all windows and does nothing if a gesture already
  zoomed past that. A pointer press, scroll or pinch on a canvas stops a flight
  where it is.
- Bookmarks: Control-Option-1 to 4 fly the camera of the display under the pointer
  to saved point 1 to 4 (zoom is left alone and any Fit return is forgotten);
  Control-Option-Shift-1 to 4 save the usable-area centre of the current view as
  that bookmark. Pressed while a pan step or a bookmark jump is still flying, they
  save where it is heading. During a Home, Fit or zoom flight the saved point is
  not reliably the destination, here as upstream (mid-flight it is whatever point
  is passing under the centre), so let those land first. The
  status line confirms ("Bookmark 2 saved") or says the bookmark is missing ("No
  bookmark 2 yet", with the chord that sets it). A bookmark holds a canvas position
  only, never a zoom. There is one set of bookmarks for every display, and it is
  saved in the scene file. They are global shortcuts only: with `--windowed`, use
  `Infinify msg bookmark` or `Infinify msg action` below.
- Shortcuts and toolbar buttons have no configuration yet: Control-Option stands in
  for DriftWM's "mod", the chords are hardcoded (bookmarks cover names 1 to 4 only),
  and the pan step (100 screen points), zoom step (1.1) and fit padding (80) are
  upstream's defaults. Every view and bookmark shortcut and every view button on the
  toolbar now runs an upstream action string (`home-toggle`, `zoom-to-fit`, `zoom-out`,
  `zoom-reset`, `zoom-in`, `pan-viewport <direction>`, `go-to-bookmark N`,
  `set-bookmark N`) through the same controller command as `Infinify msg action`.
  Camera motion is animated with the controller's upstream-derived lerp. These
  actions move cameras only; they never move, resize, focus or otherwise touch
  native windows. If a shortcut cannot be registered the toolbar still works. A
  held chord is one step: it does not auto-repeat as upstream's zoom in, zoom out
  and pan do. The Quit button and Control-Option-Escape call the shell's quit
  directly instead of sending the `quit` action, so exit never depends on the
  controller or on an active output. The experimental navigation and resize
  controls below were not changed by this.
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
Only world geometry, display UUID cameras, bookmarks and app/title metadata are
persisted; PIDs, window IDs, process births, and captures are not saved. Bookmarks
are an additive field of the same file and the format version is unchanged: scene
files written by older builds still load, with no bookmarks. Older builds reject
fields they do not know, so an older build cannot read a scene file that contains
bookmarks; keep a copy of a scene file before opening it with an older build.
A bookmark change or window move made over the IPC socket below is saved the same
way. Home and Fit return positions are per display, in memory only: not saved, and
dropped on reload, on Return to desktop, and whenever a display change recreates
the panels. Reloaded windows are unbound placeholders. A chooser selection is
always required to rebind; there is no PID or title guess. A failed load blocks
source selection and disables every save path, preserving the original bytes until
an explicit different state path or repaired file is provided. Display changes
recreate panels while retaining cameras by stable display UUID. Source lifecycle and normal bounds are polled on the
main event loop; ScreenCaptureKit buffers independently report pixel dimensions.

## Scripting (IPC)

A normal run listens on a Unix-domain socket, and `Infinify msg` is the macOS
counterpart of `driftwm msg`: upstream's requests and JSON shapes (one JSON line
out, one back), with the arguments after `msg` mirroring upstream's CLI.

```sh
APP=./target/app/Infinify.app/Contents/MacOS/Infinify
$APP msg state
$APP msg --json camera 500 300
$APP msg action zoom-to-fit
$APP msg bookmark inbox 500 300
```

`msg` runs before AppKit starts, so it opens no window and asks for no permission.
It prints a readable reply, or the reply as JSON with `--json`. An error reply or
a failed connection prints `error: …` on stderr and exits 1; with `--json` an
error reply is printed as JSON on stdout instead, still with status 1, as upstream
does. A usage error exits 2. `--json` and `--socket` may go before or after the
command (upstream takes them before it); command options such as `--id N` go
after it.

The default socket is `~/Library/Application Support/Infinify/infinify.sock`. The
app's `--socket PATH` flag moves it; the path must be absolute. `--state` does not
move the socket, so a second instance on its own scene file needs its own
`--socket` as well. `msg` looks for `--socket PATH`, then the `INFINIFY_SOCKET`
environment variable, then the default; the app itself does not read
`INFINIFY_SOCKET`. The socket's parent directory must exist, be owned by you and
not be group- or world-writable, the socket is mode 0600, and a peer with another
user ID is hung up on. A request is one line of at most 64 KiB (a longer one is
hung up on without a reply), at most 16 connections are served at once, and one
that completes no request for 30 seconds is closed. A stale socket file is removed
only after connecting to it fails. Nothing serializes that check and the bind
between instances, so two started on one path at the same moment can both find it
stale, and the later one then replaces the earlier one's socket; give instances
their own paths rather than rely on the check. If another running Infinify
answers, or the
path is unusable (longer than 103 bytes, a directory that fails the checks above,
a file that is not a socket), this app keeps running without IPC and says so in
its status line and on stderr rather than taking the socket over. The socket is
removed on quit. The server runs in normal runs only, never in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` or owned-resize modes. As
upstream's does, the socket is a full control surface (`msg action quit` quits the
app), guarded only by those checks.

Coordinates follow DriftWM, not the scene file: camera, window and bookmark
positions are canvas points with Y up (larger Y is higher). A camera position is
the centre of the view (the output below the toolbar strip), a window position the
centre of its frame in whole points, and a bookmark the point under the centre of
the view's usable area. The app registers no usable area yet, so that is the whole
view and a bookmark set at a view equals its camera position. The controller's own
world is top-left, Y-down, and the controller converts. A window is selected by
`--id N`, the Infinify window id that `state` prints, or by a case-insensitive
part of its bundle identifier, where a window with a bound source wins over a
detached placeholder. Requests act on the active output: the one under the
pointer, else the one of the panel under the pointer, else the first. Before the
canvas first opens there is none: `camera`, `zoom`, setting `focus` and the view
and bookmark actions (`pan-viewport`, `home-toggle`, the zoom actions,
`go-to-bookmark`, `set-bookmark`) answer `no active output`, and everything else
answers as it always does: `state`, `bookmark`, `move`, `debug-counters`, reading
`focus` or `resize`, `action quit`, and the unknown and not-implemented replies.
After Return to desktop every request answers `the
canvas is closed`, after a failed scene load the load error, and while an
experimental native resize is unresolved `a native resize is pending`.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, windows (id, bundle id as `app_id`, title, centre position, size, `suspended` for a detached placeholder), outputs (stable id as `name`, `active`) and the active bookmark. `layout`, `fullscreen`, `pinned` and the layer lists are always empty. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source, at the current zoom for a detached placeholder. Native application focus does not change: the app does not perform the focus request the controller returns. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, and when it would put the frame outside the 32-bit integer range every other request reads positions in. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size only. Setting one answers an error: native layout resize is not available yet. |
| `action SPEC...` | Run an upstream action string, below. |
| `bookmark [NAME] [X Y] [--delete]` | List bookmarks, get or set one, or delete it. |
| `debug-counters` | A small map of controller collection sizes; the keys are Infinify's own and not stable. |

`layout`, `opacity`, `pin`, `close`, `suspend`, `relaunch`, `screenshot` and
`subscribe` answer `<name> is not implemented on macOS yet`.

`action` parses the full upstream action grammar with upstream's spelling. These
run: `pan-viewport <direction>`, `home-toggle`, `zoom-in`, `zoom-out`,
`zoom-reset`, `zoom-to-fit`, `go-to-bookmark NAME`, `set-bookmark NAME` and
`quit`. Every other upstream action parses and answers `action not implemented on
macOS yet: …`; a string upstream does not parse answers upstream's own message,
such as `unknown action: …` or `unknown direction: …`. Upstream replies Ok to any
spec that parses; Infinify reports the not-implemented case instead.
`go-to-bookmark` with a name that is not set answers Ok and does nothing, as
upstream's does.

On the socket itself the members of a reply object arrive in alphabetical order,
not upstream's declaration order; `msg --json` prints upstream's order. The app
re-encodes each request line before the controller decodes it, so a raw client
can send a whole-valued float where upstream requires an integer (`100.0` for
`100` in `move`) and have it accepted, and a line holding a number such as `1e999`
answers a bare `invalid request`. `msg` sends neither. Requests
that move a camera start a flight and answer at once: poll `camera` or `zoom` to
see it land. A pointer press, scroll or pinch on the canvas stops a scripted
flight where it is, like any other. A client must wait for its reply: a
connection whose peer has already closed when the server accepts it is dropped
unread, where upstream would still run the request.

Status: automated coverage is controller scenarios through the exported C ABI/JSON
path. On 2026-10-09 the built app was also driven by a script over a private
socket in `--windowed` mode on a seeded scene of three detached placeholders
(macOS 27.2, Apple Silicon); nothing from those runs is saved as evidence.
Observed there through `Infinify msg` and the raw socket: `state`;
camera and zoom reads and writes landing on their targets (with the exceptions
below), the zoom clamp included; `zoom-in`, `zoom-out`, `zoom-reset`; `zoom-to-fit` to the pose that
frames the seeded windows and back; `home-toggle` there and back; `pan-viewport`;
bookmark set, get, list, delete, `set-bookmark` and `go-to-bookmark` with the
active bookmark in `state`; `move` by id, and a move past the integer range
refused with the scene still readable; `focus` by id and by bundle identifier
flying to an out-of-view placeholder with the zoom left at 0.5, and moving
nothing for one already in view; `zoom nan` and `camera inf 0` refused by `msg`;
the unknown, not-implemented and refused replies with their exit statuses; an
invalid line; `debug-counters`; `INFINIFY_SOCKET`; the socket's 0600 mode; a
stale socket replaced; a second instance on the same path left without IPC while
the first kept answering; bookmarks, the moved window, focus and the camera in
the scene file and after a restart; `msg action quit` and SIGTERM both answering,
exiting 0 and removing the socket. The last two runs were made after the review fixes
to `focus`, `move` and `msg`, and every flight in them landed; they did not repeat
the zoom clamp, `zoom-in`, `zoom-out`, `zoom-reset`, `INFINIFY_SOCKET`, the stale
socket, the restart or `msg action quit`, which stand as observed before those
fixes. Three flights in the earlier runs did not land
exactly: `camera 0 0` stopped short in one full run and in one of six short
launches, having landed in the first full run and the other five, and one flight
ended 0.31 points off in x alone. The machine's own pointer input reaching the
panel is the likely cause and was not confirmed. Not observed:
anything drawn (the panel, tiles, animation frames, the status line), the
toolbar, every shortcut and its status feedback, bound sources and so the focus
effect and the 1:1 focus flight, a multi-display active output, requests before the canvas opens or after
Return to desktop, the default socket path, the peer user check, and the
connection, line-length and idle limits against the app.

## Nested development window

`--windowed [WIDTHxHEIGHT]` (default 1200x800) is the macOS analogue of upstream's
nested winit backend. Instead of one full-screen floating panel per display it
opens the canvas immediately in one ordinary-level, non-activating panel with a
single output whose stable id is `windowed`. No global hot keys are registered, so
use the toolbar, the pointer and `Infinify msg`; the chooser is not shown at
launch but stays reachable from the toolbar. It is rejected in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` and owned-resize modes. It saves to
the default scene file and takes the default socket unless `--state` and `--socket`
say otherwise, so give a development window its own when you also use Infinify
normally. A size must be at least 960x480 (the width that keeps the toolbar and
status line visible) and at most 16384 in each direction, or the app exits 64; the
panel is then clamped to the main display's visible area and centred on it. It is
the same borderless panel as the full-screen ones: it cannot be dragged, it closes
only through Return to desktop or Quit, and a display change rebuilds it. With
`--experimental-native-navigation` the Option-Tab hot keys are not registered, but
that flag's listen-only input observer still is.

Launched on 2026-10-09 as `--windowed 1100x700` with `--state` and `--socket`:
`msg state` reported one output named `windowed` of 1100x636 (the panel less its
64-point toolbar strip), and its camera was saved under that name and restored on
the next launch. The panel itself, its window level, the toolbar and the absence
of global hot keys were not inspected.

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
Minimized/hidden/Space transitions, display hotplug, IME composition, the
registered exit hotkey and the view-action and bookmark shortcuts require manual
validation on the intended workstation. The view actions, bookmarks and IPC
requests have exported-C-ABI/JSON controller test coverage, and scripted `msg`
sessions against a running `--windowed` app (see Scripting above) that left no
saved evidence. Their rendered animation, toolbar buttons, global-shortcut
delivery and status feedback have not been verified on a live run, and neither
has IPC with bound sources or more than one display. The view actions omit upstream's fullscreen
interaction (Infinify has no fullscreen yet, so Home has no fullscreen-return
leg or pointer warp), configurable chords and steps, and `nav_anchors` in Fit.
Bookmark chords cover names 1 to 4 and there is no bookmark configuration or
upstream `restore_bookmarks` switch: bookmarks are always saved.
The IPC surface is a subset of DriftWM's. Most upstream actions parse but are
not implemented; `layout`, `opacity`, `pin`, `close`, `suspend`, `relaunch`,
`screenshot` and `subscribe` are not implemented; `resize` is read-only. An IPC
focus is logical focus and camera navigation only and changes no native focus, and
an IPC move is a logical world move that never moves the native window. Nested
`--windowed` mode registers no global shortcuts and has one output.
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
readback from the focus adapter. Mouse, keyboard and other human intent cancel
pending focus work and the held cycle before the legacy pointer path; clicks are
never saved for later replay. Observed input does not stop camera flights: a
pointer press, scroll or pinch on a canvas stops them, as in the default app,
and so does the system disabling the observer. Detach, rebind, chooser, screen
changes, cleanup, and shutdown invalidate work, camera flights included, before
teardown. Unsupported non-null owner authority fails closed rather than being
silently discarded.

Coalesced bounded observation runs at most once per half second on the same
serial worker. Expected confirmations use `focus_result`, duplicate confirmed
observations do nothing, independently validated external focus ends cycling,
and failed/unknown readback does not claim focus loss. A single common-mode
60 Hz main-thread timer advances all active camera flights and renders once per
frame; idle polling keeps the clock current and completed flights save once.
The default app runs the same timer for view-action flights without this flag,
ticking the controller directly on the same clock. With the flag the coordinator
ticks them, and they stop on the same input as without it: the observer's
cancellation above is limited to focus work, so a shortcut's own key release,
pointer movement, or a click outside a canvas leaves a flight flying. View
actions combined with this flag are unrun.
The navigation flag does not enable resizing; resizing has a separate experimental flag.

`./tests/e2e/desktop-navigation.sh` runs the real Objective-C coordinator and
input-order policy against the actual Rust C ABI with injected nonmutating
focus, clock, and scheduling. It covers exact identities, binding generations,
held/reverse/release-pending cycles, supersession, rejected commands, teardown,
observation reconciliation, pointer cancellation, focus-only cancellation that
leaves a camera flight armed, two-output intermediate camera poses, and saved
final poses. It starts no NSApplication, windows, fixture,
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
never becomes an accepted baseline. A fresh isolated scene is used. The chooser attaches the exact SCK source. The runner selects that source through the real
controller focus command without dispatching its returned native-focus effect;
this establishes logical selection only. It verifies the focused source, settled
placement, actual rendered handle layer and converted pointer/output before calling
the gesture path. Receipts record those checks and the resulting gesture/transaction.
The runner calls the real
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
Before publishing readiness, it preserves both original created frames and spends
at most two seconds servicing the event loop while observing exact CG IDs/owners,
process birth and matching original top-coordinate bounds. No transform is queried
until both windows are registered. Two consecutive registered observations,
separated by an event pump, must have identical finite transforms; any subsequent
registered change, unknown transform, changed geometry or interference fails and
closes only the owned windows. Missing registration remains pending, never a usable
baseline. The observation sequence is retained in `fixture-readiness.json`.
The first registered transform candidates are frozen once: there is no rebase on
change or after readiness. Before chooser use, the controller independently confirms
that the current transform and AX/CG geometry equal this published baseline.
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
passive MouseEntered, MouseExited and CursorUpdate notifications are discarded
before dispatch without latching failure or clearing any existing latch. MouseMoved
and all actionable or unknown events still latch failure. There is no event-tag
exemption. Scripted DesktopView calls bypass the event queue. All owned-window
exclusion contracts are checked before capture and mutation. Diagnostics preserve
the first failing window's class, ID, visibility and mouse/key/main exclusion flags;
unknown windows remain forbidden except an enumeration-only AppKit auxiliary:
the exact class NSLocalWindowSharingWindow, hidden, unable to become key/main
and currently neither key nor main. ID -1 is accepted before registration; a
positive ID additionally requires an exact current CG row owned by this process,
its unchanged birth identity and explicit CG onscreen=false. Missing facts fail.
The first validated positive ID is frozen per object; later ID changes, including
returning to -1, fail. Every scan rechecks those conditions and records actual CG
facts separately from the first helper failure. This observed-state exception
does not establish the private class's purpose or compatibility on other OS builds.
The probe never alters that helper. Direct owned-window checks and before-order checks retain their strict
mouse exclusion requirement. No window titles or human text are recorded.

Every setter checks the exact owned identity, unchanged read-only transform,
recognized geometry, deadline, foreground identity, fresh fixture exclusion state,
and sticky input-exclusion status. The same foreground application's unrelated
input is allowed: this mode does not query global HID inactivity or require an
input-observation grant. Switching foreground apps still aborts, and unexpected
actionable or unknown input delivered to the probe is dropped and permanently
aborts the session.
Owned mode registers neither the global Escape monitor, the exit hotkey nor the
view-action shortcuts, and its toolbar has no view-action buttons; use
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
